package main

import (
	"io"
	"net"
	"net/netip"
	"sync"
	"time"
)

func parseAddrPort(s string) (netip.AddrPort, error) { return netip.ParseAddrPort(s) }

// pipe copies in both directions until either side finishes.
func pipe(a, b net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)
	cp := func(dst, src net.Conn) {
		defer wg.Done()
		io.Copy(dst, src)
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

// LogBuf keeps the most recent log lines for the UI.
type LogBuf struct {
	mu    sync.Mutex
	lines []string
}

func (l *LogBuf) Add(s string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.lines = append(l.lines, time.Now().Format("15:04:05 ")+s)
	if len(l.lines) > 300 {
		l.lines = l.lines[len(l.lines)-300:]
	}
}

func (l *LogBuf) Snapshot() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]string(nil), l.lines...)
}
