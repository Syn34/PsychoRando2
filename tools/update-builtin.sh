#!/bin/sh
# Copies a completed scan into app/builtin so release builds ship it.
# Usage: tools/update-builtin.sh <path to Mods/PsychoRando/data or the app's data folder>
set -e
src="${1:?usage: $0 <scan data folder>}"
dst="$(dirname "$0")/../app/builtin"
[ -f "$src/scan_done.txt" ] || { echo "no completed scan in $src"; exit 1; }
for f in scan_locations.jsonl scan_items.jsonl figment_params.json scan_done.txt; do
  [ -f "$src/$f" ] && cp "$src/$f" "$dst/$f"
done
chmod 644 "$dst"/*
echo "Built-in data updated from $src:"; cat "$dst/scan_done.txt"; echo
