package ckcore

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
)

type syncBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuf) Write(p []byte) (int, error) { s.mu.Lock(); defer s.mu.Unlock(); return s.b.Write(p) }
func (s *syncBuf) String() string              { s.mu.Lock(); defer s.mu.Unlock(); return s.b.String() }

// The app side of the bridge (what the Android VpnService does): listen, accept
// the engine, pump framed packets. A user-space "phone" plays the OS.
func TestBridgeLikeAndroidApp(t *testing.T) {
	echo := echoTCP(t)
	gw := fakeUDPGW(t)
	sshAddr := startSSHServer(t, remap{"10.9.9.9:80": echo, "127.0.0.1:7300": gw})
	host, portS, _ := net.SplitHostPort(sshAddr)
	port, _ := strconv.Atoi(portS)
	pj, _ := json.Marshal(profile{Name: "t", Host: "does-not-resolve.invalid", DialAddr: host, Port: port, User: "u", Password: "p", UdpgwEnabled: true})

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	out := &syncBuf{}
	runErr := make(chan error, 1)
	go func() { runErr <- RunBridge(string(pj), ln.Addr().String(), out) }()

	ln.(*net.TCPListener).SetDeadline(time.Now().Add(10 * time.Second))
	conn, err := ln.Accept()
	if err != nil {
		t.Fatalf("engine did not connect: %v\n%s", err, out.String())
	}
	defer conn.Close()

	var wmu sync.Mutex
	ph := newPhone(t, func(p []byte) { // phone -> engine
		buf := make([]byte, 2+len(p))
		binary.BigEndian.PutUint16(buf, uint16(len(p)))
		copy(buf[2:], p)
		wmu.Lock()
		conn.Write(buf)
		wmu.Unlock()
	})
	go func() { // engine -> phone
		r := bufio.NewReader(conn)
		var h [2]byte
		for {
			if _, err := io.ReadFull(r, h[:]); err != nil {
				return
			}
			p := make([]byte, binary.BigEndian.Uint16(h[:]))
			if _, err := io.ReadFull(r, p); err != nil {
				return
			}
			ph.deliver(p)
		}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	c, err := gonet.DialContextTCP(ctx, ph.s, tcpip.FullAddress{Addr: tcpip.AddrFromSlice([]byte{10, 9, 9, 9}), Port: 80}, ipv4.ProtocolNumber)
	if err != nil {
		t.Fatalf("tcp through the bridge: %v", err)
	}
	defer c.Close()
	c.Write([]byte("android"))
	got := make([]byte, 7)
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.ReadFull(c, got); err != nil || string(got) != "android" {
		t.Fatalf("echo: %q %v", got, err)
	}

	time.Sleep(1200 * time.Millisecond) // one status tick
	log := out.String()
	for _, want := range []string{`"type":"ready"`, `"type":"hostkey"`, `"type":"status"`, `"tcpOK"`} {
		if !strings.Contains(log, want) {
			t.Errorf("events are missing %s:\n%s", want, log)
		}
	}

	conn.Close() // the app goes away -> the engine ends
	select {
	case <-runErr:
	case <-time.After(5 * time.Second):
		t.Fatal("engine did not stop after the socket closed")
	}
}

func TestBridgeBadPassword(t *testing.T) {
	sshAddr := startSSHServer(t, nil)
	host, portS, _ := net.SplitHostPort(sshAddr)
	port, _ := strconv.Atoi(portS)
	pj, _ := json.Marshal(profile{Name: "t", Host: host, Port: port, User: "u", Password: "wrong"})
	out := &syncBuf{}
	if err := RunBridge(string(pj), "127.0.0.1:1", out); err == nil {
		t.Fatal("expected an error")
	}
	if !strings.Contains(out.String(), `"type":"error"`) {
		t.Fatalf("no error event: %s", out.String())
	}
}
