//go:build !windows

package main

import (
	"fmt"
	"os"
	"os/signal"
	"syscall"
)

// runUI on non-Windows systems is a headless runner used for development.
func runUI(app *App, connect string) {
	if connect != "" {
		go func() {
			if err := app.Connect(connect); err != nil {
				fmt.Fprintln(os.Stderr, err)
			}
		}()
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	<-sig
	app.Disconnect()
}
