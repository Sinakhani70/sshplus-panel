// ckengine is the CK Client engine as a stand-alone executable (used by the Android app).
//
//	ckengine run   <profile.json> <host:port>   run a VPN session (see ckcore.RunBridge)
//	ckengine parse                               read text from stdin, print profiles JSON (links import)
//	ckengine version
package main

import (
	"fmt"
	"io"
	"os"

	"ckclient/ckcore"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: ckengine run <profile.json> <host:port> | parse | version")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "version":
		fmt.Println(ckcore.Version())
	case "parse":
		b, _ := io.ReadAll(io.LimitReader(os.Stdin, 1<<20))
		out, err := ckcore.ParseLinks(string(b))
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Println(out)
	case "run":
		if len(os.Args) != 4 {
			fmt.Fprintln(os.Stderr, "usage: ckengine run <profile.json> <host:port>")
			os.Exit(2)
		}
		pj, err := os.ReadFile(os.Args[2])
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		os.Remove(os.Args[2]) // the profile holds the password: do not leave it on disk
		ckcore.SetMemoryLimitMB(100)
		if err := ckcore.RunBridge(string(pj), os.Args[3], os.Stdout); err != nil {
			os.Exit(1)
		}
	default:
		fmt.Fprintln(os.Stderr, "unknown command", os.Args[1])
		os.Exit(2)
	}
}
