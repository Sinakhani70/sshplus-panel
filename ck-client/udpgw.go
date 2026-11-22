package main

import (
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/netip"
	"sync"
	"time"
)

// BadVPN UDPGW client.
//
// Wire format (one TCP stream to the server's badvpn-udpgw):
//
//	packet  = u16 length (little endian) | payload
//	payload = u8 flags | u16 conid (little endian) | address | UDP data
//	address = IPv4: 4 bytes + u16 port (big endian)
//	          IPv6 (flag 8): 16 bytes + u16 port (big endian)
//
// A keep-alive packet is just flags=1, conid=0 with no address.
const (
	flagKeepalive = 1 << 0
	flagRebind    = 1 << 1
	flagDNS       = 1 << 2
	flagIPv6      = 1 << 3

	udpgwMaxPacket = 65535
	udpgwKeepalive = 10 * time.Second
)

var errUDPGWClosed = errors.New("udpgw: connection closed")

type UDPGW struct {
	dial func() (net.Conn, error) // opens a TCP stream to the server's udpgw port

	mu       sync.Mutex
	conn     net.Conn
	sessions map[uint16]*UDPSession
	next     uint16

	wmu sync.Mutex // serialises writes to conn
}

func NewUDPGW(dial func() (net.Conn, error)) *UDPGW {
	return &UDPGW{dial: dial, sessions: map[uint16]*UDPSession{}}
}

type UDPSession struct {
	g    *UDPGW
	id   uint16
	dst  netip.AddrPort
	recv chan []byte
	done chan struct{}
	once sync.Once
}

// Open creates a UDP flow towards dst, connecting to udpgw if needed.
func (g *UDPGW) Open(dst netip.AddrPort) (*UDPSession, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.conn == nil {
		c, err := g.dial()
		if err != nil {
			return nil, err
		}
		g.conn = c
		go g.readLoop(c)
		go g.keepaliveLoop(c)
	}
	// pick a free connection id (0 is reserved for keep-alives)
	for i := 0; i < 65536; i++ {
		g.next++
		if g.next == 0 {
			g.next = 1
		}
		if _, used := g.sessions[g.next]; !used {
			break
		}
	}
	s := &UDPSession{g: g, id: g.next, dst: dst, recv: make(chan []byte, 64), done: make(chan struct{})}
	g.sessions[s.id] = s
	return s, nil
}

func (g *UDPGW) Close() {
	g.mu.Lock()
	c := g.conn
	g.mu.Unlock()
	if c != nil {
		c.Close()
	}
}

func (g *UDPGW) dropConn(c net.Conn) {
	g.mu.Lock()
	if g.conn == c {
		g.conn = nil
		for id, s := range g.sessions {
			s.closeLocked()
			delete(g.sessions, id)
		}
	}
	g.mu.Unlock()
	c.Close()
}

func (s *UDPSession) closeLocked() { s.once.Do(func() { close(s.done) }) }

func (s *UDPSession) Close() {
	s.g.mu.Lock()
	delete(s.g.sessions, s.id)
	s.g.mu.Unlock()
	s.closeLocked()
}

// Send transmits one datagram to the session's destination.
func (s *UDPSession) Send(data []byte) error {
	s.g.mu.Lock()
	c := s.g.conn
	s.g.mu.Unlock()
	if c == nil {
		return errUDPGWClosed
	}
	pkt := encodePacket(s.id, s.dst, data)
	s.g.wmu.Lock()
	defer s.g.wmu.Unlock()
	c.SetWriteDeadline(time.Now().Add(15 * time.Second))
	if _, err := c.Write(pkt); err != nil {
		go s.g.dropConn(c)
		return err
	}
	return nil
}

// Recv returns the next datagram from the destination or an error when the
// session ends or the timeout expires.
func (s *UDPSession) Recv(timeout time.Duration) ([]byte, error) {
	t := time.NewTimer(timeout)
	defer t.Stop()
	select {
	case p := <-s.recv:
		return p, nil
	case <-s.done:
		return nil, errUDPGWClosed
	case <-t.C:
		return nil, errors.New("timeout")
	}
}

func encodePacket(id uint16, dst netip.AddrPort, data []byte) []byte {
	flags := byte(0)
	addr := dst.Addr().Unmap()
	alen := 4
	if addr.Is6() {
		flags |= flagIPv6
		alen = 16
	}
	plen := 1 + 2 + alen + 2 + len(data)
	buf := make([]byte, 2+plen)
	binary.LittleEndian.PutUint16(buf[0:], uint16(plen))
	buf[2] = flags
	binary.LittleEndian.PutUint16(buf[3:], id)
	n := 5
	n += copy(buf[n:], addr.AsSlice())
	binary.BigEndian.PutUint16(buf[n:], dst.Port())
	n += 2
	copy(buf[n:], data)
	return buf
}

// decodePayload parses a server->client payload (after the length prefix).
func decodePayload(p []byte) (flags byte, id uint16, src netip.AddrPort, data []byte, err error) {
	if len(p) < 3 {
		return 0, 0, src, nil, errors.New("udpgw: short packet")
	}
	flags = p[0]
	id = binary.LittleEndian.Uint16(p[1:])
	if flags&flagKeepalive != 0 {
		return flags, id, src, nil, nil
	}
	alen := 4
	if flags&flagIPv6 != 0 {
		alen = 16
	}
	if len(p) < 3+alen+2 {
		return 0, 0, src, nil, errors.New("udpgw: short address")
	}
	a, _ := netip.AddrFromSlice(p[3 : 3+alen])
	port := binary.BigEndian.Uint16(p[3+alen:])
	return flags, id, netip.AddrPortFrom(a, port), p[3+alen+2:], nil
}

func (g *UDPGW) readLoop(c net.Conn) {
	defer g.dropConn(c)
	var hdr [2]byte
	for {
		if _, err := io.ReadFull(c, hdr[:]); err != nil {
			return
		}
		n := int(binary.LittleEndian.Uint16(hdr[:]))
		if n == 0 {
			continue
		}
		p := make([]byte, n)
		if _, err := io.ReadFull(c, p); err != nil {
			return
		}
		flags, id, _, data, err := decodePayload(p)
		if err != nil || flags&flagKeepalive != 0 {
			continue
		}
		g.mu.Lock()
		s := g.sessions[id]
		g.mu.Unlock()
		if s == nil {
			continue
		}
		select {
		case s.recv <- data:
		default: // receiver too slow: drop like a real UDP path would
		}
	}
}

func (g *UDPGW) keepaliveLoop(c net.Conn) {
	t := time.NewTicker(udpgwKeepalive)
	defer t.Stop()
	for range t.C {
		g.mu.Lock()
		alive := g.conn == c
		g.mu.Unlock()
		if !alive {
			return
		}
		pkt := []byte{3, 0, flagKeepalive, 0, 0}
		g.wmu.Lock()
		c.SetWriteDeadline(time.Now().Add(15 * time.Second))
		_, err := c.Write(pkt)
		g.wmu.Unlock()
		if err != nil {
			g.dropConn(c)
			return
		}
	}
}
