package main

import (
	"errors"
	"fmt"
	"sync"
	"time"
)

const appName = "CK Client"

type App struct {
	store *Store
	logs  LogBuf

	mu       sync.Mutex
	state    string // idle | connecting | connected | error
	errMsg   string
	active   string
	started  time.Time
	tunnel   *Tunnel
	socks    *Socks
	stopVPN  func()
	sysProxy bool
}

func NewApp() *App {
	return &App{store: OpenStore(), state: "idle"}
}

func (a *App) logf(f string, args ...any) { a.logs.Add(fmt.Sprintf(f, args...)) }

func (a *App) Connect(name string) error {
	a.mu.Lock()
	if a.state == "connecting" || a.state == "connected" {
		a.mu.Unlock()
		return errors.New("already connected")
	}
	a.state, a.errMsg, a.active = "connecting", "", name
	a.mu.Unlock()

	err := a.connect(name)
	a.mu.Lock()
	defer a.mu.Unlock()
	if err != nil {
		a.state, a.errMsg = "error", err.Error()
		a.logf("connect failed: %v", err)
		return err
	}
	a.state, a.started = "connected", time.Now()
	return nil
}

func (a *App) connect(name string) error {
	p := a.store.Get(name)
	if p == nil {
		return errors.New("profile not found")
	}
	a.logf("connecting to %s:%d as %s (%s, mode %s, udpgw %v)", p.Host, p.Port, p.User, p.Transport, p.Mode, p.UdpgwEnabled)
	t := NewTunnel(p, a.store, a.logf)
	if err := t.Start(); err != nil {
		return err
	}
	a.logf("SSH connected")
	if p.UdpgwEnabled {
		// verify udpgw is reachable so the user learns now, not when a game lags
		if c, err := t.DialTCP(p.UdpgwAddr); err != nil {
			a.logf("WARNING: udpgw %s is not reachable on the server: %v (UDP will not work)", p.UdpgwAddr, err)
		} else {
			c.Close()
			a.logf("udpgw reachable at %s", p.UdpgwAddr)
		}
	}
	switch p.Mode {
	case "vpn":
		stop, err := startVPN(t, p, a.logf)
		if err != nil {
			t.Stop()
			return err
		}
		a.mu.Lock()
		a.tunnel, a.stopVPN = t, stop
		a.mu.Unlock()
	default:
		s, err := StartSocks(t, p.SocksPort)
		if err != nil {
			t.Stop()
			return err
		}
		a.logf("SOCKS5 proxy listening on 127.0.0.1:%d (TCP + UDP)", p.SocksPort)
		if err := setSystemProxy(p.SocksPort); err == nil {
			a.sysProxy = true
		}
		a.mu.Lock()
		a.tunnel, a.socks = t, s
		a.mu.Unlock()
	}
	return nil
}

func (a *App) Disconnect() {
	a.mu.Lock()
	t, s, stop, sp := a.tunnel, a.socks, a.stopVPN, a.sysProxy
	a.tunnel, a.socks, a.stopVPN, a.sysProxy = nil, nil, nil, false
	a.state, a.errMsg = "idle", ""
	a.mu.Unlock()
	if sp {
		clearSystemProxy()
	}
	if s != nil {
		s.Close()
	}
	if stop != nil {
		stop()
	}
	if t != nil {
		t.Stop()
	}
	a.logf("disconnected")
}

// Snapshot is what the UI shows.
type Snapshot struct {
	State, Err, Active string
	Up, Down           int64
	Link               bool
	Since              time.Time
	Logs               []string
}

func (a *App) Snapshot() Snapshot {
	a.mu.Lock()
	defer a.mu.Unlock()
	s := Snapshot{State: a.state, Err: a.errMsg, Active: a.active, Since: a.started, Logs: a.logs.Snapshot()}
	if a.tunnel != nil {
		s.Up, s.Down, s.Link = a.tunnel.Up.Load(), a.tunnel.Down.Load(), a.tunnel.Connected()
	}
	return s
}
