package main

import (
	"bytes"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestMotherlobeSaveEdit(t *testing.T) {
	base, err := fs.ReadFile(builtinFS, "builtin/"+newGameBaseName)
	if err != nil {
		t.Fatal(err)
	}
	// the base parses and re-serializes byte for byte
	s, err := parseP2Save(base)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(s.bytes(), base) {
		t.Fatal("round trip changed the save")
	}
	if len(s.tail) != 0 {
		t.Fatalf("unparsed tail of %d bytes", len(s.tail))
	}
	q0, _ := QuestStatuses(base)
	if q0[questLoboDone] != questActive || q0[questFrontDesk] != 1 {
		t.Fatalf("unexpected base quests %d %d", q0[questLoboDone], q0[questFrontDesk])
	}

	out, err := MotherlobeTemplate()
	if err != nil {
		t.Fatal(err)
	}
	q, err := QuestStatuses(out)
	if err != nil {
		t.Fatal(err)
	}
	if q[questLoboDone] != questComplete || q[questFrontDesk] != questActive || q["QUEST_LOBO_700_HubBridge"] != questComplete {
		t.Fatal("quests not updated")
	}
	if q["QUEST_HUB1_0000_ROOT"] != questActive || q["QUEST_HUB1_1010_InternStart"] != 1 {
		t.Fatal("unrelated quests changed")
	}
	if len(q) != len(q0) {
		t.Fatal("quest count changed")
	}
	if m := SaveCurrentMap(out); m != hqinMap {
		t.Fatalf("resumes in %q", m)
	}
	if m := SaveCurrentMap(base); m != "/Game/Maps/LOBO/LOBO.LOBO" {
		t.Fatalf("base resumes in %q", m)
	}
	// every other block is untouched
	o, _ := parseP2Save(out)
	for i, sec := range o.sections {
		switch sec.Name {
		case "P2::Managers::PlayerPosition", "P2::Managers::Quests", "P2::Managers::SaveMetaData":
			continue
		}
		if !bytes.Equal(sec.Data, s.sections[i].Data) || sec.Name != s.sections[i].Name {
			t.Fatalf("block %s changed", sec.Name)
		}
	}
	if !bytes.Equal(o.head, s.head) {
		t.Fatal("GVAS properties changed")
	}
	md := o.section("P2::Managers::SaveMetaData").Data
	if !bytes.Contains(md, []byte(hqinMap)) || bytes.Contains(md, []byte("LOBO")) {
		t.Fatal("metadata map not updated")
	}
	_ = time.Now
}

func TestWriteStartingSave(t *testing.T) {
	saves, mod := t.TempDir(), t.TempDir()
	os.MkdirAll(filepath.Join(mod, "seeds"), 0o755)
	tpl, err := MotherlobeTemplate()
	if err != nil {
		t.Fatal(err)
	}
	// leftover .bak files from a deleted save are moved away
	os.WriteFile(filepath.Join(saves, "Psychonauts2Save_2.bak"), []byte("old"), 0o644)
	bdir := filepath.Join(mod, "backups", "x")
	if err := WriteStartingSave(saves, bdir, 2, tpl); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(saves, "Psychonauts2Save_2.bak")); err == nil {
		t.Fatal(".bak left behind")
	}
	if _, err := os.Stat(filepath.Join(bdir, "Psychonauts2Save_2.bak")); err != nil {
		t.Fatal(".bak not backed up")
	}
	for _, n := range []string{"Psychonauts2Save_2.sav", "Psychonauts2Save_C.sav"} {
		if got, _ := os.ReadFile(filepath.Join(saves, n)); !bytes.Equal(got, tpl) {
			t.Fatalf("%s not written", n)
		}
	}
	if err := WriteStartingSave(saves, bdir, 2, tpl); err == nil {
		t.Fatal("overwrote a slot that has a save")
	}
	// untouched tracking
	if SlotUntouched(saves, mod, 2) {
		t.Fatal("untouched without a record")
	}
	RecordStartingSave(mod, 2, tpl)
	if !SlotUntouched(saves, mod, 2) {
		t.Fatal("fresh start not recognised")
	}
	os.WriteFile(filepath.Join(saves, "Psychonauts2Save_C.sav"), append([]byte{}, tpl[:len(tpl)-1]...), 0o644)
	if SlotUntouched(saves, mod, 2) {
		t.Fatal("played slot seen as untouched")
	}
	RemoveUntouchedStart(saves, mod, 2)
	if len(slotFiles(saves, 2)) != 2 {
		t.Fatal("removed a played save")
	}
}
