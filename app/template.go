package main

import (
	"embed"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

//go:embed builtin
var builtinFS embed.FS

const templateName = "template_motherlobe.sav"

// AdoptTemplate copies a Motherlobe starting save captured by the mod into the
// app's own data folder (so it survives mod reinstalls).
func AdoptTemplate(modDataDir string) {
	src := filepath.Join(modDataDir, templateName)
	dst := filepath.Join(AppDataDir(), templateName)
	st, err := os.Stat(src)
	if err != nil || AppDataDir() == "" {
		return
	}
	if dt, err := os.Stat(dst); err == nil && !st.ModTime().After(dt.ModTime()) {
		return
	}
	if b, err := os.ReadFile(src); err == nil && len(b) > 1000 && string(b[:4]) == "GVAS" {
		_ = os.MkdirAll(AppDataDir(), 0o755)
		_ = os.WriteFile(dst, b, 0o644)
		_ = os.Chtimes(dst, st.ModTime(), st.ModTime())
	}
}

// MotherlobeTemplate returns the starting save (app copy first, then built in).
func MotherlobeTemplate(modDataDir string) ([]byte, string) {
	AdoptTemplate(modDataDir)
	if b, err := os.ReadFile(filepath.Join(AppDataDir(), templateName)); err == nil && len(b) > 1000 && string(b[:4]) == "GVAS" {
		return b, "captured"
	}
	if b, err := fs.ReadFile(builtinFS, "builtin/"+templateName); err == nil && len(b) > 1000 && string(b[:4]) == "GVAS" {
		return b, "built-in"
	}
	return nil, ""
}

// WriteStartingSave puts the template into both files of an empty slot.
func WriteStartingSave(saveDir string, slot int, data []byte) error {
	if len(slotFiles(saveDir, slot)) > 0 {
		return fmt.Errorf("slot %d is not empty", slot+1)
	}
	for _, n := range []string{fmt.Sprintf("Psychonauts2Save_%d.sav", slot), fmt.Sprintf("Psychonauts2Save_%c.sav", 'A'+slot)} {
		if err := os.WriteFile(filepath.Join(saveDir, n), data, 0o644); err != nil {
			return err
		}
	}
	return nil
}
