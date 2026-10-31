# PsychoRando 2

An item randomizer for **Psychonauts 2** (PC, Steam). It shuffles collectibles between locations, both within and across levels:

Figments, PSI Cards, PSI Challenge Markers, Half-a-Minds, Supply Chest Keys, Memory Vaults, Nuggets of Wisdom, Bag Tags, Emotional Baggage and Scavenger Hunt items. Supply chest contents are available as an experimental option.

> Status: early (v0.1.0). The generator and runtime logic are tested against synthetic data. Real in-game testing is in progress.

## Requirements

- Psychonauts 2 on PC
- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) 3.0.1 installed in `Psychonauts2/Binaries/Win64`
- Windows 10/11 (the app window uses the WebView2 runtime that ships with Windows)

## Using it

1. Run `PsychoRando.exe`. Point it at your game folder and your save folder (`%LOCALAPPDATA%\Psychonauts2\Saved\SaveGames`). Both are detected automatically.
2. Click **Install the mod**. This copies the Lua mod into `Mods/PsychoRando` and enables it in `mods.txt`.
3. **Scan** (one time only): click **Start scan**, launch the game, and wait at the main menu. The mod loads every level package in-engine and records each collectible. If the game crashes, start the scan again and it resumes, skipping the package that crashed it.
4. Pick a save slot (1–3), choose categories and options, then click **Randomize**. Your save files are backed up to `Mods/PsychoRando/backups` first.
5. Load that slot in-game. The randomizer is only active on randomized slots. Ctrl+F8 prints the active seed to the UE4SS console. Received items are logged to `Mods/PsychoRando/psychorando.log`.

### Options

- **Where items can land:** anywhere in the game, or only within their own level.
- **Figments:** mixed with everything, or swapped only with other figments.
- **Logic:** never places a bag tag behind its own baggage. Uses assumed fill, so tag chains are also prevented.
- **Seed:** the same seed and options always produce the same layout. A spoiler log is written next to the seed.

## How it works

| Piece | What it does |
|---|---|
| `mod/PsychoRando` | UE4SS Lua mod. `scan.lua` builds the location database. `runtime.lua` applies the seed. |
| `app/` | Go app with a local web UI in a WebView2 window. Handles installation, scanning, save slots, seed generation and spoiler logs. |
| `third_party/` | Bundled copies of `go-webview2`, `go-winloader` and `golang.org/x/sys` (Windows parts), so the build works offline. |

Game facts the mod relies on:
- Every collectible has a `CoCollectable` component (`m_eCollectableType`, `m_CollectableUniqueID`).
- Pickups grant through `CoPickupable.m_aPickupGrantedItems`. The mod rewrites this array when a pickup spawns, so the game grants the new item itself.
- Vaults, baggage and interact-style pickups grant from Blueprint code. When one of these is collected, the mod watches `P2UpgradeManager:OnInventoryItemAmountChanged`, takes back the original item, and grants the assigned one using `P2BlueprintLibrary:AddToRazInventory` and `RemoveFromRazInventory`.
- The active slot comes from `P2GameUserSettings:GetCurrentSaveSlotIndex()`. Each slot is stored as a file pair (`0/A`, `1/B`, `2/C`).
- "Collected" state is already persisted per actor in the save, so the mod keeps no tracking state of its own.

Seeds are Lua tables at `Mods/PsychoRando/seeds/slot_<n>.lua`, keyed by `id:<UniqueID>` and `pa:<package>|<actor>`.

## Building

```sh
sh build.sh        # -> dist/PsychoRando.exe (cross-compiles from any OS, Go 1.24+)
```

Run the tests with `cd app && go test ./...` (copy `mod/PsychoRando` to `app/modfiles/` first; `build.sh` does this for you).

## Known open questions

- Figments may be tracked per location rather than as an inventory item. If so, moving a figment moves nothing tangible.
- One-of-a-kind items (bag tags, vault cards) might block their original pickup if you already own them through randomization.
- For Blueprint-granted sources, the original item's popup may show briefly before it is swapped.

## Third-party licenses

`third_party/go-webview2` (MIT) and `third_party/go-winloader` (ISC) are © John Chadwick. `third_party/sys` is BSD-3-Clause (© The Go Authors). Each keeps its original LICENSE file.
