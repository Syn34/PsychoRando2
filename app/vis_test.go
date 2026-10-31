package main

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

func TestSeedCarriesVisuals(t *testing.T) {
	gd := LoadBuiltinGameData()
	// give every location a fake recipe naming its own category
	for _, l := range gd.Locations {
		l.Vis = []interface{}{map[string]interface{}{"kind": "static", "mesh": "/Game/" + l.Cat + ".M", "xf": map[string]interface{}{"loc": []interface{}{0.0, 0.0, 0.0}}}}
	}
	gd.FigParams = map[string]interface{}{"FigmentTextureParamName": "Tex"}
	opt := defaultOptions()
	opt.Seed = "vis"
	res, err := Generate(gd, opt)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	sp, _, err := WriteSeed(dir, 0, gd, res)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(sp)
	src := string(b)
	if out, err := exec.Command("luac5.4", "-p", sp).CombinedOutput(); err != nil {
		t.Fatalf("lua syntax: %s", out)
	}
	n, wrong := 0, 0
	for _, p := range res.Placements {
		vis, _, _ := visualFor(p)
		if vis != nil {
			n++
			if !simpleSpot[p.Loc.Cat] || (p.Loc.Cat == "figment" && p.Reward.Cat == "figment") {
				wrong++
			}
			if !strings.Contains(src, `"/Game/`+p.From.Cat+`.M"`) {
				t.Fatalf("recipe for %s missing", p.From.Cat)
			}
		}
	}
	t.Logf("%d spots get the new item's model", n)
	if n == 0 || wrong > 0 {
		t.Fatalf("n=%d wrong=%d", n, wrong)
	}
	if !strings.Contains(src, `figParams = {["FigmentTextureParamName"]="Tex"}`) {
		t.Fatal("figParams missing")
	}
}
