package main

import (
	"encoding/csv"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// ExportCollectibles writes every scanned collectible to a CSV (UTF-8 with BOM
// so Excel opens it cleanly), including per-save-slot collected status and,
// for randomized slots, what each spot now gives.
func ExportCollectibles(gd *GameData, saveDir, modDir, outPath string) (int, error) {
	collected := make([]map[string]bool, 3)
	exists := make([]bool, 3)
	gives := make([]map[string]string, 3)
	for i := 0; i < 3; i++ {
		exists[i] = len(slotFiles(saveDir, i)) > 0
		collected[i] = CollectedIDs(saveDir, i)
		var sj struct {
			Gives map[string]string `json:"gives"`
		}
		if b, err := os.ReadFile(filepath.Join(modDir, "seeds", fmt.Sprintf("slot_%d.json", i))); err == nil {
			_ = json.Unmarshal(b, &sj)
		}
		gives[i] = sj.Gives
	}

	locs := append([]*Location(nil), gd.Locations...)
	sort.Slice(locs, func(i, j int) bool {
		a, b := locs[i], locs[j]
		if a.Level != b.Level {
			return a.Level < b.Level
		}
		if a.Cat != b.Cat {
			return a.Cat < b.Cat
		}
		return a.Key < b.Key
	})

	if err := os.MkdirAll(filepath.Dir(outPath), 0o755); err != nil {
		return 0, err
	}
	f, err := os.Create(outPath)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	_, _ = f.WriteString("\ufeff")
	w := csv.NewWriter(f)
	header := []string{"Area", "Area code", "Type", "Item", "Item asset", "Requires", "Collectible ID", "Actor", "Map", "X", "Y", "Z"}
	for i := 0; i < 3; i++ {
		header = append(header, fmt.Sprintf("Slot %d collected", i+1))
	}
	for i := 0; i < 3; i++ {
		if gives[i] != nil {
			header = append(header, fmt.Sprintf("Slot %d now gives", i+1))
		}
	}
	_ = w.Write(header)
	for _, l := range locs {
		var assets []string
		for _, g := range l.Orig.Grants {
			assets = append(assets, shortName(g.Path))
		}
		row := []string{LevelName(l.Level), l.Level, singularOr(l.Cat), l.Orig.Label, strings.Join(assets, " + "),
			prettyItem(l.Needs, gd.Items), l.ID, l.Actor, l.Pkg}
		if l.Needs == "" {
			row[5] = ""
		}
		for k := 0; k < 3; k++ {
			if len(l.Pos) == 3 {
				row = append(row, fmt.Sprintf("%.0f", l.Pos[k]))
			} else {
				row = append(row, "")
			}
		}
		for i := 0; i < 3; i++ {
			switch {
			case !exists[i]:
				row = append(row, "")
			case l.ID != "" && collected[i][l.ID]:
				row = append(row, "Yes")
			default:
				row = append(row, "No")
			}
		}
		for i := 0; i < 3; i++ {
			if gives[i] != nil {
				g, ok := gives[i][l.Key]
				if !ok {
					g = "(unchanged)"
				}
				row = append(row, g)
			}
		}
		_ = w.Write(row)
	}
	w.Flush()
	return len(locs), w.Error()
}

func singularOr(cat string) string {
	if s, ok := singular[cat]; ok {
		return s
	}
	return catNames[cat]
}

// CollectedCounts reports, per existing slot, how many scanned collectibles it has collected.
func CollectedCounts(gd *GameData, saveDir string) []map[string]int {
	out := make([]map[string]int, 3)
	for i := 0; i < 3; i++ {
		if len(slotFiles(saveDir, i)) == 0 {
			continue
		}
		ids := CollectedIDs(saveDir, i)
		m := map[string]int{}
		for _, l := range gd.Locations {
			if l.ID != "" && ids[l.ID] {
				m[l.Cat]++
				m["total"]++
			}
		}
		out[i] = m
	}
	return out
}
