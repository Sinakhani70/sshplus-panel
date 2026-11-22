package main

import (
	"flag"
	"fmt"
	"os"
	"os/signal"
	"runtime"
	"syscall"
	"time"
)

func main() {
	noAdmin := flag.Bool("noadmin", false, "do not ask for Administrator rights (VPN mode will not work)")
	noWatchdog := flag.Bool("no-watchdog", false, "keep running even if the UI window is closed")
	noWindow := flag.Bool("no-window", false, "do not open the UI window; print its URL instead")
	connect := flag.String("connect", "", "connect this saved profile right away")
	flag.Parse()

	if runtime.GOOS == "windows" && !*noAdmin && !isAdmin() {
		if relaunchAsAdmin() {
			return
		}
		fmt.Fprintln(os.Stderr, "could not elevate; continuing without Administrator rights")
	}

	app := NewApp()
	cleanupStale(app.logf)
	url, err := app.Serve()
	if err != nil {
		fmt.Fprintln(os.Stderr, "cannot start UI server:", err)
		os.Exit(1)
	}
	app.logf("%s started", appName)
	if *connect != "" {
		go app.Connect(*connect)
	}
	if !*noWatchdog && !*noWindow {
		app.Watchdog(150 * time.Second)
	}
	if *noWindow {
		fmt.Println(url)
	} else {
		openAppWindow(url)
	}

	// Run until interrupted; always undo routes/proxy on the way out.
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	<-sig
	app.Disconnect()
}
