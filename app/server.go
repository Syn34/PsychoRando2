package main

import (
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

//go:embed ui
var uiFS embed.FS

type App struct {
	mu  sync.Mutex
	cfg Config
}

func NewApp() *App {
	a := &App{cfg: LoadConfig()}
	if a.cfg.Paths.GameDir == "" || !fileExists(Paths{GameDir: a.cfg.Paths.GameDir}.Win64()) {
		a.cfg.Paths.GameDir = DetectGameDir()
	}
	if a.cfg.Paths.SaveDir == "" {
		a.cfg.Paths.SaveDir = DefaultSaveDir()
	}
	return a
}

func writeJSON(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, err error) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(400)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
}

func readBody(r *http.Request, v interface{}) error {
	defer r.Body.Close()
	return json.NewDecoder(r.Body).Decode(v)
}

type ScanStatus struct {
	Requested bool                   `json:"requested"`
	Done      bool                   `json:"done"`
	HasData   bool                   `json:"hasData"`
	Status    map[string]interface{} `json:"status"`
	Summary   *DataSummary           `json:"summary,omitempty"`
	Collected []map[string]int       `json:"collected,omitempty"`
	Export    string                 `json:"export,omitempty"`
	Source    string                 `json:"source"`
}

func (a *App) exportPath() string {
	exe, err := os.Executable()
	if err != nil {
		return filepath.Join(a.cfg.Paths.ModDir(), "PsychoRando_collectibles.csv")
	}
	return filepath.Join(filepath.Dir(exe), "PsychoRando_collectibles.csv")
}

func (a *App) scanStatus() ScanStatus {
	p := a.cfg.Paths
	s := ScanStatus{}
	s.Requested = fileExists(filepath.Join(p.ModDir(), "scan_request.txt"))
	s.Done = fileExists(filepath.Join(p.DataDir(), "scan_done.txt"))
	s.HasData = fileExists(filepath.Join(p.DataDir(), "scan_locations.jsonl"))
	if b, err := os.ReadFile(filepath.Join(p.DataDir(), "scan_status.json")); err == nil {
		_ = json.Unmarshal(b, &s.Status)
	}
	{
		if gd := LoadActiveGameData(p.DataDir()); gd != nil {
			s.Source = gd.Source
			sum := gd.Summary()
			s.Summary = &sum
			s.Collected = CollectedCounts(gd, p.SaveDir)
			// write the export automatically the first time a finished scan is seen
			out := a.exportPath()
			doneSt, _ := os.Stat(filepath.Join(p.DataDir(), "scan_done.txt"))
			outSt, err := os.Stat(out)
			if err != nil || (doneSt != nil && gd.Source == "your scan" && outSt.ModTime().Before(doneSt.ModTime())) {
				_, _ = ExportCollectibles(gd, p.SaveDir, p.ModDir(), out)
			}
			if fileExists(out) {
				s.Export = out
			}
		}
	}
	return s
}

func defaultOptions() Options {
	o := Options{Scope: "global", Figments: "mixed", Logic: true, Categories: map[string]bool{}}
	for _, c := range Categories {
		o.Categories[c.ID] = c.Default
	}
	return o
}

func (a *App) routes() http.Handler {
	mux := http.NewServeMux()
	sub, _ := fs.Sub(uiFS, "ui")
	mux.Handle("/", http.FileServer(http.FS(sub)))

	mux.HandleFunc("/api/state", func(w http.ResponseWriter, r *http.Request) {
		a.mu.Lock()
		defer a.mu.Unlock()
		p := a.cfg.Paths
		slots, slotErr := ListSlots(p.SaveDir, p.ModDir())
		opts := a.cfg.Options
		if opts.Categories == nil {
			opts = defaultOptions()
		}
		resp := map[string]interface{}{
			"paths":      p,
			"install":    GetInstallState(p),
			"slots":      slots,
			"scan":       a.scanStatus(),
			"options":    opts,
			"categories": Categories,
		}
		if slotErr != nil {
			resp["slotError"] = slotErr.Error()
		}
		writeJSON(w, resp)
	})

	mux.HandleFunc("/api/paths", func(w http.ResponseWriter, r *http.Request) {
		var p Paths
		if err := readBody(r, &p); err != nil {
			writeErr(w, err)
			return
		}
		a.mu.Lock()
		if p.GameDir != "" {
			a.cfg.Paths.GameDir = strings.TrimSpace(p.GameDir)
		}
		if p.SaveDir != "" {
			a.cfg.Paths.SaveDir = strings.TrimSpace(p.SaveDir)
		}
		SaveConfig(a.cfg)
		a.mu.Unlock()
		writeJSON(w, map[string]bool{"ok": true})
	})

	mux.HandleFunc("/api/browse", func(w http.ResponseWriter, r *http.Request) {
		var req struct{ Start, Title string }
		_ = readBody(r, &req)
		dir, err := BrowseFolder(req.Title, req.Start)
		if err != nil {
			writeErr(w, err)
			return
		}
		writeJSON(w, map[string]string{"path": dir})
	})

	mux.HandleFunc("/api/install", func(w http.ResponseWriter, r *http.Request) {
		a.mu.Lock()
		defer a.mu.Unlock()
		if err := InstallMod(a.cfg.Paths); err != nil {
			writeErr(w, err)
			return
		}
		writeJSON(w, GetInstallState(a.cfg.Paths))
	})

	mux.HandleFunc("/api/scan/request", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Fresh bool `json:"fresh"`
			Full  bool `json:"full"`
		}
		_ = readBody(r, &req)
		a.mu.Lock()
		defer a.mu.Unlock()
		p := a.cfg.Paths
		if err := InstallMod(p); err != nil {
			writeErr(w, err)
			return
		}
		// progress files from mod versions before 0.1.9 have no "ok" lines and can't be resumed
		if b, err := os.ReadFile(filepath.Join(p.DataDir(), "scan_progress.txt")); err == nil && !strings.Contains(string(b), "\nok ") && !strings.HasPrefix(string(b), "ok ") {
			req.Fresh = true
		}
		if req.Fresh {
			for _, f := range []string{"scan_locations.jsonl", "scan_items.jsonl", "scan_progress.txt", "scan_done.txt", "scan_status.json", "scan_worlds.txt"} {
				_ = os.Remove(filepath.Join(p.DataDir(), f))
			}
		}
		_ = os.Remove(filepath.Join(p.DataDir(), "scan_done.txt"))
		mode := "normal"
		if req.Full {
			mode = "full"
		}
		req2 := mode + "\n" + strings.Join(MapPackagesFromSaves(p.SaveDir), "\n") + "\n"
		if err := os.WriteFile(filepath.Join(p.ModDir(), "scan_request.txt"), []byte(req2), 0o644); err != nil {
			writeErr(w, err)
			return
		}
		writeJSON(w, a.scanStatus())
	})

	mux.HandleFunc("/api/scan/cancel", func(w http.ResponseWriter, r *http.Request) {
		a.mu.Lock()
		defer a.mu.Unlock()
		_ = os.Remove(filepath.Join(a.cfg.Paths.ModDir(), "scan_request.txt"))
		writeJSON(w, a.scanStatus())
	})

	mux.HandleFunc("/api/scan/status", func(w http.ResponseWriter, r *http.Request) {
		a.mu.Lock()
		defer a.mu.Unlock()
		writeJSON(w, a.scanStatus())
	})

	mux.HandleFunc("/api/launch", func(w http.ResponseWriter, r *http.Request) {
		if err := OpenURL("steam://rungameid/607080"); err != nil {
			writeErr(w, err)
			return
		}
		writeJSON(w, map[string]bool{"ok": true})
	})

	mux.HandleFunc("/api/open", func(w http.ResponseWriter, r *http.Request) {
		var req struct{ What string }
		_ = readBody(r, &req)
		a.mu.Lock()
		p := a.cfg.Paths
		a.mu.Unlock()
		target := ""
		switch req.What {
		case "saves":
			target = p.SaveDir
		case "mod":
			target = p.ModDir()
		case "log":
			target = filepath.Join(p.ModDir(), "psychorando.log")
		}
		if target == "" {
			writeErr(w, fmt.Errorf("unknown target"))
			return
		}
		if err := OpenURL(target); err != nil {
			writeErr(w, err)
			return
		}
		writeJSON(w, map[string]bool{"ok": true})
	})

	mux.HandleFunc("/api/generate", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Slot    int     `json:"slot"`
			Options Options `json:"options"`
		}
		if err := readBody(r, &req); err != nil {
			writeErr(w, err)
			return
		}
		a.mu.Lock()
		defer a.mu.Unlock()
		p := a.cfg.Paths
		gd := LoadActiveGameData(p.DataDir())
		if req.Options.Seed == "" {
			req.Options.Seed = RandomSeedName()
		}
		req.Options.Collected = CollectedIDs(p.SaveDir, req.Slot)
		res, err := Generate(gd, req.Options)
		if err != nil {
			writeErr(w, err)
			return
		}
		backup, err := BackupSlot(p.SaveDir, p.ModDir(), req.Slot)
		if err != nil {
			writeErr(w, fmt.Errorf("backing up save failed: %w", err))
			return
		}
		if err := InstallMod(p); err != nil {
			writeErr(w, err)
			return
		}
		seedPath, spoilerPath, err := WriteSeed(p.ModDir(), req.Slot, gd, res)
		if err != nil {
			writeErr(w, err)
			return
		}
		a.cfg.Options = req.Options
		SaveConfig(a.cfg)
		_, _ = ExportCollectibles(gd, p.SaveDir, p.ModDir(), a.exportPath())
		writeJSON(w, map[string]interface{}{
			"seed": res.Options.Seed, "stats": res.Stats, "seedFile": seedPath,
			"spoilerFile": spoilerPath, "backup": backup,
		})
	})

	mux.HandleFunc("/api/unrandomize", func(w http.ResponseWriter, r *http.Request) {
		var req struct{ Slot int }
		_ = readBody(r, &req)
		a.mu.Lock()
		defer a.mu.Unlock()
		base := filepath.Join(a.cfg.Paths.ModDir(), "seeds", fmt.Sprintf("slot_%d", req.Slot))
		_ = os.Remove(base + ".lua")
		_ = os.Remove(base + "_spoiler.txt")
		_ = os.Remove(base + ".json")
		_, _ = ExportCollectibles(LoadActiveGameData(a.cfg.Paths.DataDir()), a.cfg.Paths.SaveDir, a.cfg.Paths.ModDir(), a.exportPath())
		writeJSON(w, map[string]bool{"ok": true})
	})

	mux.HandleFunc("/api/spoiler", func(w http.ResponseWriter, r *http.Request) {
		a.mu.Lock()
		p := a.cfg.Paths
		a.mu.Unlock()
		slot := r.URL.Query().Get("slot")
		b, err := os.ReadFile(filepath.Join(p.ModDir(), "seeds", "slot_"+slot+"_spoiler.txt"))
		if err != nil {
			http.Error(w, "No spoiler log for this slot", 404)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write(b)
	})

	mux.HandleFunc("/api/export", func(w http.ResponseWriter, r *http.Request) {
		a.mu.Lock()
		defer a.mu.Unlock()
		p := a.cfg.Paths
		gd := LoadActiveGameData(p.DataDir())
		out := a.exportPath()
		n, err := ExportCollectibles(gd, p.SaveDir, p.ModDir(), out)
		if err != nil {
			writeErr(w, fmt.Errorf("could not write %s: %w (close it in Excel and try again)", out, err))
			return
		}
		_ = OpenURL(out)
		writeJSON(w, map[string]interface{}{"path": out, "count": n})
	})

	mux.HandleFunc("/api/randomseed", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]string{"seed": RandomSeedName()})
	})
	return mux
}

var seedWords = []string{"Brainy", "Psychic", "Lucid", "Cerebral", "Mental", "Dreamy", "Figmental", "Telekinetic",
	"Levitating", "Burning", "Clairvoyant", "Nervous", "Bottled", "Baked", "Bowling", "Sanctuary", "Censor", "Regret",
	"Doubt", "Judge", "Bad Idea", "Panic", "Enlightened", "Questionable", "Hollis", "Otto", "Sasha", "Milla", "Ford", "Lili"}
var seedNouns = []string{"Bacon", "Brain", "Vault", "Baggage", "Figment", "Marker", "Nugget", "Card", "Tag", "Mind",
	"Lobe", "Tanker", "Cookoff", "Follies", "Collection", "Sensorium", "Bottle", "Labyrinth", "Gulch", "Bumpers"}

func RandomSeedName() string {
	n := time.Now().UnixNano()
	r := rngFor(fmt.Sprint(n))
	return fmt.Sprintf("%s%s%d", strings.ReplaceAll(seedWords[r.IntN(len(seedWords))], " ", ""),
		seedNouns[r.IntN(len(seedNouns))], 10+r.IntN(90))
}

func startServer(a *App) (string, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", err
	}
	go func() { _ = http.Serve(ln, a.routes()) }()
	return "http://" + ln.Addr().String() + "/", nil
}
