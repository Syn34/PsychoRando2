package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Psychonauts 2 keeps each slot as a pair of files: Psychonauts2Save_<n>.sav
// and Psychonauts2Save_<letter>.sav (0/A, 1/B, 2/C) and writes them alternately.
type SaveSlot struct {
	Index      int       `json:"index"` // 0-based, as the game reports it
	Label      string    `json:"label"` // "Slot 1"
	Exists     bool      `json:"exists"`
	Files      []string  `json:"files"`
	Modified   time.Time `json:"modified"`
	SizeKB     int64     `json:"sizeKB"`
	Areas      []string  `json:"areas"`
	Randomized bool      `json:"randomized"`
	Seed       string    `json:"seed"`
}

var reMapRef = regexp.MustCompile(`/Game/Maps/([A-Za-z0-9_]+)/`)

func slotFiles(dir string, idx int) []string {
	names := []string{fmt.Sprintf("Psychonauts2Save_%d.sav", idx), fmt.Sprintf("Psychonauts2Save_%c.sav", 'A'+idx)}
	var out []string
	for _, n := range names {
		p := filepath.Join(dir, n)
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			out = append(out, p)
		}
	}
	return out
}

func ListSlots(saveDir, modDir string) ([]SaveSlot, error) {
	if st, err := os.Stat(saveDir); err != nil || !st.IsDir() {
		return nil, fmt.Errorf("save folder not found: %s", saveDir)
	}
	var slots []SaveSlot
	for i := 0; i < 3; i++ {
		s := SaveSlot{Index: i, Label: fmt.Sprintf("Slot %d", i+1)}
		files := slotFiles(saveDir, i)
		var newest string
		for _, f := range files {
			st, _ := os.Stat(f)
			s.Files = append(s.Files, filepath.Base(f))
			if st.ModTime().After(s.Modified) {
				s.Modified = st.ModTime()
				s.SizeKB = st.Size() / 1024
				newest = f
			}
		}
		if newest != "" {
			s.Exists = true
			s.Areas = areasInSave(newest)
		}
		if seed := readSeedName(modDir, i); seed != "" {
			s.Randomized = true
			s.Seed = seed
		}
		slots = append(slots, s)
	}
	return slots, nil
}

func areasInSave(path string) []string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, 64<<20))
	if err != nil {
		return nil
	}
	seen := map[string]bool{}
	for _, m := range reMapRef.FindAllSubmatch(data, -1) {
		seen[string(m[1])] = true
	}
	var out []string
	for k := range seen {
		out = append(out, LevelName(k))
	}
	sort.Strings(out)
	return dedupe(out)
}

func dedupe(s []string) []string {
	var out []string
	for i, v := range s {
		if i == 0 || v != s[i-1] {
			out = append(out, v)
		}
	}
	return out
}

var reSeedName = regexp.MustCompile(`seed = "((?:[^"\\]|\\.)*)"`)

func readSeedName(modDir string, slot int) string {
	p := filepath.Join(modDir, "seeds", fmt.Sprintf("slot_%d.lua", slot))
	f, err := os.Open(p)
	if err != nil {
		return ""
	}
	defer f.Close()
	head := make([]byte, 2048)
	n, _ := f.Read(head)
	if m := reSeedName.FindSubmatch(head[:n]); m != nil {
		return string(bytes.ReplaceAll(m[1], []byte(`\"`), []byte(`"`)))
	}
	return "?"
}

var reIDish = regexp.MustCompile(`[A-Za-z0-9_]{12,}`)

// CollectedIDs returns every collectible unique ID the save has recorded as
// collected (the game lists them under P2::Managers::Collectibles). Callers
// intersect this with scanned IDs, so unrelated strings are harmless.
func CollectedIDs(saveDir string, slot int) map[string]bool {
	out := map[string]bool{}
	var newest string
	var newestT time.Time
	for _, f := range slotFiles(saveDir, slot) {
		if st, err := os.Stat(f); err == nil && st.ModTime().After(newestT) {
			newest, newestT = f, st.ModTime()
		}
	}
	if newest == "" {
		return out
	}
	b, err := os.ReadFile(newest)
	if err != nil {
		return out
	}
	for _, m := range reIDish.FindAll(b, -1) {
		out[string(m)] = true
	}
	return out
}

var rePkgRef = regexp.MustCompile(`/Game/Maps/[A-Za-z0-9_/]+`)

// MapPackagesFromSaves collects every level package name mentioned in the
// save files. The in-game scanner uses this as its starting list of maps.
func MapPackagesFromSaves(saveDir string) []string {
	seen := map[string]bool{}
	entries, _ := os.ReadDir(saveDir)
	for _, e := range entries {
		n := strings.ToLower(e.Name())
		if e.IsDir() || !(strings.HasSuffix(n, ".sav") || strings.HasSuffix(n, ".bak")) {
			continue
		}
		b, err := os.ReadFile(filepath.Join(saveDir, e.Name()))
		if err != nil {
			continue
		}
		for _, m := range rePkgRef.FindAll(b, -1) {
			seen[string(m)] = true
		}
	}
	var out []string
	for p := range seen {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// BackupSlot copies a slot's save files into the mod's backups folder.
func BackupSlot(saveDir, modDir string, idx int) (string, error) {
	files := slotFiles(saveDir, idx)
	if len(files) == 0 {
		return "", nil
	}
	dst := filepath.Join(modDir, "backups", fmt.Sprintf("%s_slot%d", time.Now().Format("20060102-150405"), idx+1))
	if err := os.MkdirAll(dst, 0o755); err != nil {
		return "", err
	}
	for _, f := range files {
		if err := copyFile(f, filepath.Join(dst, filepath.Base(f))); err != nil {
			return "", err
		}
	}
	return dst, nil
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
