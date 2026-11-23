package ckcore

import (
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// ImportText turns text copied from the CK.VPN panel into profiles and returns
// them as a JSON array. It accepts ssh:// links (plain, base64 login, TLS with
// ?security=tls&sni=), several of them (one per line, or base64 of the list)
// and the panel's subscription URL https://HOST:2053/s/<token> (fetched here,
// so call it off the UI thread).
func ImportText(text string) (string, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return "", errors.New("the clipboard is empty - copy a link from the panel first")
	}
	if !strings.Contains(text, "\n") && (strings.HasPrefix(text, "http://") || strings.HasPrefix(text, "https://")) {
		body, err := FetchSubscription(text)
		if err != nil {
			return "", fmt.Errorf("could not fetch the subscription link: %w", err)
		}
		text = body
	}
	ps, err := parseLinks(text)
	if err != nil {
		return "", err
	}
	b, _ := json.Marshal(ps)
	return string(b), nil
}

// ParseLinks parses ssh:// links only (no network) and returns a JSON array.
func ParseLinks(text string) (string, error) {
	ps, err := parseLinks(text)
	if err != nil {
		return "", err
	}
	b, _ := json.Marshal(ps)
	return string(b), nil
}

func parseLinks(text string) ([]*profile, error) {
	text = strings.TrimSpace(text)
	if !strings.Contains(text, "ssh://") {
		if dec, ok := decodeB64(text); ok && strings.Contains(dec, "ssh://") {
			text = dec
		}
	}
	var out []*profile
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
		return nil, errors.New("no ssh:// link found - copy the account link from the panel")
	}
	return out, nil
}

func parseLink(s string) (*profile, error) {
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
	p := &profile{Host: u.Hostname(), Port: port, User: user, Password: pass, UdpgwEnabled: true}
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

// FetchSubscription downloads the panel's subscription list. The panel's own
// certificate is usually self-signed, so a verified attempt is tried first and
// then an unverified one (the link carries the account password: use only a
// link copied from your own panel).
func FetchSubscription(raw string) (string, error) {
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
