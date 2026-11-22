//go:build windows

package main

import (
	"context"
	"errors"
	"fmt"
	"net"
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

// relaunchAsAdmin restarts the program elevated (UAC prompt). Returns true if started.
func relaunchAsAdmin() bool {
	exe, err := os.Executable()
	if err != nil {
		return false
	}
	verb, _ := syscall.UTF16PtrFromString("runas")
	file, _ := syscall.UTF16PtrFromString(exe)
	args, _ := syscall.UTF16PtrFromString(strings.Join(os.Args[1:], " "))
	dir, _ := syscall.UTF16PtrFromString(filepath.Dir(exe))
	return windows.ShellExecute(0, verb, file, args, dir, windows.SW_NORMAL) == nil
}

type route struct{ dest, mask, gw string }

func startVPN(t *Tunnel, p *Profile, logf func(string, ...any)) (func(), error) {
	if !isAdmin() {
		return nil, errors.New("VPN mode needs Administrator rights")
	}
	exe, _ := os.Executable()
	if _, err := os.Stat(filepath.Join(filepath.Dir(exe), "wintun.dll")); err != nil {
		return nil, errors.New("wintun.dll not found next to ck-client.exe - download the amd64 build from https://www.wintun.net and copy it here")
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
	wgtun.WintunTunnelType = "CK Client"
	dev, err := tun.Open(tunName, vpnMTU)
	if err != nil {
		return nil, fmt.Errorf("create adapter: %w", err)
	}
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
	run("netsh", "interface", "ipv4", "set", "interface", tunName, "metric=1")

	addRoute := func(r route, extra ...string) error {
		args := append([]string{"add", r.dest, "mask", r.mask, r.gw, "metric", "1"}, extra...)
		if out, err := run("route", args...); err != nil {
			return fmt.Errorf("route add %s: %v %s", r.dest, err, out)
		}
		added = append(added, r)
		os.WriteFile(stateFile(), []byte(srv+"\n"+gw+"\n"), 0o600)
		return nil
	}
	// the SSH connection itself must keep using the real network
	if !isLocalIP(srv) {
		if err := addRoute(route{srv, "255.255.255.255", gw}, "if", ifidx); err != nil {
			return fail(err)
		}
	}
	for _, r := range []route{{"0.0.0.0", "128.0.0.0", tunGW}, {"128.0.0.0", "128.0.0.0", tunGW}} {
		if err := addRoute(r); err != nil {
			return fail(err)
		}
	}
	// IPv6: send it into the tunnel too so it cannot leak around it (best effort)
	if _, err := run("netsh", "interface", "ipv6", "add", "address", tunName, tunIP6+"/64"); err == nil {
		run("netsh", "interface", "ipv6", "add", "route", "::/1", tunName, "metric=1")
		run("netsh", "interface", "ipv6", "add", "route", "8000::/1", tunName, "metric=1")
	}
	for i, d := range p.DNS {
		if i == 0 {
			run("netsh", "interface", "ipv4", "set", "dnsservers", "name="+tunName, "static", d, "primary", "validate=no")
		} else {
			run("netsh", "interface", "ipv4", "add", "dnsservers", "name="+tunName, d, "index="+strconv.Itoa(i+1), "validate=no")
		}
	}
	run("ipconfig", "/flushdns")
	logf("VPN adapter up, all traffic routed through the tunnel")
	return cleanup, nil
}

func stateFile() string { return filepath.Join(configDir(), "routes.state") }

// cleanupStale removes the host route left behind if a previous run crashed.
func cleanupStale(logf func(string, ...any)) {
	b, err := os.ReadFile(stateFile())
	if err != nil {
		return
	}
	f := strings.Fields(string(b))
	if len(f) == 2 {
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

// openAppWindow shows the UI in an app-style Edge window (always present on Windows 10/11).
func openAppWindow(url string) {
	for _, c := range [][]string{
		{"msedge", "--app=" + url, "--window-size=520,760"},
		{"cmd", "/c", "start", "", url},
	} {
		cmd := exec.Command(c[0], c[1:]...)
		cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
		if cmd.Start() == nil {
			return
		}
	}
}
