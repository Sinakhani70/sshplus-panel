package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	_ "embed"
)

//go:embed ui/index.html
var indexHTML []byte

const appName = "CK Client"

type App struct {
	store *Store
	logs  LogBuf
	token string

	mu       sync.Mutex
	state    string // idle | connecting | connected | error
	errMsg   string
	active   string
	started  time.Time
	tunnel   *Tunnel
	socks    *Socks
	stopVPN  func()
	sysProxy bool

	lastPoll atomic.Int64
}

func NewApp() *App {
	b := make([]byte, 16)
	rand.Read(b)
	return &App{store: OpenStore(), token: hex.EncodeToString(b), state: "idle"}
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

// ---------- HTTP API (127.0.0.1 only, protected by a random token) ----------

type profileView struct {
	Profile
	Password    string `json:"password"`
	PrivateKey  string `json:"privateKey"`
	HasPassword bool   `json:"hasPassword"`
	HasKey      bool   `json:"hasKey"`
}

func (a *App) Handler(port int) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		w.Write(indexHTML)
	})
	api := func(path string, h func(w http.ResponseWriter, r *http.Request)) {
		mux.HandleFunc(path, func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("X-CK-Token") != a.token {
				http.Error(w, "forbidden", 403)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			h(w, r)
		})
	}
	reply := func(w http.ResponseWriter, v any, err error) {
		if err != nil {
			w.WriteHeader(400)
			json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}
		json.NewEncoder(w).Encode(v)
	}
	api("/api/state", func(w http.ResponseWriter, r *http.Request) {
		a.lastPoll.Store(time.Now().Unix())
		a.mu.Lock()
		st := map[string]any{"state": a.state, "error": a.errMsg, "active": a.active, "logs": a.logs.Snapshot()}
		if a.tunnel != nil {
			st["up"], st["down"] = a.tunnel.Up.Load(), a.tunnel.Down.Load()
			st["link"] = a.tunnel.Connected()
			st["since"] = a.started.Unix()
		}
		a.mu.Unlock()
		json.NewEncoder(w).Encode(st)
	})
	api("/api/profiles", func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case "GET":
			out := []profileView{}
			for _, p := range a.store.List() {
				v := profileView{Profile: *p, HasPassword: p.Password != "", HasKey: p.PrivateKey != ""}
				v.Password, v.PrivateKey = "", ""
				out = append(out, v)
			}
			json.NewEncoder(w).Encode(out)
		case "POST":
			var p Profile
			if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&p); err != nil {
				reply(w, nil, err)
				return
			}
			p.Name, p.Host, p.User = strings.TrimSpace(p.Name), strings.TrimSpace(p.Host), strings.TrimSpace(p.User)
			if p.Name == "" || p.Host == "" || p.User == "" {
				reply(w, nil, errors.New("name, host and username are required"))
				return
			}
			if old := a.store.Get(p.Name); old != nil { // blank secret fields keep the stored value
				if p.Password == "" {
					p.Password = old.Password
				}
				if p.PrivateKey == "" {
					p.PrivateKey = old.PrivateKey
				}
			}
			reply(w, map[string]bool{"ok": true}, a.store.Put(&p))
		case "DELETE":
			reply(w, map[string]bool{"ok": true}, a.store.Delete(r.URL.Query().Get("name")))
		}
	})
	api("/api/connect", func(w http.ResponseWriter, r *http.Request) {
		var req struct{ Name string }
		json.NewDecoder(r.Body).Decode(&req)
		go a.Connect(req.Name)
		json.NewEncoder(w).Encode(map[string]bool{"ok": true})
	})
	api("/api/disconnect", func(w http.ResponseWriter, r *http.Request) {
		go a.Disconnect()
		json.NewEncoder(w).Encode(map[string]bool{"ok": true})
	})
	api("/api/quit", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]bool{"ok": true})
		go func() { a.Disconnect(); os.Exit(0) }()
	})
	api("/api/forget-hostkey", func(w http.ResponseWriter, r *http.Request) {
		var req struct{ Name string }
		json.NewDecoder(r.Body).Decode(&req)
		a.store.PinHostKey(req.Name, "")
		json.NewEncoder(w).Encode(map[string]bool{"ok": true})
	})

	// Reject DNS-rebinding: only accept our exact loopback host.
	want := fmt.Sprintf("127.0.0.1:%d", port)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Host != want {
			http.Error(w, "bad host", 403)
			return
		}
		mux.ServeHTTP(w, r)
	})
}

func (a *App) Serve() (url string, err error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", err
	}
	port := ln.Addr().(*net.TCPAddr).Port
	go http.Serve(ln, a.Handler(port))
	return fmt.Sprintf("http://127.0.0.1:%d/#%s", port, a.token), nil
}

// Watchdog: if the UI window is closed (no polling for a while) undo routes /
// proxy settings and exit, so nothing is left half-configured.
func (a *App) Watchdog(after time.Duration) {
	a.lastPoll.Store(time.Now().Unix())
	go func() {
		for range time.Tick(10 * time.Second) {
			if time.Since(time.Unix(a.lastPoll.Load(), 0)) > after {
				a.logf("UI closed - shutting down")
				a.Disconnect()
				os.Exit(0)
			}
		}
	}()
}
