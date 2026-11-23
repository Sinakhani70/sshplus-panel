package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime/debug"
	"time"
)

// recoverLog is deferred at the top of every background goroutine: a panic there
// is written to crash.log (next to profiles.json) instead of silently ending the program.
func recoverLog() {
	if r := recover(); r != nil {
		f, err := os.OpenFile(filepath.Join(configDir(), "crash.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
		if err == nil {
			fmt.Fprintf(f, "%s panic: %v\n%s\n", time.Now().Format(time.RFC3339), r, debug.Stack())
			f.Close()
		}
	}
}
