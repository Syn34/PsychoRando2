//go:build windows

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"

	"github.com/jchv/go-webview2"
	"golang.org/x/sys/windows/registry"
)

func DefaultSaveDir() string {
	return filepath.Join(os.Getenv("LOCALAPPDATA"), "Psychonauts2", "Saved", "SaveGames")
}

var reLibPath = regexp.MustCompile(`"path"\s+"([^"]+)"`)

// DetectGameDir finds Psychonauts 2 in any Steam library.
func DetectGameDir() string {
	var roots []string
	for _, k := range []struct {
		root registry.Key
		path string
		val  string
	}{
		{registry.CURRENT_USER, `Software\Valve\Steam`, "SteamPath"},
		{registry.LOCAL_MACHINE, `SOFTWARE\WOW6432Node\Valve\Steam`, "InstallPath"},
		{registry.LOCAL_MACHINE, `SOFTWARE\Valve\Steam`, "InstallPath"},
	} {
		if key, err := registry.OpenKey(k.root, k.path, registry.QUERY_VALUE); err == nil {
			if v, _, err := key.GetStringValue(k.val); err == nil && v != "" {
				roots = append(roots, filepath.Clean(strings.ReplaceAll(v, "/", `\`)))
			}
			key.Close()
		}
	}
	roots = append(roots, `C:\Program Files (x86)\Steam`, `C:\Program Files\Steam`)
	var libs []string
	for _, r := range roots {
		libs = append(libs, r)
		if b, err := os.ReadFile(filepath.Join(r, "steamapps", "libraryfolders.vdf")); err == nil {
			for _, m := range reLibPath.FindAllStringSubmatch(string(b), -1) {
				libs = append(libs, strings.ReplaceAll(m[1], `\\`, `\`))
			}
		}
	}
	for _, l := range libs {
		p := filepath.Join(l, "steamapps", "common", "Psychonauts 2")
		if fileExists(filepath.Join(p, "Psychonauts2", "Binaries", "Win64")) {
			return p
		}
	}
	return `C:\Program Files (x86)\Steam\steamapps\common\Psychonauts 2`
}

func hiddenCmd(name string, args ...string) *exec.Cmd {
	c := exec.Command(name, args...)
	c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
	return c
}

// BrowseFolder shows the standard Windows folder picker.
func BrowseFolder(title, start string) (string, error) {
	esc := func(s string) string { return strings.ReplaceAll(s, "'", "''") }
	script := `Add-Type -AssemblyName System.Windows.Forms; ` +
		`$f = New-Object System.Windows.Forms.FolderBrowserDialog; ` +
		`$f.Description = '` + esc(title) + `'; $f.ShowNewFolderButton = $false; ` +
		`$f.SelectedPath = '` + esc(start) + `'; ` +
		`$o = New-Object System.Windows.Forms.Form; $o.TopMost = $true; ` +
		`if ($f.ShowDialog($o) -eq 'OK') { [Console]::Out.Write($f.SelectedPath) }`
	out, err := hiddenCmd("powershell", "-NoProfile", "-STA", "-Command", script).Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func OpenURL(target string) error {
	if strings.HasPrefix(target, "steam://") || strings.HasPrefix(target, "http") {
		return hiddenCmd("rundll32", "url.dll,FileProtocolHandler", target).Start()
	}
	if st, err := os.Stat(target); err == nil && !st.IsDir() {
		return exec.Command("notepad.exe", target).Start()
	}
	return exec.Command("explorer.exe", target).Start()
}

func runUI(url string) {
	dataPath := filepath.Join(os.Getenv("LOCALAPPDATA"), "PsychoRando", "WebView2")
	w := webview2.NewWithOptions(webview2.WebViewOptions{
		Debug:     false,
		AutoFocus: true,
		DataPath:  dataPath,
		WindowOptions: webview2.WindowOptions{
			Title: "PsychoRando — Psychonauts 2 Item Randomizer", Width: 1180, Height: 860, Center: true,
		},
	})
	if w == nil {
		// WebView2 runtime missing: fall back to the default browser
		_ = OpenURL(url)
		select {}
	}
	defer w.Destroy()
	w.SetSize(1180, 860, webview2.HintNone)
	w.Navigate(url)
	w.Run()
}
