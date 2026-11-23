package main

import "flag"

func main() {
	connect := flag.String("connect", "", "connect this saved profile right away")
	flag.Parse()
	app := NewApp()
	cleanupStale(app.logf)
	app.logf("%s started", appName)
	runUI(app, *connect)
}
