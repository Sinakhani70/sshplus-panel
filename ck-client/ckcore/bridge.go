package ckcore

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

// Bridge: how the Android app talks to the engine, which runs as a separate
// process (a Go executable shipped as lib*.so, because gomobile/NDK are not
// needed that way).
//
//  * The app (VpnService) owns the TUN device and listens on 127.0.0.1:<port>.
//  * The engine connects there once SSH is up. Both directions carry IP packets
//    framed as  u16 big-endian length | packet.
//  * Events go to the engine's stdout as JSON lines:
//      {"type":"ready"}                       SSH is up, about to connect to the app
//      {"type":"error","msg":"..."}           fatal
//      {"type":"log","line":"..."}            log line
//      {"type":"hostkey","fp":"SHA256:..."}   server key trusted on first use
//      {"type":"link","up":true|false}
//      {"type":"status", ...StatusJSON}       every second
//  The engine exits when the socket closes or on SIGTERM.

type lineWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func (l *lineWriter) send(v map[string]any) {
	b, _ := json.Marshal(v)
	l.mu.Lock()
	l.w.Write(append(b, '\n'))
	l.mu.Unlock()
}

type bridgeEvents struct{ out *lineWriter }

func (b *bridgeEvents) OnLog(line string)   { b.out.send(map[string]any{"type": "log", "line": line}) }
func (b *bridgeEvents) OnHostKey(fp string) { b.out.send(map[string]any{"type": "hostkey", "fp": fp}) }
func (b *bridgeEvents) OnLink(up bool)      { b.out.send(map[string]any{"type": "link", "up": up}) }

type socketSink struct {
	mu sync.Mutex
	c  net.Conn
}

func (s *socketSink) WritePacket(p []byte) {
	if len(p) > 0xFFFF {
		return
	}
	buf := make([]byte, 2+len(p))
	binary.BigEndian.PutUint16(buf, uint16(len(p)))
	copy(buf[2:], p)
	s.mu.Lock()
	s.c.SetWriteDeadline(time.Now().Add(10 * time.Second))
	s.c.Write(buf)
	s.mu.Unlock()
}

// RunBridge runs one VPN session: SSH (from profileJSON), then packets over
// the loopback socket at hostport, events as JSON lines to out. It returns when
// the session ends.
func RunBridge(profileJSON, hostport string, out io.Writer) error {
	lw := &lineWriter{w: out}
	ev := &bridgeEvents{out: lw}
	sink := &socketSink{}
	eng, err := NewEngine(profileJSON, sink, ev)
	if err != nil {
		lw.send(map[string]any{"type": "error", "msg": err.Error()})
		return err
	}
	if err := eng.Start(); err != nil {
		lw.send(map[string]any{"type": "error", "msg": err.Error()})
		return err
	}
	defer eng.Stop()
	lw.send(map[string]any{"type": "ready"})

	var conn net.Conn
	for i := 0; i < 50; i++ { // the app starts listening right after it sees "ready"
		conn, err = net.DialTimeout("tcp", hostport, 2*time.Second)
		if err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err != nil {
		lw.send(map[string]any{"type": "error", "msg": "cannot reach the app: " + err.Error()})
		return err
	}
	defer conn.Close()
	sink.c = conn

	done := make(chan struct{})
	go func() { // status ticker
		t := time.NewTicker(time.Second)
		defer t.Stop()
		for {
			select {
			case <-done:
				return
			case <-t.C:
				var st map[string]any
				json.Unmarshal([]byte(eng.StatusJSON()), &st)
				st["type"] = "status"
				lw.send(st)
			}
		}
	}()
	defer close(done)

	r := bufio.NewReaderSize(conn, 64<<10)
	var hdr [2]byte
	for { // app -> engine
		if _, err := io.ReadFull(r, hdr[:]); err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return fmt.Errorf("socket: %w", err)
		}
		n := int(binary.BigEndian.Uint16(hdr[:]))
		if n == 0 {
			continue
		}
		pkt := make([]byte, n)
		if _, err := io.ReadFull(r, pkt); err != nil {
			return fmt.Errorf("socket: %w", err)
		}
		eng.InputPacket(pkt)
	}
}
