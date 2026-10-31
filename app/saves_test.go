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

func TestCollectedIDsFromSave(t *testing.T) {
	ids := CollectedIDs("/mnt/user-data/uploads/Psychonauts2/Saved/SaveGames", 2)
	if len(ids) == 0 {
		t.Skip("no sample saves")
	}
	for _, want := range []string{"LOBO_VAULT_CHR_Vault_4_3961715615", "COMPT_VAULT_CHR_Vault_2_789017961"} {
		if !ids[want] {
			t.Errorf("missing %s", want)
		}
	}
}
