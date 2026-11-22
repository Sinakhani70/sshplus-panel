package main

import (
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/netip"
	"strconv"
	"time"
)

// SOCKS5 server (CONNECT + UDP ASSOCIATE) that forwards through the tunnel.
// UDP goes over udpgw. Bound to 127.0.0.1 only.
type Socks struct {
	t  *Tunnel
	ln net.Listener
}

func StartSocks(t *Tunnel, port int) (*Socks, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:"+strconv.Itoa(port))
	if err != nil {
		return nil, err
	}
	s := &Socks{t: t, ln: ln}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go s.handle(c)
		}
	}()
	return s, nil
}

func (s *Socks) Close() { s.ln.Close() }

func (s *Socks) handle(c net.Conn) {
	defer c.Close()
	c.SetDeadline(time.Now().Add(15 * time.Second))
	var h [2]byte
	if _, err := io.ReadFull(c, h[:]); err != nil || h[0] != 5 {
		return
	}
	methods := make([]byte, h[1])
	if _, err := io.ReadFull(c, methods); err != nil {
		return
	}
	c.Write([]byte{5, 0})
	var r [4]byte
	if _, err := io.ReadFull(c, r[:]); err != nil || r[0] != 5 {
		return
	}
	host, err := readAddr(c, r[3])
	if err != nil {
		reply(c, 8, nil)
		return
	}
	var pb [2]byte
	if _, err := io.ReadFull(c, pb[:]); err != nil {
		return
	}
	port := binary.BigEndian.Uint16(pb[:])
	switch r[1] {
	case 1: // CONNECT
		up, err := s.t.DialTCP(net.JoinHostPort(host, strconv.Itoa(int(port))))
		if err != nil {
			reply(c, 5, nil)
			return
		}
		reply(c, 0, &net.UDPAddr{IP: net.IPv4zero})
		c.SetDeadline(time.Time{})
		pipe(c, up)
	case 3: // UDP ASSOCIATE
		s.udpAssociate(c)
	default:
		reply(c, 7, nil)
	}
}

func readAddr(c net.Conn, atyp byte) (string, error) {
	switch atyp {
	case 1:
		var b [4]byte
		_, err := io.ReadFull(c, b[:])
		return net.IP(b[:]).String(), err
	case 4:
		var b [16]byte
		_, err := io.ReadFull(c, b[:])
		return net.IP(b[:]).String(), err
	case 3:
		var l [1]byte
		if _, err := io.ReadFull(c, l[:]); err != nil {
			return "", err
		}
		b := make([]byte, l[0])
		_, err := io.ReadFull(c, b)
		return string(b), err
	}
	return "", errors.New("bad address type")
}

func reply(c net.Conn, code byte, a *net.UDPAddr) {
	ip, port := net.IPv4zero.To4(), 0
	if a != nil {
		if v4 := a.IP.To4(); v4 != nil {
			ip = v4
		}
		port = a.Port
	}
	b := []byte{5, code, 0, 1}
	b = append(b, ip...)
	b = binary.BigEndian.AppendUint16(b, uint16(port))
	c.Write(b)
}

func (s *Socks) udpAssociate(ctl net.Conn) {
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		reply(ctl, 1, nil)
		return
	}
	defer pc.Close()
	reply(ctl, 0, pc.LocalAddr().(*net.UDPAddr))
	ctl.SetDeadline(time.Time{})
	go func() { io.Copy(io.Discard, ctl); pc.Close() }() // association ends with the TCP control connection

	type flow struct {
		sess *UDPSession
		src  net.Addr
		hdr  []byte
	}
	flows := map[netip.AddrPort]*flow{}
	buf := make([]byte, 65535)
	for {
		n, src, err := pc.ReadFrom(buf)
		if err != nil {
			for _, f := range flows {
				f.sess.Close()
			}
			return
		}
		// RSV(2) FRAG(1) ATYP ADDR PORT DATA
		if n < 10 || buf[2] != 0 {
			continue
		}
		var dst netip.AddrPort
		var off int
		switch buf[3] {
		case 1:
			a, _ := netip.AddrFromSlice(buf[4:8])
			dst, off = netip.AddrPortFrom(a, binary.BigEndian.Uint16(buf[8:10])), 10
		case 4:
			if n < 22 {
				continue
			}
			a, _ := netip.AddrFromSlice(buf[4:20])
			dst, off = netip.AddrPortFrom(a, binary.BigEndian.Uint16(buf[20:22])), 22
		default:
			continue // domain names are not supported over udpgw
		}
		f := flows[dst]
		if f == nil {
			sess, err := s.t.UDP(dst.String())
			if err != nil {
				continue
			}
			f = &flow{sess: sess, src: src, hdr: append([]byte(nil), buf[:off]...)}
			flows[dst] = f
			go func(f *flow) {
				for {
					d, err := f.sess.Recv(2 * time.Minute)
					if err != nil {
						return
					}
					pc.WriteTo(append(append([]byte(nil), f.hdr...), d...), f.src)
				}
			}(f)
		}
		f.sess.Send(buf[off:n])
	}
}
