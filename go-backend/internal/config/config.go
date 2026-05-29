package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type Config struct {
	RetentionHours int      `json:"retention_hours"` // 0 = keep forever
	IgnoredApps    []string `json:"ignored_apps"`    // bundle IDs to ignore
	MaxItems       int      `json:"max_items"`
	PasteDirectly  bool     `json:"paste_directly"`  // simulate Cmd+V after copy
	PausedUntil    string   `json:"paused_until"`    // ISO8601 timestamp; recording paused until this time
}

// Default sensitive apps that should be ignored
var DefaultIgnoredApps = []string{
	"com.1password.1password",
	"com.agilebits.onepassword7",
	"com.apple.keychainaccess",
	"com.lastpass.LastPass",
	"com.bitwarden.desktop",
	"com.dashlane.dashlanephonefinal",
	"org.keepassxc.keepassxc",
}

var (
	current  *Config
	mu       sync.RWMutex
	filePath string
)

func defaults() *Config {
	return &Config{
		RetentionHours: 168, // 7 days
		IgnoredApps:    append([]string{}, DefaultIgnoredApps...),
		MaxItems:       1000,
		PasteDirectly:  true,
		PausedUntil:    "",
	}
}

func Load(dataDir string) *Config {
	mu.Lock()
	defer mu.Unlock()

	filePath = filepath.Join(dataDir, "settings.json")
	current = defaults()

	data, err := os.ReadFile(filePath)
	if err != nil {
		// First run: create default config
		save()
		return current
	}

	_ = json.Unmarshal(data, current)

	// Ensure valid values
	if current.MaxItems <= 0 {
		current.MaxItems = 1000
	}
	// Migration: if ignored_apps is nil OR empty, populate with defaults.
	// This ensures existing users who saved an empty list get the privacy baseline.
	if len(current.IgnoredApps) == 0 {
		current.IgnoredApps = append([]string{}, DefaultIgnoredApps...)
		save() // persist the migration
	}

	return current
}

func Get() *Config {
	mu.RLock()
	defer mu.RUnlock()
	if current == nil {
		return defaults()
	}
	c := *current
	return &c
}

func Update(newCfg *Config) error {
	mu.Lock()
	defer mu.Unlock()

	if newCfg.MaxItems <= 0 {
		newCfg.MaxItems = 1000
	}
	if newCfg.IgnoredApps == nil {
		newCfg.IgnoredApps = append([]string{}, DefaultIgnoredApps...)
	}

	current = newCfg
	return save()
}

// IsPaused returns true if recording is currently paused
func IsPaused() bool {
	mu.RLock()
	defer mu.RUnlock()
	if current == nil || current.PausedUntil == "" {
		return false
	}
	t, err := time.Parse(time.RFC3339, current.PausedUntil)
	if err != nil {
		return false
	}
	return time.Now().Before(t)
}

// Pause recording for the given duration
func Pause(d time.Duration) {
	mu.Lock()
	defer mu.Unlock()
	current.PausedUntil = time.Now().Add(d).Format(time.RFC3339)
	save()
}

// Resume recording immediately
func Resume() {
	mu.Lock()
	defer mu.Unlock()
	current.PausedUntil = ""
	save()
}

func IsAppIgnored(bundleID string) bool {
	mu.RLock()
	defer mu.RUnlock()
	if current == nil {
		return false
	}
	for _, id := range current.IgnoredApps {
		if id == bundleID {
			return true
		}
	}
	return false
}

func save() error {
	data, err := json.MarshalIndent(current, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filePath, data, 0644)
}
