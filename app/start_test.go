package main

import (
	"os"
	"strings"
	"testing"
)

func TestStartMotherlobe(t *testing.T) {
	gd := LoadBuiltinGameData()
	opt := defaultOptions()
	opt.Seed = "ml"
	opt.StartMotherlobe = true
	res, err := Generate(gd, opt)
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range res.Placements {
		if p.Loc.Level == "LOBO" || p.From.Level == "LOBO" {
			t.Fatalf("Loboto spot in the shuffle: %s <- %s", p.Loc.Key, p.From.Key)
		}
	}
	sp, _, err := WriteSeed(t.TempDir(), 0, gd, res)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(sp)
	if !strings.Contains(string(b), `startAt = "motherlobe"`) {
		t.Fatal("seed lacks startAt")
	}
	t.Logf("%d Loboto spots left out, %d shuffled", res.Stats["skippedIntro"], res.Stats["locations"])
	opt.StartMotherlobe = false
	res2, _ := Generate(gd, opt)
	if res2.Stats["skippedIntro"] != 0 {
		t.Fatal("option off still skipped Loboto")
	}
}
