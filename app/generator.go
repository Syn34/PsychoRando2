package main

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"math/rand/v2"
	"sort"
	"strings"
	"time"
)

type Options struct {
	Seed       string          `json:"seed"`
	Categories map[string]bool `json:"categories"`
	Scope      string          `json:"scope"`    // "global" or "level"
	Figments   string          `json:"figments"` // "mixed" or "separate"
	Logic      bool            `json:"logic"`    // keep baggage/tag dependencies solvable
	Levels     map[string]bool `json:"levels"`   // optional: only these levels (nil = all)
}

type Placement struct {
	Loc    *Location
	Reward Reward
	From   *Location // where the reward originally was
}

type SeedResult struct {
	Options    Options
	Placements []Placement
	Created    time.Time
	Stats      map[string]int
}

func rngFor(seed string) *rand.Rand {
	h := sha256.Sum256([]byte("PsychoRando/v1/" + seed))
	return rand.New(rand.NewPCG(binary.LittleEndian.Uint64(h[0:8]), binary.LittleEndian.Uint64(h[8:16])))
}

// Generate shuffles rewards between locations according to the options.
func Generate(gd *GameData, opt Options) (*SeedResult, error) {
	if opt.Seed == "" {
		return nil, fmt.Errorf("seed is empty")
	}
	rng := rngFor(opt.Seed)

	var locs []*Location
	for _, l := range gd.Locations {
		if !opt.Categories[l.Cat] {
			continue
		}
		if opt.Levels != nil && len(opt.Levels) > 0 && !opt.Levels[l.Level] {
			continue
		}
		if len(l.Orig.Grants) == 0 && l.Cat != "figment" {
			continue // unknown original reward: leave this location vanilla
		}
		locs = append(locs, l)
	}
	if len(locs) == 0 {
		return nil, fmt.Errorf("no locations selected")
	}
	// Deterministic base order regardless of map iteration
	sort.Slice(locs, func(i, j int) bool { return locs[i].Key < locs[j].Key })

	// Partition into independent pools
	pools := map[string][]*Location{}
	for _, l := range locs {
		k := "all"
		if opt.Scope == "level" {
			k = l.Group
		}
		if opt.Figments == "separate" && l.Cat == "figment" {
			k = "figment|" + k
		}
		pools[k] = append(pools[k], l)
	}
	keys := make([]string, 0, len(pools))
	for k := range pools {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	res := &SeedResult{Options: opt, Created: time.Now(), Stats: map[string]int{}}
	for _, k := range keys {
		pl, err := fillPool(pools[k], rng, opt.Logic)
		if err != nil {
			return nil, fmt.Errorf("pool %s: %w", k, err)
		}
		res.Placements = append(res.Placements, pl...)
	}
	for _, p := range res.Placements {
		if p.From != p.Loc {
			res.Stats["moved"]++
		}
		if p.From.Level != p.Loc.Level {
			res.Stats["crossLevel"]++
		}
	}
	res.Stats["locations"] = len(res.Placements)
	return res, nil
}

type poolItem struct {
	r    Reward
	from *Location
}

// fillPool places every location's original reward somewhere in the pool.
// Bag tags are placed first with assumed fill so that no baggage ends up
// holding (directly or through a chain) the tag needed to open it.
func fillPool(locs []*Location, rng *rand.Rand, logic bool) ([]Placement, error) {
	needed := map[string]bool{}
	for _, l := range locs {
		if l.Needs != "" {
			needed[l.Needs] = true
		}
	}
	progOf := func(r Reward) string {
		for _, g := range r.Grants {
			if needed[g.Path] {
				return g.Path
			}
		}
		return ""
	}
	var prog, rest []poolItem
	for _, l := range locs {
		it := poolItem{l.Orig, l}
		if logic && progOf(l.Orig) != "" {
			prog = append(prog, it)
		} else {
			rest = append(rest, it)
		}
	}

	for attempt := 0; attempt < 50; attempt++ {
		assigned := map[*Location]poolItem{}
		rng.Shuffle(len(prog), func(i, j int) { prog[i], prog[j] = prog[j], prog[i] })
		ok := true
		for pi := range prog {
			// Assume we own every progression item not yet placed
			owned := map[string]bool{}
			for _, it := range prog[pi+1:] {
				owned[progOf(it.r)] = true
			}
			reach := reachable(locs, assigned, owned, progOf)
			var cands []*Location
			for _, l := range locs {
				if _, used := assigned[l]; !used && reach[l] {
					cands = append(cands, l)
				}
			}
			if len(cands) == 0 {
				ok = false
				break
			}
			assigned[cands[rng.IntN(len(cands))]] = prog[pi]
		}
		if !ok {
			continue
		}
		var free []*Location
		for _, l := range locs {
			if _, used := assigned[l]; !used {
				free = append(free, l)
			}
		}
		rng.Shuffle(len(rest), func(i, j int) { rest[i], rest[j] = rest[j], rest[i] })
		for i, l := range free {
			assigned[l] = rest[i]
		}
		if logic {
			reach := reachable(locs, assigned, map[string]bool{}, progOf)
			for _, l := range locs {
				if !reach[l] {
					ok = false
					break
				}
			}
			if !ok {
				continue
			}
		}
		out := make([]Placement, 0, len(locs))
		for _, l := range locs {
			it := assigned[l]
			out = append(out, Placement{Loc: l, Reward: it.r, From: it.from})
		}
		return out, nil
	}
	return nil, fmt.Errorf("could not find a solvable placement")
}

// reachable returns which locations can be collected given starting items,
// picking up progression items from reachable assigned locations until stable.
func reachable(locs []*Location, assigned map[*Location]poolItem, start map[string]bool, progOf func(Reward) string) map[*Location]bool {
	owned := map[string]bool{}
	for k, v := range start {
		owned[k] = v
	}
	reach := map[*Location]bool{}
	for changed := true; changed; {
		changed = false
		for _, l := range locs {
			if reach[l] || (l.Needs != "" && !owned[l.Needs]) {
				continue
			}
			reach[l] = true
			changed = true
			if it, ok := assigned[l]; ok {
				if p := progOf(it.r); p != "" {
					owned[p] = true
				}
			}
		}
	}
	return reach
}

var _ = strings.TrimSpace
