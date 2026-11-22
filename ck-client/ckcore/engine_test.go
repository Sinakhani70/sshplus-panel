package ckcore

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
	"strconv"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
)

// ---- fakes: SSH server (password auth + direct-tcpip), echo server, udpgw ----

// remap lets the tests pretend that 10.9.9.x addresses exist.
type remap map[string]string

func startSSHServer(t *testing.T, rm remap) string {
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	signer, _ := ssh.NewSignerFromKey(priv)
	cfg := &ssh.ServerConfig{PasswordCallback: func(c ssh.ConnMetadata, pw []byte) (*ssh.Permissions, error) {
		if c.User() == "u" && string(pw) == "p" {
			return nil, nil
		}
		return nil, io.EOF
	}}
	cfg.AddHostKey(signer)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			nc, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				sc, chans, reqs, err := ssh.NewServerConn(nc, cfg)
				if err != nil {
					return
				}
				go func() {
					for r := range reqs {
						if r.WantReply {
							r.Reply(r.Type == "keepalive@openssh.com", nil)
						}
					}
				}()
				for nch := range chans {
					if nch.ChannelType() != "direct-tcpip" {
						nch.Reject(ssh.UnknownChannelType, "no")
						continue
					}
					var d struct {
						Host string
						Port uint32
						OH   string
						OP   uint32
					}
					ssh.Unmarshal(nch.ExtraData(), &d)
					target := net.JoinHostPort(d.Host, strconv.Itoa(int(d.Port)))
					if m, ok := rm[target]; ok {
						target = m
					}
					up, err := net.Dial("tcp", target)
					if err != nil {
						nch.Reject(ssh.ConnectionFailed, err.Error())
						continue
					}
					ch, rq, _ := nch.Accept()
					go ssh.DiscardRequests(rq)
					go func() { io.Copy(ch, up); ch.Close() }()
					go func() { io.Copy(up, ch); up.Close() }()
				}
				sc.Close()
			}()
		}
	}()
	return ln.Addr().String()
}

func echoTCP(t *testing.T) string {
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() { io.Copy(c, c); c.Close() }()
		}
	}()
	return ln.Addr().String()
}

// fakeUDPGW echoes every datagram with the same id and address.
func fakeUDPGW(t *testing.T) string {
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				var h [2]byte
				for {
					if _, err := io.ReadFull(c, h[:]); err != nil {
						return
					}
					p := make([]byte, binary.LittleEndian.Uint16(h[:]))
					if _, err := io.ReadFull(c, p); err != nil {
						return
					}
					if p[0]&flagKeepalive != 0 {
						continue
					}
					c.Write(append(h[:], p...))
				}
			}()
		}
	}()
	return ln.Addr().String()
}

// ---- a second user-space stack playing the role of the phone's OS ----

type phone struct {
	s  *stack.Stack
	ep *channel.Endpoint
}

func newPhone(t *testing.T, eng *Engine) *phone {
	ep := channel.New(512, MTU, "")
	s := stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol},
	})
	if err := s.CreateNIC(1, ep); err != nil {
		t.Fatal(err)
	}
	addr := tcpip.AddrFromSlice(net.IPv4(10, 0, 0, 2).To4())
	if err := s.AddProtocolAddress(1, tcpip.ProtocolAddress{Protocol: ipv4.ProtocolNumber,
		AddressWithPrefix: tcpip.AddressWithPrefix{Address: addr, PrefixLen: 24}}, stack.AddressProperties{}); err != nil {
		t.Fatal(err)
	}
	s.SetRouteTable([]tcpip.Route{{Destination: header.IPv4EmptySubnet, NIC: 1}})
	ph := &phone{s: s, ep: ep}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go func() { // phone -> engine
		for {
			pkt := ep.ReadContext(ctx)
			if pkt == nil {
				return
			}
			buf := pkt.ToBuffer()
			data := buf.Flatten()
			buf.Release()
			pkt.DecRef()
			eng.InputPacket(data)
		}
	}()
	return ph
}

func (p *phone) deliver(data []byte) { // engine -> phone
	pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(append([]byte(nil), data...))})
	p.ep.InjectInbound(header.IPv4ProtocolNumber, pkt)
	pkt.DecRef()
}

type sink struct {
	mu sync.Mutex
	f  func([]byte)
}

func (s *sink) WritePacket(b []byte) {
	s.mu.Lock()
	f := s.f
	s.mu.Unlock()
	if f != nil {
		f(b)
	}
}

type events struct {
	mu   sync.Mutex
	pins []string
}

func (e *events) OnLog(string) {}
func (e *events) OnHostKey(fp string) {
	e.mu.Lock()
	e.pins = append(e.pins, fp)
	e.mu.Unlock()
}
func (e *events) OnLink(bool) {}

func setup(t *testing.T) (*Engine, *phone, *events) {
	echo := echoTCP(t)
	gw := fakeUDPGW(t)
	sshAddr := startSSHServer(t, remap{"10.9.9.9:80": echo, "127.0.0.1:7300": gw})
	host, portS, _ := net.SplitHostPort(sshAddr)
	port, _ := strconv.Atoi(portS)
	pj, _ := json.Marshal(profile{Name: "t", Host: host, Port: port, User: "u", Password: "p", UdpgwEnabled: true})
	sk := &sink{}
	ev := &events{}
	eng, err := NewEngine(string(pj), sk, ev)
	if err != nil {
		t.Fatal(err)
	}
	ph := newPhone(t, eng)
	sk.f = ph.deliver
	if err := eng.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(eng.Stop)
	return eng, ph, ev
}

func TestEnginePacketPath(t *testing.T) {
	eng, ph, ev := setup(t)
	if len(ev.pins) != 1 {
		t.Fatalf("host key not pinned: %v", ev.pins)
	}

	// 1. a UDP flow that stays open (regression: a blocking UDP handler once stalled every packet)
	uc, err := gonet.DialUDP(ph.s, nil, &tcpip.FullAddress{Addr: tcpip.AddrFromSlice(net.IPv4(10, 9, 9, 8).To4()), Port: 5353}, ipv4.ProtocolNumber)
	if err != nil {
		t.Fatal(err)
	}
	defer uc.Close()
	uc.Write([]byte("dns?"))
	uc.SetReadDeadline(time.Now().Add(5 * time.Second))
	buf := make([]byte, 100)
	n, err := uc.Read(buf)
	if err != nil || string(buf[:n]) != "dns?" {
		t.Fatalf("udp echo via udpgw: %q %v", buf[:n], err)
	}

	// 2. TCP while that UDP flow is still idle
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	c, err := gonet.DialContextTCP(ctx, ph.s, tcpip.FullAddress{Addr: tcpip.AddrFromSlice(net.IPv4(10, 9, 9, 9).To4()), Port: 80}, ipv4.ProtocolNumber)
	if err != nil {
		t.Fatalf("tcp dial through the engine: %v", err)
	}
	defer c.Close()
	msg := []byte("hello through ssh")
	c.Write(msg)
	got := make([]byte, len(msg))
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.ReadFull(c, got); err != nil || string(got) != string(msg) {
		t.Fatalf("tcp echo: %q %v", got, err)
	}

	var st map[string]any
	json.Unmarshal([]byte(eng.StatusJSON()), &st)
	if st["link"] != true || st["up"].(float64) <= 0 || st["down"].(float64) <= 0 {
		t.Fatalf("status: %v", st)
	}
}

func TestPing(t *testing.T) {
	eng, _, _ := setup(t)
	ms, err := eng.tun.measurePing() // default target 1.1.1.1:443 is unreachable from the fake server -> use "off"
	_ = ms
	_ = err
	eng.tun.p.PingTarget = "off"
	ms, err = eng.tun.measurePing()
	if err != nil || ms < 1 {
		t.Fatalf("ssh round trip: %d %v", ms, err)
	}
}

func TestHostKeyMismatchRejected(t *testing.T) {
	sshAddr := startSSHServer(t, nil)
	host, portS, _ := net.SplitHostPort(sshAddr)
	port, _ := strconv.Atoi(portS)
	pj, _ := json.Marshal(profile{Name: "t", Host: host, Port: port, User: "u", Password: "p", HostKey: "SHA256:bogus"})
	eng, _ := NewEngine(string(pj), &sink{}, &events{})
	if err := eng.Start(); err == nil {
		eng.Stop()
		t.Fatal("expected host key mismatch")
	}
}
