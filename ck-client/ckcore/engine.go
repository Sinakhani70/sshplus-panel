package ckcore

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/xjasonlyu/tun2socks/v2/core"
	"github.com/xjasonlyu/tun2socks/v2/core/adapter"
	"github.com/xjasonlyu/tun2socks/v2/core/device/iobased"
	"github.com/xjasonlyu/tun2socks/v2/core/option"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
)

// MTU of the virtual interface; keeps UDP payloads under badvpn's default
// --udp-mtu 1200 (the panel's UDPGW uses 1200).
const MTU = 1200

// PacketSink receives IP packets the engine wants to send to the device
// (implemented by the Swift Packet Tunnel: packetFlow.writePackets).
type PacketSink interface {
	WritePacket(packet []byte)
}

// EventHandler receives events from the engine. Methods are called from Go
// goroutines; keep them quick and thread-safe.
type EventHandler interface {
	OnLog(line string)
	OnHostKey(fingerprint string) // the server key was trusted on first use: persist it
	OnLink(up bool)               // SSH link up/down (reconnecting)
}

// Engine is one VPN session: SSH tunnel + user-space stack + UDPGW.
type Engine struct {
	p    *profile
	sink PacketSink
	ev   EventHandler

	tun   *tunnel
	dev   *memDev
	ep    *iobased.Endpoint
	stack *stack.Stack

	mu      sync.Mutex
	started bool
	stopped bool
	logs    []string
}

// NewEngine creates an engine from a profile JSON (see profile fields in
// profile.go; password/privateKey are included by the caller).
func NewEngine(profileJSON string, sink PacketSink, ev EventHandler) (*Engine, error) {
	p, err := parseProfileJSON(profileJSON)
	if err != nil {
		return nil, fmt.Errorf("bad profile: %w", err)
	}
	if p.Host == "" || p.User == "" {
		return nil, errors.New("profile needs a host and a username")
	}
	if sink == nil {
		return nil, errors.New("packet sink is nil")
	}
	return &Engine{p: p, sink: sink, ev: ev}, nil
}

func (e *Engine) logf(f string, a ...any) {
	line := fmt.Sprintf(f, a...)
	e.mu.Lock()
	e.logs = append(e.logs, time.Now().Format("15:04:05 ")+line)
	if len(e.logs) > 200 {
		e.logs = e.logs[len(e.logs)-200:]
	}
	e.mu.Unlock()
	if e.ev != nil {
		e.ev.OnLog(line)
	}
}

// Start connects SSH (returns the error if login fails) and brings up the
// packet path. Call InputPacket for every packet read from the device.
func (e *Engine) Start() error {
	e.mu.Lock()
	if e.started || e.stopped {
		e.mu.Unlock()
		return errors.New("engine already started")
	}
	e.started = true
	e.mu.Unlock()

	var onPin func(string)
	var onLink func(bool)
	if e.ev != nil {
		onPin, onLink = e.ev.OnHostKey, e.ev.OnLink
	}
	e.tun = newTunnel(e.p, e.logf, onPin, onLink)
	e.logf("connecting to %s:%d as %s (%s)", e.p.Host, e.p.Port, e.p.User, e.p.Transport)
	if err := e.tun.start(); err != nil {
		return err
	}
	e.logf("SSH connected")
	if e.p.UdpgwEnabled {
		if c, err := e.tun.dialTCP(e.p.UdpgwAddr); err != nil {
			e.logf("WARNING: udpgw %s not reachable on the server: %v (UDP will not work)", e.p.UdpgwAddr, err)
		} else {
			c.Close()
			e.logf("udpgw reachable at %s", e.p.UdpgwAddr)
		}
	}

	e.dev = &memDev{in: make(chan []byte, 1024), done: make(chan struct{}), sink: e.sink}
	ep, err := iobased.New(e.dev, MTU, 0)
	if err != nil {
		e.tun.stop()
		return err
	}
	e.ep = ep
	st, err := core.CreateStack(&core.Config{
		LinkEndpoint:     ep,
		TransportHandler: &handler{e: e},
		Options: []option.Option{ // small buffers: iOS extensions have a tight memory limit
			option.WithTCPSendBufferSizeRange(4<<10, 64<<10, 256<<10),
			option.WithTCPReceiveBufferSizeRange(4<<10, 64<<10, 256<<10),
		},
	})
	if err != nil {
		e.tun.stop()
		return fmt.Errorf("create stack: %w", err)
	}
	e.stack = st
	e.logf("tunnel up")
	return nil
}

// InputPacket hands one IP packet read from the device to the engine.
func (e *Engine) InputPacket(packet []byte) {
	d := e.dev
	if d == nil || len(packet) == 0 {
		return
	}
	select {
	case d.in <- append([]byte(nil), packet...):
	default: // overloaded: drop like a congested link would
	}
}

// Stop tears everything down. Safe to call more than once.
func (e *Engine) Stop() {
	e.mu.Lock()
	if e.stopped {
		e.mu.Unlock()
		return
	}
	e.stopped = true
	e.mu.Unlock()
	if e.dev != nil {
		e.dev.close()
	}
	if e.stack != nil {
		e.stack.Close()
	}
	if e.ep != nil {
		e.ep.Close()
	}
	if e.tun != nil {
		e.tun.stop()
	}
	e.logf("stopped")
}

// StatusJSON returns {"up":bytes,"down":bytes,"pingMs":n,"link":bool,"tcpOK":n,"tcpFail":n,"udp":n}.
func (e *Engine) StatusJSON() string {
	m := map[string]any{"up": 0, "down": 0, "pingMs": -1, "link": false}
	if t := e.tun; t != nil {
		m["up"], m["down"], m["pingMs"], m["link"] = t.up.Load(), t.down.Load(), t.ping.Load(), t.connected.Load()
	}
	m["tcpOK"], m["tcpFail"], m["udp"] = tcpOK.Load(), tcpFail.Load(), udpFlows.Load()
	b, _ := json.Marshal(m)
	return string(b)
}

// Logs returns the recent log lines, newline separated.
func (e *Engine) Logs() string {
	e.mu.Lock()
	defer e.mu.Unlock()
	return strings.Join(e.logs, "\n")
}

// SetMemoryLimitMB sets the Go runtime soft memory limit (call once, early,
// in the Packet Tunnel extension, e.g. 30).
func SetMemoryLimitMB(mb int) {
	debug.SetMemoryLimit(int64(mb) << 20)
	debug.SetGCPercent(50)
}

// Version of the core.
func Version() string { return "ckcore 1.0" }

var tcpOK, tcpFail, udpFlows atomic.Int64

// ---- device glue ----

type memDev struct {
	in   chan []byte
	done chan struct{}
	sink PacketSink
	once sync.Once
}

func (d *memDev) Read(b []byte) (int, error) {
	select {
	case p := <-d.in:
		return copy(b, p), nil
	case <-d.done:
		return 0, io.EOF
	}
}

func (d *memDev) Write(b []byte) (int, error) {
	d.sink.WritePacket(append([]byte(nil), b...))
	return len(b), nil
}

func (d *memDev) close() { d.once.Do(func() { close(d.done) }) }

// ---- flow handlers ----

type handler struct{ e *Engine }

func ipOf(a tcpip.Address) netip.Addr {
	ip, _ := netip.AddrFromSlice(a.AsSlice())
	return ip.Unmap()
}

// The stack calls these on its packet-processing goroutine, so they must
// return immediately: the work runs in a new goroutine.
func (h *handler) HandleTCP(c adapter.TCPConn) { go h.tcp(c) }
func (h *handler) HandleUDP(c adapter.UDPConn) { go h.udp(c) }

func (h *handler) tcp(c adapter.TCPConn) {
	id := c.ID()
	dst := net.JoinHostPort(ipOf(id.LocalAddress).String(), strconv.Itoa(int(id.LocalPort)))
	up, err := h.e.tun.dialTCP(dst)
	if err != nil {
		if n := tcpFail.Add(1); n <= 10 {
			h.e.logf("TCP -> %s failed: %v", dst, err)
		}
		c.Close()
		return
	}
	tcpOK.Add(1)
	pipe(c, up)
}

func (h *handler) udp(c adapter.UDPConn) {
	id := c.ID()
	dst := netip.AddrPortFrom(ipOf(id.LocalAddress), id.LocalPort)
	defer c.Close()
	udpFlows.Add(1)

	idle := 60 * time.Second
	if dst.Port() == 53 {
		idle = 10 * time.Second
	}
	if h.e.p.UdpgwEnabled {
		if sess, err := h.e.tun.gw.Open(dst); err == nil {
			defer sess.Close()
			go func() { // server -> app
				for {
					d, err := sess.Recv(idle)
					if err != nil {
						c.Close()
						return
					}
					c.Write(d)
				}
			}()
			buf := make([]byte, 65535)
			for { // app -> server
				c.SetReadDeadline(time.Now().Add(idle))
				n, err := c.Read(buf)
				if err != nil {
					return
				}
				if sess.Send(buf[:n]) != nil {
					return
				}
			}
		}
	}
	if dst.Port() == 53 { // udpgw unavailable: DNS still works over TCP through the tunnel
		h.dnsOverTCP(c, dst, idle)
	}
}

func (h *handler) dnsOverTCP(c adapter.UDPConn, dst netip.AddrPort, idle time.Duration) {
	buf := make([]byte, 4096)
	for {
		c.SetReadDeadline(time.Now().Add(idle))
		n, err := c.Read(buf)
		if err != nil {
			return
		}
		q := append([]byte(nil), buf[:n]...)
		go func() {
			up, err := h.e.tun.dialTCP(net.JoinHostPort(dst.Addr().String(), "53"))
			if err != nil {
				return
			}
			defer up.Close()
			up.SetDeadline(time.Now().Add(8 * time.Second))
			up.Write(binary.BigEndian.AppendUint16(nil, uint16(len(q))))
			up.Write(q)
			var l [2]byte
			if _, err := io.ReadFull(up, l[:]); err != nil {
				return
			}
			r := make([]byte, binary.BigEndian.Uint16(l[:]))
			if _, err := io.ReadFull(up, r); err != nil {
				return
			}
			c.Write(r)
		}()
	}
}

// pipe copies in both directions until either side finishes.
func pipe(a, b net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)
	cp := func(dst, src net.Conn) {
		defer wg.Done()
		buf := make([]byte, 16<<10) // small relay buffer (memory)
		io.CopyBuffer(dst, src, buf)
		if cw, ok := dst.(interface{ CloseWrite() error }); ok {
			cw.CloseWrite()
		} else {
			dst.SetReadDeadline(time.Now().Add(5 * time.Second))
		}
	}
	go cp(a, b)
	go cp(b, a)
	wg.Wait()
	a.Close()
	b.Close()
}
