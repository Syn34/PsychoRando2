package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestAdoptScan(t *testing.T) {
	mod := t.TempDir()
	app := AppDataDir()
	defer os.RemoveAll(app)
	os.RemoveAll(app)
	// no completed scan: nothing adopted, built-in used
	if AdoptScan(mod) {
		t.Fatal("adopted without scan_done")
	}
	if gd := LoadActiveGameData(mod); gd.Source != "built-in" || len(gd.Locations) != 1611 {
		t.Fatalf("source=%s n=%d", gd.Source, len(gd.Locations))
	}
	// completed scan: adopted and used
	for _, f := range []string{"scan_locations.jsonl", "scan_items.jsonl", "figment_params.json", "scan_done.txt"} {
		b, _ := os.ReadFile(filepath.Join("builtin", f))
		os.WriteFile(filepath.Join(mod, f), b, 0o644)
	}
	if !AdoptScan(mod) {
		t.Fatal("not adopted")
	}
	gd := LoadActiveGameData(mod)
	if gd.Source != "latest scan" || len(gd.Locations) != 1611 || gd.FigParams["FigmentTextureParamName"] != "Texture" {
		t.Fatalf("source=%s n=%d fp=%v", gd.Source, len(gd.Locations), gd.FigParams)
	}
	// same scan again: no re-copy; mod folder wiped: app copy still used
	if AdoptScan(mod) {
		t.Fatal("re-adopted unchanged scan")
	}
	os.RemoveAll(mod)
	if gd := LoadActiveGameData(mod); gd.Source != "latest scan" {
		t.Fatal("lost the scan after the mod folder was wiped")
	}
	// a newer but empty/failed scan never replaces good data
	os.MkdirAll(mod, 0o755)
	os.WriteFile(filepath.Join(mod, "scan_locations.jsonl"), []byte(""), 0o644)
	os.WriteFile(filepath.Join(mod, "scan_done.txt"), []byte("{}"), 0o644)
	future := time.Now().Add(time.Hour)
	os.Chtimes(filepath.Join(mod, "scan_done.txt"), future, future)
	if AdoptScan(mod) {
		t.Fatal("empty scan replaced good data")
	}
	vis := 0
	for _, l := range LoadBuiltinGameData().Locations {
		if len(l.Vis) > 0 {
			vis++
		}
	}
	if vis != 1611 {
		t.Fatalf("built-in visuals: %d", vis)
	}
}
