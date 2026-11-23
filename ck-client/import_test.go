package main

import (
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestParsePlainLink(t *testing.T) {
	ps, err := ParseLinks("ssh://sina:p%40ss%3Aw%2Frd@155.103.69.51:10443#CK.VPN-sina-10443")
	if err != nil || len(ps) != 1 {
		t.Fatal(err, ps)
	}
	p := ps[0]
	if p.User != "sina" || p.Password != "p@ss:w/rd" || p.Host != "155.103.69.51" || p.Port != 10443 || p.Name != "CK.VPN-sina-10443" || p.Transport != "direct" || !p.UdpgwEnabled {
		t.Fatalf("%+v", p)
	}
}

func TestParseBase64LoginAndTLS(t *testing.T) {
	b := base64.StdEncoding.EncodeToString([]byte("u1:pa:ss"))
	ps, err := ParseLinks("ssh://" + strings.ReplaceAll(b, "=", "%3D") + "@example.com:22#x")
	if err != nil || ps[0].User != "u1" || ps[0].Password != "pa:ss" {
		t.Fatal(err, ps)
	}
	ps, err = ParseLinks("ssh://u:p@sub.example.com:443?security=tls&sni=sub.example.com&allowInsecure=1#CK.VPN-u-TLS-443")
	if err != nil || ps[0].Transport != "tls" || ps[0].SNI != "sub.example.com" || ps[0].Port != 443 {
		t.Fatal(err, ps)
	}
}

func TestParseListAndBase64List(t *testing.T) {
	list := "ssh://a:b@h:22#one\nssh://a:b@h:2222#two\n"
	ps, err := ParseLinks(list)
	if err != nil || len(ps) != 2 || ps[1].Port != 2222 {
		t.Fatal(err, ps)
	}
	ps, err = ParseLinks(base64.StdEncoding.EncodeToString([]byte(list)))
	if err != nil || len(ps) != 2 {
		t.Fatal(err, ps)
	}
}

func TestParseErrors(t *testing.T) {
	for _, s := range []string{"", "hello world", "ssh://hostonly", "ssh://u@h:22", "ssh://u:p@h:99999"} {
		if _, err := ParseLinks(s); err == nil {
			t.Errorf("%q should fail", s)
		}
	}
}

func TestSubscriptionURL(t *testing.T) {
	body := "ssh://u:p@h:22#one\n"
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("fmt") != "plain" || r.URL.Path != "/s/tok" {
			http.NotFound(w, r)
			return
		}
		w.Write([]byte(body))
	}))
	defer srv.Close()
	ps, err := ImportFromText(srv.URL + "/s/tok") // self-signed certificate, like the panel
	if err != nil || len(ps) != 1 || ps[0].Host != "h" {
		t.Fatal(err, ps)
	}
	if _, err := ImportFromText(srv.URL + "/s/wrong"); err == nil {
		t.Fatal("expected an error for a bad link")
	}
}

func TestStoreImported(t *testing.T) {
	st := &Store{path: t.TempDir() + "/p.json"}
	a, _ := ParseLinks("ssh://u:one@h:22#acc")
	storeImported(st, a)
	st.Get("acc")
	old := st.Get("acc")
	old.Mode = "proxy"
	st.Put(old)
	// same account again with a new password -> replaced, settings kept
	b, _ := ParseLinks("ssh://u:two@h:22#acc")
	names, _ := storeImported(st, b)
	got := st.Get("acc")
	if len(names) != 1 || got.Password != "two" || got.Mode != "proxy" {
		t.Fatalf("%v %+v", names, got)
	}
	// different server, same name -> suffix
	c, _ := ParseLinks("ssh://u:x@other:22#acc")
	names, _ = storeImported(st, c)
	if names[0] != "acc (2)" {
		t.Fatal(names)
	}
}
