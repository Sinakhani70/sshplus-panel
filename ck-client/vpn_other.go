//go:build !windows

package main

import "errors"

func startVPN(t *Tunnel, p *Profile, logf func(string, ...any)) (func(), error) {
	return nil, errors.New("VPN mode is only available on Windows; use proxy mode")
}

func isAdmin() bool                          { return true }
func relaunchAsAdmin() bool                  { return false }
func setSystemProxy(port int) error          { return nil }
func clearSystemProxy() error                { return nil }
func cleanupStale(logf func(string, ...any)) {}
func openAppWindow(url string)               {}
