package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// ---- Raw records written by the in-game scanner ----

type ScanLoc struct {
	Pkg    string          `json:"pkg"`
	Actor  string          `json:"actor"`
	Class  string          `json:"class"`
	Type   *int            `json:"type"`
	ID     string          `json:"id"`
	Comp   string          `json:"comp"`
	Grants [][]interface{} `json:"grants"`
	Refs   [][]string      `json:"refs"`
	Loc    []float64       `json:"loc"`
	Loot   bool            `json:"loot"`
}

type ScanItem struct {
	Path    string `json:"path"`
	Class   string `json:"class"`
	Name    string `json:"name"`
	Max     int    `json:"max"`
	Missing bool   `json:"missing"`
}

// ---- Normalised model used by the generator ----

type Grant struct {
	Path   string `json:"path"`
	Amount int    `json:"amount"`
}

// Reward is the "item" that moves between locations: whatever a location
// originally gave, as one bundle.
type Reward struct {
	Cat    string  `json:"cat"`
	Label  string  `json:"label"`
	Grants []Grant `json:"grants"`
}

type Location struct {
	Key     string   `json:"key"`     // primary key (id:... or pa:...)
	Aliases []string `json:"aliases"` // all keys that identify this location at runtime
	Cat     string   `json:"cat"`
	Level   string   `json:"level"` // map folder, e.g. FORB
	Group   string   `json:"group"` // area group used for "within level" mode
	Pkg     string   `json:"pkg"`
	Actor   string   `json:"actor"`
	Class   string   `json:"class"`
	Orig    Reward   `json:"orig"`
	Needs   string   `json:"needs,omitempty"` // item path required to collect (bag tag for baggage)
}

type GameData struct {
	Locations []*Location
	Items     map[string]ScanItem // by object path
	Warnings  []string
}

var catByType = map[int]string{
	0: "figment", 1: "psitanium", 2: "psimarker", 3: "keyitem", 4: "vault", 5: "baggage",
	6: "nugget", 7: "psicard", 8: "psicore", 9: "supplychest", 10: "halfamind", 11: "bagtag",
	12: "supplykey",
}

// Categories the user can toggle, in display order.
var Categories = []struct {
	ID, Name    string
	Default     bool
	Description string
}{
	{"figment", "Figments", true, "Every figment in every mind"},
	{"psicard", "PSI Cards", true, "PSI Challenge Cards"},
	{"psimarker", "PSI Challenge Markers", true, "Rank-up markers found in the world"},
	{"halfamind", "Half-a-Minds", true, "Mental energy upgrades"},
	{"supplykey", "Supply Chest Keys", true, "Keys that open supply chests"},
	{"vault", "Memory Vaults", true, "The walking safes"},
	{"nugget", "Nuggets of Wisdom", true, "Rank-up nuggets"},
	{"bagtag", "Bag Tags", true, "Tags that let you sort emotional baggage"},
	{"baggage", "Emotional Baggage", true, "What sorting a bag rewards you with"},
	{"scavenger", "Scavenger Hunt Items", true, "Otto's scavenger hunt list"},
	{"supplychest", "Supply Chests", false, "Contents of supply chests (experimental)"},
}

var catNames = func() map[string]string {
	m := map[string]string{"keyitem": "Story Key Item", "psitanium": "Psitanium", "psicore": "PSI Core"}
	for _, c := range Categories {
		m[c.ID] = c.Name
	}
	return m
}()

// Level folder -> area group & friendly name
var levelNames = map[string]string{
	"LOBO": "Loboto's Labyrinth", "HQIN": "Motherlobe", "QUAR": "Questionable Area", "QAEX": "Questionable Area (Outskirts)",
	"HUB2": "Green Needle Gulch", "HOLL": "Hollis' Classroom", "HOLL_CASINO": "Hollis' Hot Streak", "HOLL_CLASS": "Hollis' Classroom",
	"HOLL_REAL_A": "Hollis' Hospital", "HOLL_REAL_B": "Hollis' Hospital (B)", "COMPT": "Compton's Cookoff", "FORB": "Strike City",
	"FORC": "Ford's Sanctuary", "FORG": "Ford's Sanctuary (Graveyard)", "FORH": "Ford's Sanctuary (Lighthouse)", "FORV": "Ford's Sanctuary (Vista)",
	"CASS": "Cassie's Collection", "HELM": "PSI King's Sensorium", "BOBZ": "Bob's Bottles", "GRIS": "Fatherland Follies",
	"MALI": "Lucrecia's Lament", "BOSS_MALI": "Lucrecia's Lament (Boss)", "COLU": "Collective Unconscious",
}

func LevelName(code string) string {
	if n, ok := levelNames[code]; ok {
		return n
	}
	for k, n := range levelNames {
		if strings.HasPrefix(code, k+"_") {
			return n
		}
	}
	return code
}

func readJSONL[T any](path string) ([]T, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out []T
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1024*1024), 16*1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var v T
		if err := json.Unmarshal([]byte(line), &v); err != nil {
			continue // a crash can leave one partial line; skip it
		}
		out = append(out, v)
	}
	return out, sc.Err()
}

func levelOfPkg(pkg string) string {
	// /Game/Maps/FORB/FORB_Collectibles -> FORB
	parts := strings.Split(strings.TrimPrefix(pkg, "/Game/Maps/"), "/")
	if len(parts) > 2 && strings.EqualFold(parts[0], "HOLL") {
		return strings.ToUpper(parts[1]) // Hollis' areas are nested: HOLL/HOLL_CASINO/...
	}
	if len(parts) > 0 {
		return strings.ToUpper(parts[0])
	}
	return "?"
}

func shortName(path string) string {
	// /Game/A/B/INV_X.INV_X -> INV_X
	if i := strings.LastIndex(path, "."); i >= 0 {
		return path[i+1:]
	}
	return filepath.Base(path)
}

var reCamel = regexp.MustCompile(`([a-z])([A-Z])`)

func prettyItem(path string, items map[string]ScanItem) string {
	if it, ok := items[path]; ok && it.Name != "" {
		return it.Name
	}
	n := shortName(path)
	for _, p := range []string{"SCAVHUNTITEM_", "INV_VAULT_", "INV_BagTag_", "INV_SortedBag_", "INV_Unique_", "INV_"} {
		n = strings.TrimPrefix(n, p)
	}
	n = strings.ReplaceAll(n, "_", " ")
	return reCamel.ReplaceAllString(n, "$1 $2")
}

// Finds catalogue items whose short name matches a predicate
func findItems(items map[string]ScanItem, pred func(up string) bool) []string {
	var out []string
	for p := range items {
		if pred(strings.ToUpper(shortName(p))) {
			out = append(out, p)
		}
	}
	sort.Strings(out)
	return out
}

func firstItem(items map[string]ScanItem, pred func(up string) bool) string {
	l := findItems(items, pred)
	if len(l) > 0 {
		return l[0]
	}
	return ""
}

// Baggage/tag group codes: Ford's maps (FOR*) share FORD, Hollis maps share HOLL
func baggageGroup(level string) string {
	switch {
	case strings.HasPrefix(level, "FOR"):
		return "FORD"
	case strings.HasPrefix(level, "HOLL"):
		return "HOLL"
	}
	return level
}

var bagTypes = []struct{ key, match string }{
	{"SUITCASE", "SUITCASE"}, {"DUFFLE", "DUFFLE"}, {"STEAMER", "STEAMER"}, {"HATBOX", "HATBOX"}, {"PURSE", "PURSE"},
}

func bagTypeOf(s string) string {
	up := strings.ToUpper(strings.ReplaceAll(s, "_", ""))
	for _, b := range bagTypes {
		if strings.Contains(up, b.match) {
			return b.key
		}
	}
	return ""
}

// LoadGameData reads the scanner output from the mod's data folder.
func LoadGameData(dataDir string) (*GameData, error) {
	locs, err := readJSONL[ScanLoc](filepath.Join(dataDir, "scan_locations.jsonl"))
	if err != nil {
		return nil, fmt.Errorf("no scan data yet (%v)", err)
	}
	rawItems, _ := readJSONL[ScanItem](filepath.Join(dataDir, "scan_items.jsonl"))
	gd := &GameData{Items: map[string]ScanItem{}}
	for _, it := range rawItems {
		gd.Items[it.Path] = it
	}
	return buildGameData(gd, locs), nil
}

func buildGameData(gd *GameData, locs []ScanLoc) *GameData {
	items := gd.Items
	// Count IDs so that only truly unique IDs are used as keys
	idCount := map[string]int{}
	for _, l := range locs {
		if l.ID != "" && l.ID != "None" {
			idCount[l.ID+"|"+levelOfPkg(l.Pkg)]++
		}
	}

	byKey := map[string]*Location{}
	var order []string
	for _, l := range locs {
		if l.Type == nil {
			continue
		}
		cat, ok := catByType[*l.Type]
		if !ok {
			continue
		}
		level := levelOfPkg(l.Pkg)
		var grants []Grant
		for _, g := range l.Grants {
			if len(g) < 2 {
				continue
			}
			p, _ := g[0].(string)
			n := 0
			switch v := g[1].(type) {
			case float64:
				n = int(v)
			}
			if p != "" && p != "None" && n > 0 {
				grants = append(grants, Grant{p, n})
			}
		}
		if cat == "keyitem" {
			for _, g := range grants {
				if strings.Contains(strings.ToUpper(g.Path), "SCAVHUNT") {
					cat = "scavenger"
				}
			}
		}
		pa := "pa:" + l.Pkg + "|" + l.Actor
		key := pa
		if l.ID != "" && l.ID != "None" {
			key = "id:" + l.ID
		}
		if ex, ok := byKey[key]; ok {
			// Same collectible placed in a variant sublevel (e.g. post-complete): one location, two instances
			ex.Aliases = appendUnique(ex.Aliases, pa)
			if len(ex.Orig.Grants) == 0 && len(grants) > 0 {
				ex.Orig.Grants = grants
			}
			continue
		}
		loc := &Location{
			Key: key, Aliases: []string{key}, Cat: cat, Level: level, Group: level,
			Pkg: l.Pkg, Actor: l.Actor, Class: l.Class,
			Orig: Reward{Cat: cat, Grants: grants},
		}
		if pa != key {
			loc.Aliases = append(loc.Aliases, pa)
		}
		// refs from the actor's own properties (e.g. which bag/tag a baggage uses)
		for _, r := range l.Refs {
			if len(r) == 2 && strings.Contains(r[1], "/Inventory/") {
				up := strings.ToUpper(r[1])
				if cat == "baggage" && strings.Contains(up, "BAGTAG") && loc.Needs == "" {
					loc.Needs = r[1]
				}
				if cat == "baggage" && strings.Contains(up, "SORTEDBAG") && len(loc.Orig.Grants) == 0 {
					loc.Orig.Grants = []Grant{{r[1], 1}}
				}
				if cat == "vault" && strings.Contains(up, "INV_VAULT") && len(loc.Orig.Grants) == 0 {
					loc.Orig.Grants = []Grant{{r[1], 1}}
				}
			}
		}
		byKey[key] = loc
		order = append(order, key)
	}

	// Fill in rewards that are granted from Blueprint code rather than the pickup component
	generic := map[string]string{
		"halfamind": firstItem(items, func(u string) bool { return strings.HasPrefix(u, "INV_MIND_HP") }),
		"psicard":   firstItem(items, func(u string) bool { return u == "INV_PSICHALLENGECARD" }),
		"psimarker": firstItem(items, func(u string) bool { return u == "INV_PSIMARKER" }),
		"nugget":    firstItem(items, func(u string) bool { return u == "INV_NUGGETOFWISDOM" }),
		"supplykey": firstItem(items, func(u string) bool { return strings.HasPrefix(u, "INV_SUPPLYCHESTKEY") }),
	}
	vaultPool := map[string][]string{}  // level -> vault items not yet claimed
	sortedPool := map[string][]string{} // group|type -> sorted bag items
	tagByGroupType := map[string]string{}
	for p := range items {
		up := strings.ToUpper(shortName(p))
		switch {
		case strings.HasPrefix(up, "INV_VAULT_"):
			lv := strings.TrimPrefix(up, "INV_VAULT_")
			if i := strings.LastIndex(lv, "_"); i > 0 {
				lv = lv[:i]
			}
			vaultPool[lv] = append(vaultPool[lv], p)
		case strings.HasPrefix(up, "INV_SORTEDBAG_"):
			parts := strings.Split(up, "_")
			g := parts[len(parts)-1]
			sortedPool[g+"|"+bagTypeOf(up)] = append(sortedPool[g+"|"+bagTypeOf(up)], p)
		case strings.HasPrefix(up, "INV_BAGTAG_"):
			parts := strings.Split(up, "_")
			g := parts[len(parts)-1]
			tagByGroupType[g+"|"+bagTypeOf(up)] = p
		}
	}
	claimed := map[string]bool{}
	for _, k := range order {
		for _, g := range byKey[k].Orig.Grants {
			claimed[g.Path] = true
		}
	}
	take := func(pool []string) string {
		for _, p := range pool {
			if !claimed[p] {
				claimed[p] = true
				return p
			}
		}
		return ""
	}
	for _, k := range order {
		loc := byKey[k]
		if len(loc.Orig.Grants) > 0 {
			continue
		}
		switch loc.Cat {
		case "halfamind", "psicard", "psimarker", "nugget", "supplykey":
			if p := generic[loc.Cat]; p != "" {
				loc.Orig.Grants = []Grant{{p, 1}}
			}
		case "vault":
			pool := vaultPool[loc.Level]
			if len(pool) == 0 {
				pool = vaultPool[baggageGroup(loc.Level)]
			}
			sort.Strings(pool)
			if p := take(pool); p != "" {
				loc.Orig.Grants = []Grant{{p, 1}}
			}
		case "baggage":
			bt := bagTypeOf(loc.Class)
			pool := sortedPool[baggageGroup(loc.Level)+"|"+bt]
			if len(pool) == 0 {
				pool = sortedPool[loc.Level+"|"+bt]
			}
			if p := take(pool); p != "" {
				loc.Orig.Grants = []Grant{{p, 1}}
			}
		}
	}
	// Baggage needs its matching tag
	for _, k := range order {
		loc := byKey[k]
		if loc.Cat != "baggage" || loc.Needs != "" {
			continue
		}
		bt := bagTypeOf(loc.Class)
		if t, ok := tagByGroupType[baggageGroup(loc.Level)+"|"+bt]; ok {
			loc.Needs = t
		} else if t, ok := tagByGroupType[loc.Level+"|"+bt]; ok {
			loc.Needs = t
		}
	}

	missing := map[string]int{}
	for _, k := range order {
		loc := byKey[k]
		loc.Orig.Label = rewardLabel(loc.Orig, items)
		if len(loc.Orig.Grants) == 0 && loc.Cat != "figment" {
			missing[loc.Cat]++
		}
		gd.Locations = append(gd.Locations, loc)
	}
	for c, n := range missing {
		gd.Warnings = append(gd.Warnings, fmt.Sprintf("%d %s locations: original reward unknown", n, catNames[c]))
	}
	sort.Strings(gd.Warnings)
	return gd
}

var singular = map[string]string{"figment": "Figment", "psicard": "PSI Card", "psimarker": "PSI Challenge Marker",
	"halfamind": "Half-a-Mind", "supplykey": "Supply Chest Key", "vault": "Memory Vault", "nugget": "Nugget of Wisdom",
	"bagtag": "Bag Tag", "baggage": "Emotional Baggage", "scavenger": "Scavenger Hunt Item", "supplychest": "Supply Chest"}

func rewardLabel(r Reward, items map[string]ScanItem) string {
	if len(r.Grants) == 0 {
		if s, ok := singular[r.Cat]; ok {
			return s
		}
		return catNames[r.Cat]
	}
	var parts []string
	for _, g := range r.Grants {
		s := prettyItem(g.Path, items)
		if g.Amount > 1 {
			s = fmt.Sprintf("%s x%d", s, g.Amount)
		}
		parts = append(parts, s)
	}
	l := strings.Join(parts, " + ")
	if r.Cat == "figment" && !strings.Contains(strings.ToLower(l), "figment") {
		l = "Figment (" + l + ")"
	}
	return l
}

func appendUnique(s []string, v string) []string {
	for _, x := range s {
		if x == v {
			return s
		}
	}
	return append(s, v)
}

// Summary for the UI: counts per category and per level
type DataSummary struct {
	Total      int            `json:"total"`
	ByCategory map[string]int `json:"byCategory"`
	ByLevel    map[string]int `json:"byLevel"`
	Items      int            `json:"items"`
	Warnings   []string       `json:"warnings"`
}

func (gd *GameData) Summary() DataSummary {
	s := DataSummary{ByCategory: map[string]int{}, ByLevel: map[string]int{}, Items: len(gd.Items), Warnings: gd.Warnings}
	for _, l := range gd.Locations {
		s.Total++
		s.ByCategory[l.Cat]++
		s.ByLevel[l.Level]++
	}
	return s
}
