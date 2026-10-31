// PsychoRando — item randomizer for Psychonauts 2 (PC).
// A small local web UI (shown in a WebView2 window) that installs the
// UE4SS Lua mod, runs the in-game scan, and writes per-save-slot seeds.
package main

import (
	"fmt"
	"os"
)

func main() {
	app := NewApp()
	url, err := startServer(app)
	if err != nil {
		fmt.Fprintln(os.Stderr, "failed to start:", err)
		os.Exit(1)
	}
	runUI(url)
}
