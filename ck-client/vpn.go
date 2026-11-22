package main

import (
	"encoding/binary"
	"io"
	"net"
	"net/netip"
	"strconv"
	"sync/atomic"
	"time"

	"github.com/xjasonlyu/tun2socks/v2/core/adapter"
	"gvisor.dev/gvisor/pkg/tcpip"
)

const vpnMTU = 1200 // keeps UDP payloads under badvpn's default --udp-mtu 1200

// vpnHandler receives every TCP/UDP flow the OS routes into the TUN adapter
// and forwards it through the SSH tunnel (UDP via udpgw).
type vpnHandler struct {
	t     *Tunnel
	useGW bool
	logf  func(string, ...any)
}

func addrString(a tcpip.Address) netip.Addr {
	ip, _ := netip.AddrFromSlice(a.AsSlice())
	return ip.Unmap()
}

func (h *vpnHandler) HandleTCP(c adapter.TCPConn) {
	id := c.ID()
	dst := net.JoinHostPort(addrString(id.LocalAddress).String(), strconv.Itoa(int(id.LocalPort)))
	up, err := h.t.DialTCP(dst)
	if err != nil {
		if n := h.badTCP.Add(1); n <= 10 {
			h.logf("TCP -> %s failed: %v", dst, err)
		}
		c.Close()
		return
	}
	if n := h.okTCP.Add(1); n <= 3 {
		h.logf("TCP flow #%d from the system -> %s forwarded OK", n, dst)
	}
	pipe(c, up)
}

func (h *vpnHandler) HandleUDP(c adapter.UDPConn) {
	id := c.ID()
	dst := netip.AddrPortFrom(addrString(id.LocalAddress), id.LocalPort)
	defer c.Close()
	if n := h.udpN.Add(1); n <= 3 {
		h.logf("UDP flow #%d from the system -> %s", n, dst)
	}

	idle := 60 * time.Second
	if dst.Port() == 53 {
		idle = 10 * time.Second
	}

	if h.useGW {
		if sess, err := h.t.gw.Open(dst); err == nil {
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
	// udpgw unavailable: DNS can still work over TCP through the tunnel.
	if dst.Port() == 53 {
		h.dnsOverTCP(c, dst, idle)
	}
}

func (h *vpnHandler) dnsOverTCP(c adapter.UDPConn, dst netip.AddrPort, idle time.Duration) {
	buf := make([]byte, 4096)
	for {
		c.SetReadDeadline(time.Now().Add(idle))
		n, err := c.Read(buf)
		if err != nil {
			return
		}
		q := append([]byte(nil), buf[:n]...)
		go func() {
			up, err := h.t.DialTCP(net.JoinHostPort(dst.Addr().String(), "53"))
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
