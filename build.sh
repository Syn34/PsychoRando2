#!/bin/sh
# Builds dist/PsychoRando.exe (Windows, amd64). Works from Linux, macOS or Windows (Git Bash).
# Dependencies are bundled in third_party/, so no network access is needed.
set -e
cd "$(dirname "$0")/app"
rm -rf modfiles && mkdir -p modfiles && cp -r ../mod/PsychoRando modfiles/
export GOFLAGS=-mod=mod GOSUMDB=off GOPROXY=off GOOS=windows GOARCH=amd64
go build -trimpath -ldflags "-H windowsgui -s -w" -o ../dist/PsychoRando.exe .
echo "Built dist/PsychoRando.exe"
