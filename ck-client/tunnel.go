package main

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/crypto/ssh"
)

// Tunnel keeps one SSH connection to the server alive (auto reconnect) and
// hands out TCP streams and UDP flows through it.
type Tunnel struct {
	p     *Profile
	store *Store
	log   func(string, ...any)

	mu     sync.Mutex
	client *ssh.Client
	ready  chan struct{} // closed while a client is available
	gw     *UDPGW

	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup

	Up, Down  atomic.Int64
	ping      atomic.Int64 // last latency in ms, -1 = unknown
	connected atomic.Bool
	lastErr   atomic.Value // string
}

func NewTunnel(p *Profile, st *Store, logf func(string, ...any)) *Tunnel {
	ctx, cancel := context.WithCancel(context.Background())
	t := &Tunnel{p: p, store: st, log: logf, ctx: ctx, cancel: cancel, ready: make(chan struct{})}
	t.gw = NewUDPGW(t.dialUDPGW)
	t.ping.Store(-1)
	return t
}

func (t *Tunnel) Connected() bool { return t.connected.Load() }
func (t *Tunnel) LastError() string {
	s, _ := t.lastErr.Load().(string)
	return s
}

// Start connects once (so errors such as a wrong password are reported
// immediately) and then keeps the link alive in the background.
func (t *Tunnel) Start() error {
	c, err := t.connect()
	if err != nil {
		t.cancel()
		return err
	}
	t.setClient(c)
	t.wg.Add(2)
	go t.supervise(c)
	go t.pingLoop()
	return nil
}

// PingMs returns the latest latency in milliseconds, or -1 if unknown.
func (t *Tunnel) PingMs() int64 { return t.ping.Load() }

func (t *Tunnel) pingLoop() {
	defer t.wg.Done()
	defer recoverLog()
	tick := time.NewTicker(3 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-t.ctx.Done():
			return
		case <-tick.C:
			if ms, err := t.measurePing(); err == nil {
				t.ping.Store(ms)
			} else {
				t.ping.Store(-1)
			}
		}
	}
}

// measurePing times a TCP connect to the ping target through the tunnel
// (you -> server -> target). With target "off" it times an SSH round trip.
func (t *Tunnel) measurePing() (int64, error) {
	c, err := t.getClient(0)
	if err != nil {
		return -1, err
	}
	type res struct {
		d   time.Duration
		err error
	}
	ch := make(chan res, 1)
	start := time.Now()
	target := t.p.PingTarget
	go func() {
		if target == "" || target == "off" {
			_, _, err := c.SendRequest("keepalive@openssh.com", true, nil)
			ch <- res{time.Since(start), err}
			return
		}
		conn, err := c.Dial("tcp", target)
		d := time.Since(start)
		if conn != nil {
			conn.Close()
		}
		ch <- res{d, err}
	}()
	select {
	case r := <-ch:
		if r.err != nil {
			return -1, r.err
		}
		ms := r.d.Milliseconds()
		if ms < 1 {
			ms = 1
		}
		return ms, nil
	case <-time.After(5 * time.Second):
		return -1, errors.New("ping timeout")
	}
}

func (t *Tunnel) Stop() {
	t.cancel()
	t.gw.Close()
	t.mu.Lock()
	c := t.client
	t.mu.Unlock()
	if c != nil {
		c.Close()
	}
	t.wg.Wait()
	t.connected.Store(false)
}

func (t *Tunnel) setClient(c *ssh.Client) {
	t.mu.Lock()
	t.client = c
	select {
	case <-t.ready:
	default:
		close(t.ready)
	}
	t.mu.Unlock()
	t.connected.Store(true)
	t.lastErr.Store("")
}

func (t *Tunnel) clearClient() {
	t.mu.Lock()
	t.client = nil
	t.ready = make(chan struct{})
	t.mu.Unlock()
	t.connected.Store(false)
	t.gw.Close()
}

func (t *Tunnel) supervise(c *ssh.Client) {
	defer t.wg.Done()
	defer recoverLog()
	backoff := time.Second
	for {
		// keep-alive until the connection dies
		dead := make(chan struct{})
		go func() { c.Wait(); close(dead) }()
		tick := time.NewTicker(15 * time.Second)
	loop:
		for {
			select {
			case <-dead:
				break loop
			case <-t.ctx.Done():
				tick.Stop()
				return
			case <-tick.C:
				done := make(chan error, 1)
				go func() { _, _, err := c.SendRequest("keepalive@openssh.com", true, nil); done <- err }()
				select {
				case err := <-done:
					if err != nil {
						c.Close()
					}
				case <-time.After(10 * time.Second):
					c.Close()
				}
			}
		}
		tick.Stop()
		t.clearClient()
		t.log("SSH connection lost, reconnecting...")
		for {
			select {
			case <-t.ctx.Done():
				return
			case <-time.After(backoff):
			}
			nc, err := t.connect()
			if err != nil {
				t.lastErr.Store(err.Error())
				t.log("reconnect failed: %v", err)
				if backoff < 20*time.Second {
					backoff *= 2
				}
				continue
			}
			backoff = time.Second
			c = nc
			t.setClient(c)
			t.log("SSH reconnected")
			break
		}
	}
}

func (t *Tunnel) connect() (*ssh.Client, error) {
	p := t.p
	var auth []ssh.AuthMethod
	if p.PrivateKey != "" {
		signer, err := ssh.ParsePrivateKey([]byte(p.PrivateKey))
		if err != nil {
			return nil, fmt.Errorf("private key: %w", err)
		}
		auth = append(auth, ssh.PublicKeys(signer))
	}
	if p.Password != "" {
		auth = append(auth, ssh.Password(p.Password),
			ssh.KeyboardInteractive(func(_, _ string, qs []string, _ []bool) ([]string, error) {
				ans := make([]string, len(qs))
				for i := range ans {
					ans[i] = p.Password
				}
				return ans, nil
			}))
	}
	if len(auth) == 0 {
		return nil, errors.New("no password or private key set")
	}
	cfg := &ssh.ClientConfig{
		User:            p.User,
		Auth:            auth,
		HostKeyCallback: t.hostKey,
		Timeout:         15 * time.Second,
		ClientVersion:   "SSH-2.0-CKClient",
	}
	addr := net.JoinHostPort(p.Host, strconv.Itoa(p.Port))
	d := net.Dialer{Timeout: 15 * time.Second, KeepAlive: 30 * time.Second}
	var raw net.Conn
	var err error
	raw, err = d.DialContext(t.ctx, "tcp", addr)
	if err != nil {
		return nil, err
	}
	if p.Transport == "tls" {
		sni := p.SNI
		if sni == "" {
			sni = p.Host
		}
		tc := tls.Client(raw, &tls.Config{ServerName: sni, InsecureSkipVerify: true}) // SSH host key is verified inside
		tc.SetDeadline(time.Now().Add(15 * time.Second))
		if err := tc.Handshake(); err != nil {
			raw.Close()
			return nil, fmt.Errorf("tls: %w", err)
		}
		tc.SetDeadline(time.Time{})
		raw = tc
	}
	raw = &countConn{Conn: raw, up: &t.Up, down: &t.Down}
	sc, chans, reqs, err := ssh.NewClientConn(raw, addr, cfg)
	if err != nil {
		raw.Close()
		return nil, err
	}
	return ssh.NewClient(sc, chans, reqs), nil
}

// hostKey implements trust-on-first-use pinning.
func (t *Tunnel) hostKey(_ string, _ net.Addr, key ssh.PublicKey) error {
	sum := sha256.Sum256(key.Marshal())
	fp := "SHA256:" + base64.RawStdEncoding.EncodeToString(sum[:])
	if t.p.HostKey == "" {
		t.p.HostKey = fp
		t.store.PinHostKey(t.p.Name, fp)
		t.log("pinned host key %s", fp)
		return nil
	}
	if t.p.HostKey != fp {
		return fmt.Errorf("HOST KEY CHANGED (expected %s, got %s) - possible man-in-the-middle; delete the profile's saved key to re-trust", t.p.HostKey, fp)
	}
	return nil
}

// client waits (briefly) for a live SSH connection.
func (t *Tunnel) getClient(wait time.Duration) (*ssh.Client, error) {
	t.mu.Lock()
	c, ready := t.client, t.ready
	t.mu.Unlock()
	if c != nil {
		return c, nil
	}
	select {
	case <-ready:
		t.mu.Lock()
		c = t.client
		t.mu.Unlock()
		if c != nil {
			return c, nil
		}
	case <-time.After(wait):
	case <-t.ctx.Done():
	}
	return nil, errors.New("tunnel is down")
}

// DialTCP opens a stream to host:port from the server's side.
func (t *Tunnel) DialTCP(hostport string) (net.Conn, error) {
	c, err := t.getClient(5 * time.Second)
	if err != nil {
		return nil, err
	}
	return c.Dial("tcp", hostport)
}

func (t *Tunnel) dialUDPGW() (net.Conn, error) {
	return t.DialTCP(t.p.UdpgwAddr)
}

// UDP opens a UDP flow through udpgw.
func (t *Tunnel) UDP(dst string) (*UDPSession, error) {
	ap, err := parseAddrPort(dst)
	if err != nil {
		return nil, err
	}
	return t.gw.Open(ap)
}

type countConn struct {
	net.Conn
	up, down *atomic.Int64
}

func (c *countConn) Read(b []byte) (int, error) {
	n, err := c.Conn.Read(b)
	c.down.Add(int64(n))
	return n, err
}
func (c *countConn) Write(b []byte) (int, error) {
	n, err := c.Conn.Write(b)
	c.up.Add(int64(n))
	return n, err
}
