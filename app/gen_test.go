package main

import "testing"

func testData(t *testing.T) *GameData {
	gd, err := LoadGameData("testdata")
	if err != nil {
		t.Fatal(err)
	}
	return gd
}

func solvable(res *SeedResult) bool {
	var locs []*Location
	asg := map[*Location]poolItem{}
	needed := map[string]bool{}
	for _, p := range res.Placements {
		locs = append(locs, p.Loc)
		asg[p.Loc] = poolItem{p.Reward, p.From}
		if p.Loc.Needs != "" {
			needed[p.Loc.Needs] = true
		}
	}
	prog := func(r Reward) string {
		for _, g := range r.Grants {
			if needed[g.Path] {
				return g.Path
			}
		}
		return ""
	}
	reach := reachable(locs, asg, map[string]bool{}, prog)
	return len(reach) == len(locs)
}

func TestLogic(t *testing.T) {
	gd := testData(t)
	for _, l := range gd.Locations {
		if l.Cat == "baggage" && l.Needs == "" {
			t.Fatalf("baggage %s has no tag requirement", l.Key)
		}
	}
	cats := map[string]bool{"bagtag": true, "baggage": true}
	unsolvedNoLogic := 0
	for i := 0; i < 300; i++ {
		seed := "t" + string(rune('a'+i%26)) + string(rune('a'+i/26))
		res, err := Generate(gd, Options{Seed: seed, Categories: cats, Scope: "global", Logic: true})
		if err != nil {
			t.Fatal(err)
		}
		if !solvable(res) {
			t.Fatalf("seed %s unsolvable with logic on", seed)
		}
		res2, _ := Generate(gd, Options{Seed: seed, Categories: cats, Scope: "global", Logic: false})
		if !solvable(res2) {
			unsolvedNoLogic++
		}
	}
	t.Logf("logic off produced %d/300 unsolvable seeds (control)", unsolvedNoLogic)
	if unsolvedNoLogic == 0 {
		t.Fatal("control never unsolvable: check is not detecting anything")
	}
}

func TestDeterministicAndComplete(t *testing.T) {
	gd := testData(t)
	opt := defaultOptions()
	opt.Seed = "Same"
	a, _ := Generate(gd, opt)
	b, _ := Generate(gd, opt)
	seen := map[*Location]int{}
	for i := range a.Placements {
		if a.Placements[i].Loc != b.Placements[i].Loc || a.Placements[i].From != b.Placements[i].From {
			t.Fatal("not deterministic")
		}
		seen[a.Placements[i].From]++
	}
	for l, n := range seen {
		if n != 1 {
			t.Fatalf("reward from %s placed %d times", l.Key, n)
		}
	}
	lv, _ := Generate(gd, Options{Seed: "x", Categories: opt.Categories, Scope: "level", Logic: true})
	for _, p := range lv.Placements {
		if p.From.Group != p.Loc.Group {
			t.Fatal("level scope leaked across levels")
		}
	}
}
