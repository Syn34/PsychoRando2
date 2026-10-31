package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestMotherlobeStartingSave(t *testing.T) {
	os.RemoveAll(AppDataDir())
	defer os.RemoveAll(AppDataDir())
	mod, saves := t.TempDir(), t.TempDir()
	if b, _ := MotherlobeTemplate(mod); b != nil {
		t.Fatal("template without capture")
	}
	sample, err := os.ReadFile("/mnt/user-data/uploads/Psychonauts2/Saved/SaveGames/Psychonauts2Save_0.sav")
	if err != nil {
		t.Skip("no sample save")
	}
	os.WriteFile(filepath.Join(mod, templateName), sample, 0o644)
	b, src := MotherlobeTemplate(mod)
	if b == nil || src != "captured" {
		t.Fatalf("template not adopted (%s)", src)
	}
	os.RemoveAll(mod) // survives a mod reinstall
	if b, _ := MotherlobeTemplate(t.TempDir()); b == nil {
		t.Fatal("template lost after mod folder wiped")
	}
	if err := WriteStartingSave(saves, 2, b); err != nil {
		t.Fatal(err)
	}
	for _, n := range []string{"Psychonauts2Save_2.sav", "Psychonauts2Save_C.sav"} {
		if got, _ := os.ReadFile(filepath.Join(saves, n)); len(got) != len(sample) {
			t.Fatalf("%s not written", n)
		}
	}
	if err := WriteStartingSave(saves, 2, b); err == nil {
		t.Fatal("overwrote a slot that has a save")
	}
}
