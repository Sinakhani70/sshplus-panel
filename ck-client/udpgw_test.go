package main

import (
	"encoding/binary"
	"io"
	"net"
	"net/netip"
	"testing"
	"time"
)

// A tiny in-process stand-in for badvpn-udpgw that echoes every datagram back
// with the same connection id and destination address.
func fakeUDPGW(t *testing.T) (addr string, stop func()) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
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
					c.Write(append(h[:], p...)) // echo
				}
			}()
		}
	}()
	return ln.Addr().String(), func() { ln.Close() }
}

func TestUDPGWRoundTrip(t *testing.T) {
	addr, stop := fakeUDPGW(t)
	defer stop()
	g := NewUDPGW(func() (net.Conn, error) { return net.Dial("tcp", addr) })
	defer g.Close()

	for _, dst := range []string{"8.8.8.8:53", "[2001:4860:4860::8888]:443"} {
		ap := netip.MustParseAddrPort(dst)
		s, err := g.Open(ap)
		if err != nil {
			t.Fatal(err)
		}
		msg := []byte("hello-" + dst)
		if err := s.Send(msg); err != nil {
			t.Fatal(err)
		}
		got, err := s.Recv(2 * time.Second)
		if err != nil || string(got) != string(msg) {
			t.Fatalf("%s: got %q err %v", dst, got, err)
		}
		s.Close()
	}
}

func TestEncodeLayout(t *testing.T) {
	p := encodePacket(0x0102, netip.MustParseAddrPort("1.2.3.4:53"), []byte{9})
	want := []byte{10, 0 /*len LE*/, 0 /*flags*/, 2, 1 /*conid LE*/, 1, 2, 3, 4, 0, 53, 9}
	if string(p) != string(want) {
		t.Fatalf("got %v want %v", p, want)
	}
}
