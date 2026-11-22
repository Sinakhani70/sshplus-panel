package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
)

// Profile is one saved server connection.
type Profile struct {
	Name         string   `json:"name"`
	Host         string   `json:"host"`
	Port         int      `json:"port"`
	User         string   `json:"user"`
	Password     string   `json:"password,omitempty"`
	PrivateKey   string   `json:"privateKey,omitempty"` // PEM text
	Transport    string   `json:"transport"`            // "direct" | "tls"
	SNI          string   `json:"sni,omitempty"`
	UdpgwEnabled bool     `json:"udpgwEnabled"`
	UdpgwAddr    string   `json:"udpgwAddr"` // as seen from the server, default 127.0.0.1:7300
	Mode         string   `json:"mode"`      // "vpn" | "proxy"
	SocksPort    int      `json:"socksPort"`
	DNS          []string `json:"dns,omitempty"`
	HostKey      string   `json:"hostKey,omitempty"` // pinned SHA256 fingerprint (TOFU)
}

func (p *Profile) applyDefaults() {
	if p.Port == 0 {
		p.Port = 22
	}
	if p.Transport == "" {
		p.Transport = "direct"
	}
	if p.UdpgwAddr == "" {
		p.UdpgwAddr = "127.0.0.1:7300"
	}
	if p.Mode == "" {
		p.Mode = "vpn"
	}
	if p.SocksPort == 0 {
		p.SocksPort = 10808
	}
	if len(p.DNS) == 0 {
		p.DNS = []string{"1.1.1.1", "8.8.8.8"}
	}
}

type Store struct {
	mu   sync.Mutex
	path string
	data struct {
		Profiles []*Profile `json:"profiles"`
		Active   string     `json:"active"`
	}
}

func configDir() string {
	d, err := os.UserConfigDir()
	if err != nil || d == "" {
		d = "."
	}
	d = filepath.Join(d, "CKClient")
	_ = os.MkdirAll(d, 0o700)
	return d
}

func OpenStore() *Store {
	s := &Store{path: filepath.Join(configDir(), "profiles.json")}
	if b, err := os.ReadFile(s.path); err == nil {
		_ = json.Unmarshal(b, &s.data)
	}
	return s
}

func (s *Store) save() error {
	b, err := json.MarshalIndent(&s.data, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(s.path, b, 0o600)
}

func (s *Store) List() []*Profile {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]*Profile, len(s.data.Profiles))
	copy(out, s.data.Profiles)
	return out
}

func (s *Store) Get(name string) *Profile {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, p := range s.data.Profiles {
		if p.Name == name {
			c := *p
			return &c
		}
	}
	return nil
}

func (s *Store) Put(p *Profile) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	p.applyDefaults()
	for i, q := range s.data.Profiles {
		if q.Name == p.Name {
			if p.HostKey == "" && q.Host == p.Host && q.Port == p.Port {
				p.HostKey = q.HostKey // keep pin unless the server changed
			}
			s.data.Profiles[i] = p
			return s.save()
		}
	}
	s.data.Profiles = append(s.data.Profiles, p)
	return s.save()
}

func (s *Store) Delete(name string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := s.data.Profiles[:0]
	for _, p := range s.data.Profiles {
		if p.Name != name {
			out = append(out, p)
		}
	}
	s.data.Profiles = out
	return s.save()
}

func (s *Store) PinHostKey(name, fp string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, p := range s.data.Profiles {
		if p.Name == name {
			p.HostKey = fp
		}
	}
	_ = s.save()
}
