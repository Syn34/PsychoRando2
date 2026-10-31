package main

import (
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
)

//go:embed builtin
var builtinFS embed.FS

// WriteStartingSave puts the starting save into both files of an empty slot.
// Leftover .bak files of a deleted save are moved into backupDir first, so the
// game can't fall back to them.
func WriteStartingSave(saveDir, backupDir string, slot int, data []byte) error {
	if len(slotFiles(saveDir, slot)) > 0 {
		return fmt.Errorf("slot %d is not empty", slot+1)
	}
	for _, n := range []string{fmt.Sprintf("Psychonauts2Save_%d.bak", slot), fmt.Sprintf("Psychonauts2Save_%c.bak", 'A'+slot)} {
		p := filepath.Join(saveDir, n)
		if _, err := os.Stat(p); err == nil {
			if err := os.MkdirAll(backupDir, 0o755); err == nil && copyFile(p, filepath.Join(backupDir, n)) == nil {
				_ = os.Remove(p)
			}
		}
	}
	for _, n := range []string{fmt.Sprintf("Psychonauts2Save_%d.sav", slot), fmt.Sprintf("Psychonauts2Save_%c.sav", 'A'+slot)} {
		if err := os.WriteFile(filepath.Join(saveDir, n), data, 0o644); err != nil {
			return err
		}
	}
	return nil
}

// The hash of the starting save written for a slot is kept next to its seed,
// so an unplayed randomized slot can be re-rolled or un-randomized cleanly.
func startHashPath(modDir string, slot int) string {
	return filepath.Join(modDir, "seeds", fmt.Sprintf("slot_%d_start.sha256", slot))
}

func RecordStartingSave(modDir string, slot int, data []byte) {
	_ = os.WriteFile(startHashPath(modDir, slot), []byte(sha256Hex(data)), 0o644)
}

// SlotUntouched reports whether the slot's files are still exactly the
// starting save PsychoRando wrote (the game hasn't saved over them yet).
func SlotUntouched(saveDir, modDir string, slot int) bool {
	want, err := os.ReadFile(startHashPath(modDir, slot))
	if err != nil || len(want) == 0 {
		return false
	}
	files := slotFiles(saveDir, slot)
	if len(files) == 0 {
		return false
	}
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil || sha256Hex(b) != string(want) {
			return false
		}
	}
	return true
}

// RemoveUntouchedStart deletes an unplayed starting save written by PsychoRando.
func RemoveUntouchedStart(saveDir, modDir string, slot int) {
	if SlotUntouched(saveDir, modDir, slot) {
		for _, f := range slotFiles(saveDir, slot) {
			_ = os.Remove(f)
		}
	}
	_ = os.Remove(startHashPath(modDir, slot))
}

func sha256Hex(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}
