package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"io/fs"
	"strings"
	"time"
)

// A Psychonauts 2 save is a GVAS file whose property list is followed by the
// game's own manager blocks:
//
//	int32 0, int32 count, then count x { FString name, uint32 size, size bytes }
//
// (FDialogManager, FDlgMemory, P2::Managers::PlayerPosition, ...Quests, ...).
// The Motherlobe start is made by editing a fresh New Game save: Loboto's
// Labyrinth quests are marked complete, the check-in quest is made active and
// Raz is placed at the Motherlobe atrium (the same spot the game's own fast
// travel uses).

const (
	newGameBaseName = "newgame_base.sav"
	hqinMap         = "/Game/Maps/HQIN/HQIN.HQIN"
	hqinSublevel    = "/Game/Maps/HQIN/HQIN_DES.HQIN_DES"
	hqinDest        = "PersistentLevel.PlayerDestination_FastTravel_Atrium"
	questLoboDone   = "QUEST_HUB1_1000_CompleteLobo"
	questFrontDesk  = "QUEST_HUB1_1005_CheckinFrontDesk"
	questComplete   = 4
	questActive     = 2
)

type saveSection struct {
	Name string
	Data []byte
}

type p2Save struct {
	head     []byte // GVAS header and properties, up to the section count
	sections []saveSection
	tail     []byte
}

type rd struct {
	b   []byte
	o   int
	err error
}

func (r *rd) i32() int32 {
	if r.err != nil || r.o+4 > len(r.b) {
		r.fail("unexpected end of save")
		return 0
	}
	v := int32(binary.LittleEndian.Uint32(r.b[r.o:]))
	r.o += 4
	return v
}

func (r *rd) fail(msg string) {
	if r.err == nil {
		r.err = fmt.Errorf("%s (at byte %d)", msg, r.o)
	}
}

func (r *rd) fstr() string {
	n := int(r.i32())
	if r.err != nil {
		return ""
	}
	if n == 0 {
		return ""
	}
	if n < 0 { // UTF-16
		n = -n * 2
		if r.o+n > len(r.b) {
			r.fail("bad string")
			return ""
		}
		var sb strings.Builder
		for i := 0; i+1 < n-2; i += 2 {
			sb.WriteRune(rune(binary.LittleEndian.Uint16(r.b[r.o+i:])))
		}
		r.o += n
		return sb.String()
	}
	if n > 1<<20 || r.o+n > len(r.b) {
		r.fail("bad string")
		return ""
	}
	s := string(r.b[r.o : r.o+n-1])
	r.o += n
	return s
}

func (r *rd) bytes(n int) []byte {
	if r.err != nil || n < 0 || r.o+n > len(r.b) {
		r.fail("unexpected end of save")
		return nil
	}
	v := r.b[r.o : r.o+n]
	r.o += n
	return v
}

type wr struct{ bytes.Buffer }

func (w *wr) i32(v int32) {
	var b [4]byte
	binary.LittleEndian.PutUint32(b[:], uint32(v))
	w.Write(b[:])
}

func (w *wr) fstr(s string) {
	if s == "" {
		w.i32(0)
		return
	}
	w.i32(int32(len(s) + 1))
	w.WriteString(s)
	w.WriteByte(0)
}

func parseP2Save(b []byte) (*p2Save, error) {
	if len(b) < 64 || string(b[:4]) != "GVAS" {
		return nil, fmt.Errorf("not a Psychonauts 2 save")
	}
	marker := []byte("\x0f\x00\x00\x00FDialogManager\x00")
	i := bytes.Index(b, marker)
	if i < 4 {
		return nil, fmt.Errorf("save has no game data block")
	}
	r := &rd{b: b, o: i - 4}
	n := int(r.i32())
	if n < 1 || n > 200 {
		return nil, fmt.Errorf("unexpected save layout (%d blocks)", n)
	}
	s := &p2Save{head: append([]byte(nil), b[:i-4]...)}
	for k := 0; k < n; k++ {
		name := r.fstr()
		size := int(uint32(r.i32()))
		data := r.bytes(size)
		if r.err != nil {
			return nil, r.err
		}
		s.sections = append(s.sections, saveSection{name, append([]byte(nil), data...)})
	}
	s.tail = append([]byte(nil), b[r.o:]...)
	return s, nil
}

func (s *p2Save) bytes() []byte {
	var w wr
	w.Write(s.head)
	w.i32(int32(len(s.sections)))
	for _, sec := range s.sections {
		w.fstr(sec.Name)
		w.i32(int32(len(sec.Data)))
		w.Write(sec.Data)
	}
	w.Write(s.tail)
	return w.Bytes()
}

func (s *p2Save) section(name string) *saveSection {
	for i := range s.sections {
		if s.sections[i].Name == name {
			return &s.sections[i]
		}
	}
	return nil
}

// Quest block: int32 count, then { FString questPath, FString subPath, uint8 status }.
type questEntry struct {
	Path   string
	Status byte
	at     int
}

func readQuests(data []byte) ([]questEntry, error) {
	r := &rd{b: data}
	n := int(r.i32())
	if n < 0 || n > 5000 {
		return nil, fmt.Errorf("bad quest count")
	}
	out := make([]questEntry, 0, n)
	for k := 0; k < n && r.err == nil; k++ {
		p := r.fstr()
		r.fstr()
		st := r.bytes(1)
		if r.err != nil {
			break
		}
		out = append(out, questEntry{Path: p, Status: st[0], at: r.o - 1})
	}
	return out, r.err
}

func questName(path string) string {
	if i := strings.LastIndexByte(path, '.'); i >= 0 {
		return path[i+1:]
	}
	return path
}

// QuestStatuses returns quest name -> status for a save (used by tests and the UI).
func QuestStatuses(b []byte) (map[string]byte, error) {
	s, err := parseP2Save(b)
	if err != nil {
		return nil, err
	}
	q := s.section("P2::Managers::Quests")
	if q == nil {
		return nil, fmt.Errorf("save has no quest data")
	}
	list, err := readQuests(q.Data)
	if err != nil {
		return nil, err
	}
	m := map[string]byte{}
	for _, e := range list {
		m[questName(e.Path)] = e.Status
	}
	return m, nil
}

// SaveCurrentMap returns the map the save resumes in.
func SaveCurrentMap(b []byte) string {
	s, err := parseP2Save(b)
	if err != nil {
		return ""
	}
	pp := s.section("P2::Managers::PlayerPosition")
	if pp == nil {
		return ""
	}
	r := &rd{b: pp.Data}
	n := int(r.i32())
	for k := 0; k < n && r.err == nil; k++ {
		r.fstr()
		r.i32()
		r.bytes(40)
	}
	n = int(r.i32())
	for k := 0; k < n && r.err == nil; k++ {
		r.fstr()
		r.i32()
		r.fstr()
		r.fstr()
	}
	cur := r.fstr()
	if r.err != nil {
		return ""
	}
	return cur
}

func fileTimeTicks(t time.Time) uint64 {
	// FDateTime: 100ns ticks since 0001-01-01
	const unixEpochTicks = 621355968000000000
	return uint64(unixEpochTicks + t.UTC().UnixNano()/100)
}

// MakeMotherlobeSave turns a fresh New Game save into one that resumes at the
// Motherlobe with Loboto's Labyrinth complete.
func MakeMotherlobeSave(base []byte, now time.Time) ([]byte, error) {
	s, err := parseP2Save(base)
	if err != nil {
		return nil, err
	}

	// Quests
	qs := s.section("P2::Managers::Quests")
	if qs == nil {
		return nil, fmt.Errorf("save has no quest data")
	}
	list, err := readQuests(qs.Data)
	if err != nil {
		return nil, err
	}
	found := 0
	for _, e := range list {
		n := questName(e.Path)
		switch {
		case n == questLoboDone || strings.HasPrefix(n, "QUEST_LOBO_"):
			qs.Data[e.at] = questComplete
			if n == questLoboDone {
				found++
			}
		case n == questFrontDesk:
			qs.Data[e.at] = questActive
			found++
		}
	}
	if found != 2 {
		return nil, fmt.Errorf("save is missing the Motherlobe quests")
	}

	// Player position: no stored transforms, one destination at the atrium.
	pp := s.section("P2::Managers::PlayerPosition")
	if pp == nil {
		return nil, fmt.Errorf("save has no player position")
	}
	var w wr
	w.i32(0)
	w.i32(1)
	w.fstr(hqinMap)
	w.i32(0)
	w.fstr(hqinSublevel)
	w.fstr(hqinDest)
	w.fstr(hqinMap)
	w.i32(0)
	pp.Data = w.Bytes()

	// Save metadata: level shown in the menu, and the save time.
	if md := s.section("P2::Managers::SaveMetaData"); md != nil && len(md.Data) > 36 {
		d := md.Data
		binary.LittleEndian.PutUint64(d[16:], fileTimeTicks(now))
		r := &rd{b: d, o: 32}
		start := r.o
		old := r.fstr()
		if r.err == nil && strings.HasPrefix(old, "/Game/Maps/") {
			var m wr
			m.Write(d[:start])
			m.fstr(hqinMap)
			m.Write(d[r.o:])
			md.Data = m.Bytes()
		}
	}
	return s.bytes(), nil
}

// MotherlobeTemplate builds the Motherlobe starting save from the built-in
// fresh New Game save.
func MotherlobeTemplate() ([]byte, error) {
	base, err := fs.ReadFile(builtinFS, "builtin/"+newGameBaseName)
	if err != nil {
		return nil, fmt.Errorf("the built-in New Game save is missing")
	}
	return MakeMotherlobeSave(base, time.Now())
}
