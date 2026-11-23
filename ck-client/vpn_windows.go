//go:build windows

package main

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/xjasonlyu/tun2socks/v2/core"
	"github.com/xjasonlyu/tun2socks/v2/core/device/tun"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
	wgtun "golang.zx2c4.com/wireguard/tun"
)

const (
	tunName = "CK Client"
	tunIP   = "10.77.0.2"
	tunGW   = "10.77.0.1"
	tunIP6  = "fd77:77::2"
)

func run(name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func isAdmin() bool {
	var sid *windows.SID
	if err := windows.AllocateAndInitializeSid(&windows.SECURITY_NT_AUTHORITY, 2,
		windows.SECURITY_BUILTIN_DOMAIN_RID, windows.DOMAIN_ALIAS_RID_ADMINS, 0, 0, 0, 0, 0, 0, &sid); err != nil {
		return false
	}
	defer windows.FreeSid(sid)
	m, err := windows.Token(0).IsMember(sid)
	return err == nil && m
}

const (
	wintunURL  = "https://www.wintun.net/builds/wintun-0.14.1.zip"
	wintunSHA  = "07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51"
	wintunHelp = "download wintun.dll (amd64) from https://www.wintun.net and put it next to ck-client.exe"
)

// ensureWintun makes sure wintun.dll sits next to the exe, downloading the
// official build (checked against a pinned SHA-256) when it is missing.
func ensureWintun(logf func(string, ...any)) error {
	exe, _ := os.Executable()
	dst := filepath.Join(filepath.Dir(exe), "wintun.dll")
	if _, err := os.Stat(dst); err == nil {
		return nil
	}
	logf("wintun.dll not found - downloading the official build...")
	cl := &http.Client{Timeout: 60 * time.Second}
	resp, err := cl.Get(wintunURL)
	if err != nil {
		return fmt.Errorf("wintun.dll missing and download failed (%v); %s", err, wintunHelp)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil || resp.StatusCode != 200 {
		return fmt.Errorf("wintun.dll missing and download failed (HTTP %d); %s", resp.StatusCode, wintunHelp)
	}
	if sum := sha256.Sum256(body); hex.EncodeToString(sum[:]) != wintunSHA {
		return fmt.Errorf("downloaded wintun archive failed its checksum, refusing to use it; %s", wintunHelp)
	}
	zr, err := zip.NewReader(bytes.NewReader(body), int64(len(body)))
	if err != nil {
		return err
	}
	for _, f := range zr.File {
		if f.Name == "wintun/bin/amd64/wintun.dll" {
			rc, err := f.Open()
			if err != nil {
				return err
			}
			defer rc.Close()
			dll, err := io.ReadAll(rc)
			if err != nil {
				return err
			}
			if err := os.WriteFile(dst, dll, 0o644); err != nil {
				return fmt.Errorf("cannot save wintun.dll: %v; %s", err, wintunHelp)
			}
			logf("wintun.dll installed")
			return nil
		}
	}
	return errors.New("wintun archive has an unexpected layout; " + wintunHelp)
}

type route struct{ dest, mask, gw string }

func startVPN(t *Tunnel, p *Profile, logf func(string, ...any)) (func(), error) {
	if !isAdmin() {
		return nil, errors.New("VPN mode needs Administrator rights")
	}
	if err := ensureWintun(logf); err != nil {
		return nil, err
	}

	// 1. where does the server live, and which gateway do we use to reach it?
	srv, err := resolveV4(p.Host)
	if err != nil {
		return nil, fmt.Errorf("resolve %s: %w", p.Host, err)
	}
	gw, ifidx, err := defaultGateway()
	if err != nil {
		return nil, fmt.Errorf("cannot find default gateway: %w", err)
	}
	logf("server %s via gateway %s (if %s)", srv, gw, ifidx)

	// 2. create the TUN adapter + netstack
	cleanupStale(logf)
	logf("creating the virtual adapter...")
	wgtun.WintunTunnelType = "CK Client"
	dev, err := tun.Open(tunName, vpnMTU)
	if err != nil {
		return nil, fmt.Errorf("create adapter: %w", err)
	}
	logf("adapter created, starting network stack...")
	stack, err := core.CreateStack(&core.Config{
		LinkEndpoint:     dev,
		TransportHandler: &vpnHandler{t: t, useGW: p.UdpgwEnabled, logf: logf},
	})
	if err != nil {
		dev.Close()
		return nil, fmt.Errorf("create stack: %w", err)
	}

	var added []route
	cleanup := func() {
		for i := len(added) - 1; i >= 0; i-- {
			r := added[i]
			run("route", "delete", r.dest, "mask", r.mask, r.gw)
		}
		removeNRPT()
		stack.Close()
		dev.Close()
		os.Remove(stateFile())
	}
	fail := func(err error) (func(), error) { cleanup(); return nil, err }

	// 3. address, routes, DNS
	var lastErr error
	for i := 0; i < 15; i++ { // adapter needs a moment before netsh sees it
		_, lastErr = run("netsh", "interface", "ipv4", "set", "address", "name="+tunName,
			"source=static", "address="+tunIP, "mask=255.255.255.0")
		if lastErr == nil {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if lastErr != nil {
		return fail(fmt.Errorf("set adapter address: %w", lastErr))
	}
	logf("adapter address %s set", tunIP)
	run("netsh", "interface", "ipv4", "set", "interface", tunName, "metric=1")

	tunIdx := ""
	for i := 0; i < 20 && tunIdx == ""; i++ {
		if ifc, err := net.InterfaceByName(tunName); err == nil {
			tunIdx = strconv.Itoa(ifc.Index)
		} else {
			time.Sleep(300 * time.Millisecond)
		}
	}
	if tunIdx == "" {
		return fail(errors.New("adapter \"" + tunName + "\" did not appear"))
	}
	logf("adapter %s index %s", tunName, tunIdx)

	addRoute := func(r route, extra ...string) error {
		args := append([]string{"add", r.dest, "mask", r.mask, r.gw, "metric", "1"}, extra...)
		if out, err := run("route", args...); err != nil {
			return fmt.Errorf("route add %s: %v %s", r.dest, err, out)
		}
		added = append(added, r)
		os.WriteFile(stateFile(), []byte(srv+"\n"+gw+"\nnrpt\n"), 0o600)
		return nil
	}
	logf("adding routes...")
	// the SSH connection itself must keep using the real network
	if !isLocalIP(srv) {
		if err := addRoute(route{srv, "255.255.255.255", gw}, "if", ifidx); err != nil {
			return fail(err)
		}
	}
	for _, r := range []route{{"0.0.0.0", "128.0.0.0", tunGW}, {"128.0.0.0", "128.0.0.0", tunGW}} {
		if err := addRoute(r, "if", tunIdx); err != nil {
			return fail(err)
		}
	}
	logf("routes added (server via %s, everything else via the tunnel)", gw)
	// IPv6: send it into the tunnel too so it cannot leak around it (best effort)
	if _, err := run("netsh", "interface", "ipv6", "add", "address", tunName, tunIP6+"/64"); err == nil {
		run("netsh", "interface", "ipv6", "add", "route", "::/1", tunName, "metric=1")
		run("netsh", "interface", "ipv6", "add", "route", "8000::/1", tunName, "metric=1")
	}
	logf("setting adapter DNS...")
	for i, d := range p.DNS {
		if i == 0 {
			run("netsh", "interface", "ipv4", "set", "dnsservers", "name="+tunName, "static", d, "primary", "validate=no")
		} else {
			run("netsh", "interface", "ipv4", "add", "dnsservers", "name="+tunName, d, "index="+strconv.Itoa(i+1), "validate=no")
		}
	}
	logf("forcing DNS through the tunnel (takes a few seconds)...")
	// Windows asks every adapter's DNS in parallel and the ISP's (often poisoned)
	// answer wins; a catch-all NRPT rule makes it use only our DNS servers.
	if len(p.DNS) > 0 {
		quoted := make([]string, len(p.DNS))
		for i, d := range p.DNS {
			quoted[i] = "'" + strings.ReplaceAll(d, "'", "") + "'"
		}
		if out, err := run("powershell", "-NoProfile", "-NonInteractive", "-Command",
			"Add-DnsClientNrptRule -Namespace '.' -NameServers "+strings.Join(quoted, ",")+" -Comment 'CKClient'"); err != nil {
			logf("warning: could not force DNS through the tunnel: %v %s", err, out)
		} else {
			logf("DNS forced through the tunnel (%s)", strings.Join(p.DNS, ", "))
		}
	}
	go run("ipconfig", "/flushdns") // can stall right after the DNS rule changes - never block on it
	logf("VPN adapter up, all traffic routed through the tunnel")
	go selfTest(t, logf)
	return cleanup, nil
}

func removeNRPT() {
	run("powershell", "-NoProfile", "-NonInteractive", "-Command",
		"Get-DnsClientNrptRule | Where-Object { $_.Comment -eq 'CKClient' } | Remove-DnsClientNrptRule -Force")
	run("ipconfig", "/flushdns")
}

// selfTest logs the exit IP seen through the SSH tunnel and the one seen by a
// normal Windows connection; if they differ the OS routes are not effective.
func selfTest(t *Tunnel, logf func(string, ...any)) {
	defer recoverLog()
	time.Sleep(2 * time.Second)
	trace := func(c net.Conn) string {
		defer c.Close()
		c.SetDeadline(time.Now().Add(8 * time.Second))
		fmt.Fprint(c, "GET /cdn-cgi/trace HTTP/1.1\r\nHost: 1.1.1.1\r\nConnection: close\r\n\r\n")
		b, _ := io.ReadAll(c)
		for _, l := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(l, "ip=") {
				return strings.TrimSpace(strings.TrimPrefix(l, "ip="))
			}
		}
		first, _, _ := strings.Cut(string(b), "\n")
		logf("self-test: no IP in the reply (got %d bytes, first line: %q)", len(b), strings.TrimSpace(first))
		return ""
	}
	var viaSSH, viaOS string
	if c, err := t.DialTCP("1.1.1.1:80"); err != nil {
		logf("self-test: server refused to forward TCP (%v) - check AllowTcpForwarding on the server", err)
	} else {
		viaSSH = trace(c)
		logf("self-test: exit IP through the SSH tunnel: %s", viaSSH)
	}
	if c, err := net.DialTimeout("tcp", "1.1.1.1:80", 8*time.Second); err != nil {
		logf("self-test: normal Windows connection failed: %v", err)
	} else {
		viaOS = trace(c)
		logf("self-test: exit IP seen by Windows apps: %s", viaOS)
	}
	if viaSSH != "" && viaOS != "" && viaSSH != viaOS {
		logf("WARNING: Windows traffic is NOT going through the tunnel. Routing table:")
		if out, err := run("route", "print", "-4"); err == nil {
			for _, l := range strings.Split(out, "\n") {
				if f := strings.Fields(l); len(f) >= 5 && (strings.HasPrefix(l, "          0.0.0.0") || strings.HasPrefix(l, "        128.0.0.0") || strings.Contains(l, tunGW)) {
					logf("  %s", strings.Join(f, " "))
				}
			}
		}
	} else if viaSSH != "" && viaSSH == viaOS {
		logf("self-test OK: Windows traffic leaves through the server")
	}
}

func stateFile() string { return filepath.Join(configDir(), "routes.state") }

// cleanupStale removes the host route left behind if a previous run crashed.
func cleanupStale(logf func(string, ...any)) {
	b, err := os.ReadFile(stateFile())
	if err != nil {
		return
	}
	f := strings.Fields(string(b))
	if len(f) == 3 {
		removeNRPT()
	}
	if len(f) >= 2 {
		run("route", "delete", f[0], "mask", "255.255.255.255", f[1])
		logf("removed stale route to %s", f[0])
	}
	os.Remove(stateFile())
}

func resolveV4(host string) (string, error) {
	if ip := net.ParseIP(host); ip != nil && ip.To4() != nil {
		return host, nil
	}
	ips, err := net.LookupIP(host)
	if err != nil {
		return "", err
	}
	for _, ip := range ips {
		if v4 := ip.To4(); v4 != nil {
			return v4.String(), nil
		}
	}
	return "", errors.New("no IPv4 address")
}

func isLocalIP(s string) bool {
	ip := net.ParseIP(s)
	return ip != nil && ip.IsLoopback()
}

// defaultGateway asks Windows for the best IPv4 default route.
func defaultGateway() (gw, ifIndex string, err error) {
	out, err := run("powershell", "-NoProfile", "-NonInteractive", "-Command",
		`$r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 | Where-Object { $_.NextHop -ne '0.0.0.0' -and $_.InterfaceAlias -ne '`+tunName+`' } | Sort-Object { $_.RouteMetric + (Get-NetIPInterface -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4).InterfaceMetric } | Select-Object -First 1; "$($r.NextHop) $($r.InterfaceIndex)"`)
	if err != nil {
		return "", "", fmt.Errorf("%v: %s", err, out)
	}
	f := strings.Fields(out)
	if len(f) != 2 {
		return "", "", errors.New("no default route (not connected to a network?)")
	}
	return f[0], f[1], nil
}

// ---- system proxy (proxy mode convenience) ----

const inetKey = `Software\Microsoft\Windows\CurrentVersion\Internet Settings`

func setSystemProxy(port int) error {
	k, err := registry.OpenKey(registry.CURRENT_USER, inetKey, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer k.Close()
	k.SetDWordValue("ProxyEnable", 1)
	k.SetStringValue("ProxyServer", "socks=127.0.0.1:"+strconv.Itoa(port))
	return nil
}

func clearSystemProxy() error {
	k, err := registry.OpenKey(registry.CURRENT_USER, inetKey, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer k.Close()
	return k.SetDWordValue("ProxyEnable", 0)
}
