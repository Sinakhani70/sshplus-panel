// Package ckcore is the mobile core of CK Client: SSH tunnel + BadVPN UDPGW +
// a user-space TCP/IP stack, with a small API that gomobile can bind for iOS
// (and Android). All logic is shared with, and tested like, the Windows app.
//
// Build for iOS (needs macOS + Xcode):  gomobile bind -target ios -o Ckcore.xcframework ./ckcore
package ckcore

import "encoding/json"

// profile is one saved server connection (same JSON as the Windows app).
type profile struct {
	Name         string   `json:"name"`
	Host         string   `json:"host"`
	Port         int      `json:"port"`
	User         string   `json:"user"`
	Password     string   `json:"password,omitempty"`
	PrivateKey   string   `json:"privateKey,omitempty"`
	Transport    string   `json:"transport"` // "direct" | "tls"
	SNI          string   `json:"sni,omitempty"`
	UdpgwEnabled bool     `json:"udpgwEnabled"`
	UdpgwAddr    string   `json:"udpgwAddr"`
	DNS          []string `json:"dns,omitempty"`
	PingTarget   string   `json:"pingTarget,omitempty"`
	HostKey      string   `json:"hostKey,omitempty"`
}

func (p *profile) applyDefaults() {
	if p.Port == 0 {
		p.Port = 22
	}
	if p.Transport == "" {
		p.Transport = "direct"
	}
	if p.UdpgwAddr == "" {
		p.UdpgwAddr = "127.0.0.1:7300"
	}
	if p.PingTarget == "" {
		p.PingTarget = "1.1.1.1:443"
	}
	if len(p.DNS) == 0 {
		p.DNS = []string{"1.1.1.1", "8.8.8.8"}
	}
}

func parseProfileJSON(s string) (*profile, error) {
	var p profile
	if err := json.Unmarshal([]byte(s), &p); err != nil {
		return nil, err
	}
	p.applyDefaults()
	return &p, nil
}
