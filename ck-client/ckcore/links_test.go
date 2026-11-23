package ckcore

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func parse(t *testing.T, s string) []profile {
	out, err := ParseLinks(s)
	if err != nil {
		t.Fatal(err)
	}
	var ps []profile
	if err := json.Unmarshal([]byte(out), &ps); err != nil {
		t.Fatal(err)
	}
	return ps
}

func TestParsePlainLink(t *testing.T) {
	p := parse(t, "ssh://sina:p%40ss%3Aw%2Frd@155.103.69.51:10443#CK.VPN-sina-10443")[0]
	if p.User != "sina" || p.Password != "p@ss:w/rd" || p.Host != "155.103.69.51" || p.Port != 10443 || p.Name != "CK.VPN-sina-10443" || p.Transport != "direct" || !p.UdpgwEnabled {
		t.Fatalf("%+v", p)
	}
}

func TestParseBase64LoginAndTLS(t *testing.T) {
	b := base64.StdEncoding.EncodeToString([]byte("u1:pa:ss"))
	p := parse(t, "ssh://"+strings.ReplaceAll(b, "=", "%3D")+"@example.com:22#x")[0]
	if p.User != "u1" || p.Password != "pa:ss" {
		t.Fatalf("%+v", p)
	}
	p = parse(t, "ssh://u:p@sub.example.com:443?security=tls&sni=sub.example.com&allowInsecure=1#CK.VPN-u-TLS-443")[0]
	if p.Transport != "tls" || p.SNI != "sub.example.com" || p.Port != 443 {
		t.Fatalf("%+v", p)
	}
}

func TestParseListAndBase64List(t *testing.T) {
	list := "ssh://a:b@h:22#one\nssh://a:b@h:2222#two\n"
	if ps := parse(t, list); len(ps) != 2 || ps[1].Port != 2222 {
		t.Fatal(ps)
	}
	if ps := parse(t, base64.StdEncoding.EncodeToString([]byte(list))); len(ps) != 2 {
		t.Fatal(ps)
	}
}

func TestParseErrors(t *testing.T) {
	for _, s := range []string{"", "hello world", "ssh://hostonly", "ssh://u@h:22", "ssh://u:p@h:99999"} {
		if _, err := ParseLinks(s); err == nil {
			t.Errorf("%q should fail", s)
		}
	}
}

func TestImportSubscriptionURL(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("fmt") != "plain" || r.URL.Path != "/s/tok" {
			http.NotFound(w, r)
			return
		}
		w.Write([]byte("ssh://u:p@h:22#one\n"))
	}))
	defer srv.Close()
	out, err := ImportText(srv.URL + "/s/tok") // self-signed, like the panel
	if err != nil || !strings.Contains(out, `"host":"h"`) {
		t.Fatal(out, err)
	}
	if _, err := ImportText(srv.URL + "/s/wrong"); err == nil {
		t.Fatal("expected an error")
	}
}
