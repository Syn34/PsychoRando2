package main

import (
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

//go:embed modfiles
var modFS embed.FS

const ModName = "PsychoRando"

type Paths struct {
	GameDir string `json:"gameDir"`
	SaveDir string `json:"saveDir"`
}

func (p Paths) Win64() string {
	return filepath.Join(p.GameDir, "Psychonauts2", "Binaries", "Win64")
}
func (p Paths) ModsDir() string { return filepath.Join(p.Win64(), "Mods") }
func (p Paths) ModDir() string  { return filepath.Join(p.ModsDir(), ModName) }
func (p Paths) DataDir() string { return filepath.Join(p.ModDir(), "data") }

type InstallState struct {
	GameFound    bool   `json:"gameFound"`
	UE4SSFound   bool   `json:"ue4ssFound"`
	ModInstalled bool   `json:"modInstalled"`
	ModEnabled   bool   `json:"modEnabled"`
	InstalledVer string `json:"installedVersion"`
	BundledVer   string `json:"bundledVersion"`
	NeedsUpdate  bool   `json:"needsUpdate"`
}

func bundledVersion() string {
	b, err := modFS.ReadFile("modfiles/PsychoRando/Scripts/main.lua")
	if err != nil {
		return "?"
	}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.Contains(line, "local VERSION") {
			if i := strings.Index(line, `"`); i >= 0 {
				rest := line[i+1:]
				if j := strings.Index(rest, `"`); j >= 0 {
					return rest[:j]
				}
			}
		}
	}
	return "?"
}

func installedVersion(p Paths) string {
	b, err := os.ReadFile(filepath.Join(p.ModDir(), "Scripts", "main.lua"))
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.Contains(line, "local VERSION") {
			if i := strings.Index(line, `"`); i >= 0 {
				rest := line[i+1:]
				if j := strings.Index(rest, `"`); j >= 0 {
					return rest[:j]
				}
			}
		}
	}
	return "?"
}

func fileExists(p string) bool { _, err := os.Stat(p); return err == nil }

func GetInstallState(p Paths) InstallState {
	s := InstallState{BundledVer: bundledVersion()}
	s.GameFound = fileExists(filepath.Join(p.Win64(), "Psychonauts2-Win64-Shipping.exe"))
	s.UE4SSFound = fileExists(filepath.Join(p.Win64(), "UE4SS.dll")) || fileExists(filepath.Join(p.Win64(), "ue4ss", "UE4SS.dll"))
	s.InstalledVer = installedVersion(p)
	s.ModInstalled = s.InstalledVer != ""
	s.NeedsUpdate = s.ModInstalled && s.InstalledVer != s.BundledVer
	if b, err := os.ReadFile(filepath.Join(p.ModsDir(), "mods.txt")); err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			t := strings.TrimSpace(strings.TrimPrefix(line, "\ufeff"))
			if strings.HasPrefix(t, ModName) && strings.HasSuffix(strings.ReplaceAll(t, " ", ""), ":1") {
				s.ModEnabled = true
			}
		}
	}
	if fileExists(filepath.Join(p.ModDir(), "enabled.txt")) {
		s.ModEnabled = true
	}
	return s
}

// InstallMod copies the bundled Lua mod into the game's UE4SS Mods folder
// and enables it in mods.txt (keeping the built-in Keybinds entry last).
func versionLess(a, b string) bool {
	pa, pb := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < len(pa) || i < len(pb); i++ {
		var x, y int
		if i < len(pa) {
			fmt.Sscan(pa[i], &x)
		}
		if i < len(pb) {
			fmt.Sscan(pb[i], &y)
		}
		if x != y {
			return x < y
		}
	}
	return false
}

func InstallMod(p Paths) error {
	if !fileExists(p.Win64()) {
		return fmt.Errorf("game not found at %s", p.GameDir)
	}
	if iv := installedVersion(p); iv != "" && iv != "?" && versionLess(bundledVersion(), iv) {
		return fmt.Errorf("a newer mod (%s) is already installed than this app contains (%s); use the newer PsychoRando.exe", iv, bundledVersion())
	}
	if err := os.MkdirAll(p.ModsDir(), 0o755); err != nil {
		return err
	}
	err := fs.WalkDir(modFS, "modfiles", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel := strings.TrimPrefix(path, "modfiles")
		rel = strings.TrimPrefix(rel, "/")
		if rel == "" {
			return nil
		}
		dst := filepath.Join(p.ModsDir(), filepath.FromSlash(rel))
		if d.IsDir() {
			return os.MkdirAll(dst, 0o755)
		}
		b, err := modFS.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(dst, b, 0o644)
	})
	if err != nil {
		return err
	}
	// files older versions left behind
	for _, f := range []string{"Scripts/luac.out", "data/template_motherlobe.sav", "data/template_motherlobe.json", "data/debug_menu.txt"} {
		_ = os.Remove(filepath.Join(p.ModDir(), filepath.FromSlash(f)))
	}
	for _, d := range []string{"data", "seeds", "backups"} {
		if err := os.MkdirAll(filepath.Join(p.ModDir(), d), 0o755); err != nil {
			return err
		}
	}
	return enableInModsTxt(p)
}

func enableInModsTxt(p Paths) error {
	path := filepath.Join(p.ModsDir(), "mods.txt")
	b, err := os.ReadFile(path)
	if err != nil {
		// No mods.txt: UE4SS also honours enabled.txt inside the mod folder
		return os.WriteFile(filepath.Join(p.ModDir(), "enabled.txt"), nil, 0o644)
	}
	text := string(b)
	bom := strings.HasPrefix(text, "\ufeff")
	text = strings.TrimPrefix(text, "\ufeff")
	nl := "\n"
	if strings.Contains(text, "\r\n") {
		nl = "\r\n"
	}
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	var out []string
	inserted := false
	for _, l := range lines {
		t := strings.TrimSpace(l)
		if strings.HasPrefix(t, ModName+" ") || strings.HasPrefix(t, ModName+":") {
			continue // re-added below
		}
		if !inserted && (strings.HasPrefix(t, "; Built-in keybinds") || strings.HasPrefix(t, "Keybinds")) {
			out = append(out, ModName+" : 1")
			inserted = true
		}
		out = append(out, l)
	}
	if !inserted {
		out = append(out, ModName+" : 1")
	}
	res := strings.Join(out, nl)
	if bom {
		res = "\ufeff" + res
	}
	return os.WriteFile(path, []byte(res), 0o644)
}

// ---- persistent app config ----

type Config struct {
	Paths   Paths   `json:"paths"`
	Options Options `json:"options"`
}

func configPath() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		dir = "."
	}
	return filepath.Join(dir, "PsychoRando", "config.json")
}

func LoadConfig() Config {
	var c Config
	if b, err := os.ReadFile(configPath()); err == nil {
		_ = json.Unmarshal(b, &c)
	}
	return c
}

func SaveConfig(c Config) {
	_ = os.MkdirAll(filepath.Dir(configPath()), 0o755)
	b, _ := json.MarshalIndent(c, "", "  ")
	_ = os.WriteFile(configPath(), b, 0o644)
}
