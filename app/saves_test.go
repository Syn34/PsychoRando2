package main

import "testing"

func TestMapPackagesFromSaves(t *testing.T) {
	p := MapPackagesFromSaves("/mnt/user-data/uploads/Psychonauts2/Saved/SaveGames")
	if len(p) == 0 {
		t.Skip("no sample saves")
	}
	has := map[string]bool{}
	for _, x := range p {
		has[x] = true
	}
	for _, want := range []string{"/Game/Maps/HOLL/HOLL_CASINO/HOLL_CASINO", "/Game/Maps/FORB/FORB_Collectibles", "/Game/Maps/LOBO/LOBO"} {
		if !has[want] {
			t.Errorf("missing %s", want)
		}
	}
	t.Logf("%d packages", len(p))
	if levelOfPkg("/Game/Maps/HOLL/HOLL_CASINO/HOLL_CASINO_PILL_DES") != "HOLL_CASINO" {
		t.Error("HOLL grouping")
	}
}
