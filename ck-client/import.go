package main

import (
	"crypto/tls"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Import of what the CK.VPN panel copies to the clipboard:
//   ssh://user:pass@host:port#name                         (plain, password percent-encoded)
//   ssh://BASE64(user:pass)@host:port#name                 (the panel's "base64 login" variant)
//   ssh://user:pass@host:443?security=tls&sni=dom#name     (SSH over TLS)
//   several of those, one per line, or the whole list base64-encoded (subscription body)
//   https://HOST:2053/s/<token>                             (subscription link: fetched from the panel)

// ImportFromText turns clipboard text into profiles. It fetches subscription
// links over the network, so call it off the UI thread.
func ImportFromText(text string) ([]*Profile, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return nil, errors.New("the clipboard is empty - copy a link from the panel first")
	}
	if !strings.Contains(text, "\n") && (strings.HasPrefix(text, "http://") || strings.HasPrefix(text, "https://")) {
		body, err := fetchSubscription(text)
		if err != nil {
			return nil, fmt.Errorf("could not fetch the subscription link: %w", err)
		}
		text = body
	}
	return ParseLinks(text)
}

// ParseLinks parses ssh:// links (plain text, or a base64 blob containing them).
func ParseLinks(text string) ([]*Profile, error) {
	text = strings.TrimSpace(text)
	if !strings.Contains(text, "ssh://") {
		if dec, ok := decodeB64(text); ok && strings.Contains(dec, "ssh://") {
			text = dec
		}
	}
	var out []*Profile
	var firstErr error
	for _, line := range strings.FieldsFunc(text, func(r rune) bool { return r == '\n' || r == '\r' || r == ' ' || r == '\t' }) {
		if !strings.HasPrefix(line, "ssh://") {
			continue
		}
		p, err := parseLink(line)
		if err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		out = append(out, p)
	}
	if len(out) == 0 {
		if firstErr != nil {
			return nil, firstErr
		}
		return nil, errors.New("no ssh:// link found - copy the account link from the panel (🔗 / SSH link)")
	}
	return out, nil
}

func parseLink(s string) (*Profile, error) {
	u, err := url.Parse(s)
	if err != nil {
		return nil, fmt.Errorf("bad link: %w", err)
	}
	if u.Hostname() == "" || u.User == nil {
		return nil, errors.New("link has no host or login")
	}
	user := u.User.Username()
	pass, hasPass := u.User.Password()
	if !hasPass { // userinfo is base64("user:pass")
		dec, ok := decodeB64(user)
		if !ok || !strings.Contains(dec, ":") {
			return nil, errors.New("link has no password")
		}
		user, pass, _ = strings.Cut(dec, ":")
	}
	port := 22
	if ps := u.Port(); ps != "" {
		n, err := strconv.Atoi(ps)
		if err != nil || n < 1 || n > 65535 {
			return nil, errors.New("bad port in link")
		}
		port = n
	}
	p := &Profile{Host: u.Hostname(), Port: port, User: user, Password: pass, UdpgwEnabled: true}
	q := u.Query()
	if q.Get("security") == "tls" {
		p.Transport = "tls"
		p.SNI = q.Get("sni")
	}
	p.Name = u.Fragment
	if p.Name == "" {
		p.Name = fmt.Sprintf("%s@%s:%d", user, p.Host, port)
	}
	p.applyDefaults()
	return p, nil
}

func decodeB64(s string) (string, bool) {
	s = strings.Map(func(r rune) rune {
		if r == '\n' || r == '\r' || r == ' ' || r == '\t' {
			return -1
		}
		return r
	}, s)
	if s == "" {
		return "", false
	}
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		if b, err := enc.DecodeString(s); err == nil {
			return string(b), true
		}
	}
	return "", false
}

// fetchSubscription downloads the panel's subscription list. The panel's own
// certificate is usually self-signed, so a verified attempt is tried first and
// only then an unverified one (the link already carries the account password,
// so it must be one you copied from your own panel).
func fetchSubscription(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return "", err
	}
	q := u.Query()
	q.Set("fmt", "plain")
	u.RawQuery = q.Encode()
	get := func(insecure bool) (string, error) {
		cl := &http.Client{Timeout: 15 * time.Second, Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: insecure},
		}}
		resp, err := cl.Get(u.String())
		if err != nil {
			return "", err
		}
		defer resp.Body.Close()
		if resp.StatusCode != 200 {
			return "", fmt.Errorf("the panel answered HTTP %d (wrong or expired link?)", resp.StatusCode)
		}
		b, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		return string(b), err
	}
	body, err := get(false)
	if err != nil && u.Scheme == "https" {
		body, err = get(true)
	}
	return body, err
}

// storeImported saves parsed profiles; a profile that is the same account on
// the same server replaces the old one (keeping its other settings), otherwise
// a clashing name gets a numeric suffix. It returns the saved names.
func storeImported(st *Store, profs []*Profile) ([]string, error) {
	var names []string
	for _, p := range profs {
		if old := st.Get(p.Name); old != nil && old.Host == p.Host && old.Port == p.Port && old.User == p.User {
			old.Password, old.PrivateKey = p.Password, ""
			old.Transport, old.SNI = p.Transport, p.SNI
			if err := st.Put(old); err != nil {
				return names, err
			}
			names = append(names, old.Name)
			continue
		}
		base, n := p.Name, 2
		for st.Get(p.Name) != nil {
			p.Name = fmt.Sprintf("%s (%d)", base, n)
			n++
		}
		if err := st.Put(p); err != nil {
			return names, err
		}
		names = append(names, p.Name)
	}
	return names, nil
}
