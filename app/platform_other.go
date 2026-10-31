//go:build !windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
)

func DefaultSaveDir() string {
	h, _ := os.UserHomeDir()
	return filepath.Join(h, "Psychonauts2", "Saved", "SaveGames")
}
func DetectGameDir() string                            { return os.Getenv("P2_GAME_DIR") }
func BrowseFolder(title, start string) (string, error) { return "", fmt.Errorf("not supported") }
func OpenURL(target string) error                      { fmt.Println("open:", target); return nil }
func runUI(url string)                                 { fmt.Println("UI at", url); select {} }
