package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/binary"
	"io"
	"net"
	"strconv"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

// minimal SSH server: password auth + direct-tcpip forwarding (what sshd/dropbear do for -D)
func startSSHServer(t *testing.T) string {
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
					up, err := net.Dial("tcp", net.JoinHostPort(d.Host, strconv.Itoa(int(d.Port))))
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

func TestEndToEndSocksTCPandUDP(t *testing.T) {
	sshAddr := startSSHServer(t)
	gwAddr, stop := fakeUDPGW(t)
	defer stop()

	// TCP echo target
	eln, _ := net.Listen("tcp", "127.0.0.1:0")
	defer eln.Close()
	go func() {
		for {
			c, err := eln.Accept()
			if err != nil {
				return
			}
			go func() { io.Copy(c, c); c.Close() }()
		}
	}()

	host, portS, _ := net.SplitHostPort(sshAddr)
	port, _ := strconv.Atoi(portS)
	p := &Profile{Name: "t", Host: host, Port: port, User: "u", Password: "p", UdpgwEnabled: true, UdpgwAddr: gwAddr}
	p.applyDefaults()
	st := &Store{path: t.TempDir() + "/p.json"}
	st.Put(p)
	tun := NewTunnel(p, st, t.Logf)
	if err := tun.Start(); err != nil {
		t.Fatal(err)
	}
	defer tun.Stop()
	if st.Get("t").HostKey == "" {
		t.Fatal("host key was not pinned")
	}

	sp := 20000 + int(time.Now().UnixNano()%20000)
	sk, err := StartSocks(tun, sp)
	if err != nil {
		t.Fatal(err)
	}
	defer sk.Close()

	// --- SOCKS5 CONNECT
	c, err := net.Dial("tcp", "127.0.0.1:"+strconv.Itoa(sp))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.Write([]byte{5, 1, 0})
	r := make([]byte, 2)
	io.ReadFull(c, r)
	ea := eln.Addr().(*net.TCPAddr)
	req := append([]byte{5, 1, 0, 1}, ea.IP.To4()...)
	req = binary.BigEndian.AppendUint16(req, uint16(ea.Port))
	c.Write(req)
	rep := make([]byte, 10)
	if _, err := io.ReadFull(c, rep); err != nil || rep[1] != 0 {
		t.Fatalf("connect reply %v %v", rep, err)
	}
	c.Write([]byte("ping"))
	got := make([]byte, 4)
	c.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, err := io.ReadFull(c, got); err != nil || string(got) != "ping" {
		t.Fatalf("tcp echo got %q err %v", got, err)
	}

	// --- SOCKS5 UDP ASSOCIATE -> udpgw
	uc, _ := net.Dial("tcp", "127.0.0.1:"+strconv.Itoa(sp))
	defer uc.Close()
	uc.Write([]byte{5, 1, 0})
	io.ReadFull(uc, r)
	uc.Write([]byte{5, 3, 0, 1, 0, 0, 0, 0, 0, 0})
	ur := make([]byte, 10)
	io.ReadFull(uc, ur)
	relay := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: int(binary.BigEndian.Uint16(ur[8:10]))}
	u, _ := net.DialUDP("udp", nil, relay)
	defer u.Close()
	dgram := append([]byte{0, 0, 0, 1, 8, 8, 8, 8, 0, 53}, []byte("dnsquery")...)
	u.Write(dgram)
	u.SetReadDeadline(time.Now().Add(3 * time.Second))
	buf := make([]byte, 100)
	n, err := u.Read(buf)
	if err != nil || string(buf[10:n]) != "dnsquery" {
		t.Fatalf("udp echo got %q err %v", buf[:n], err)
	}
}

func TestHostKeyChangeRejected(t *testing.T) {
	addr := startSSHServer(t)
	host, portS, _ := net.SplitHostPort(addr)
	port, _ := strconv.Atoi(portS)
	p := &Profile{Name: "t", Host: host, Port: port, User: "u", Password: "p", HostKey: "SHA256:bogus"}
	p.applyDefaults()
	tun := NewTunnel(p, &Store{path: t.TempDir() + "/p.json"}, t.Logf)
	if err := tun.Start(); err == nil {
		tun.Stop()
		t.Fatal("expected host key mismatch error")
	}
}
