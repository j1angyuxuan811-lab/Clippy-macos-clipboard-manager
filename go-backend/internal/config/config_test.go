package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadDefaults(t *testing.T) {
	dir := t.TempDir()
	cfg := Load(dir)

	if cfg.RetentionHours != 168 {
		t.Errorf("expected retention 168, got %d", cfg.RetentionHours)
	}
	if cfg.MaxItems != 1000 {
		t.Errorf("expected max_items 1000, got %d", cfg.MaxItems)
	}
	if !cfg.PasteDirectly {
		t.Error("expected paste_directly true by default")
	}
	if len(cfg.IgnoredApps) != len(DefaultIgnoredApps) {
		t.Errorf("expected %d default ignored apps, got %d", len(DefaultIgnoredApps), len(cfg.IgnoredApps))
	}
}

func TestMigrateEmptyIgnoredApps(t *testing.T) {
	dir := t.TempDir()
	// Simulate existing user with empty ignored_apps
	settingsJSON := `{"retention_hours":72,"ignored_apps":[],"max_items":500,"paste_directly":false}`
	err := os.WriteFile(filepath.Join(dir, "settings.json"), []byte(settingsJSON), 0644)
	if err != nil {
		t.Fatal(err)
	}

	cfg := Load(dir)

	// Should have migrated to defaults
	if len(cfg.IgnoredApps) != len(DefaultIgnoredApps) {
		t.Errorf("expected migration to %d default apps, got %d", len(DefaultIgnoredApps), len(cfg.IgnoredApps))
	}
	// Other settings should be preserved
	if cfg.RetentionHours != 72 {
		t.Errorf("expected retention 72 preserved, got %d", cfg.RetentionHours)
	}
	if cfg.MaxItems != 500 {
		t.Errorf("expected max_items 500 preserved, got %d", cfg.MaxItems)
	}
	if cfg.PasteDirectly != false {
		t.Error("expected paste_directly false preserved")
	}
}

func TestMigratePreservesCustomIgnoredApps(t *testing.T) {
	dir := t.TempDir()
	// User who has customized their list should keep their apps
	settingsJSON := `{"retention_hours":168,"ignored_apps":["com.custom.app"],"max_items":1000,"paste_directly":true}`
	err := os.WriteFile(filepath.Join(dir, "settings.json"), []byte(settingsJSON), 0644)
	if err != nil {
		t.Fatal(err)
	}

	cfg := Load(dir)

	// Should NOT overwrite custom list
	if len(cfg.IgnoredApps) != 1 || cfg.IgnoredApps[0] != "com.custom.app" {
		t.Errorf("expected custom ignored_apps preserved, got %v", cfg.IgnoredApps)
	}
}

func TestPauseResume(t *testing.T) {
	dir := t.TempDir()
	Load(dir)

	if IsPaused() {
		t.Error("should not be paused initially")
	}

	Pause(5 * 60 * 1e9) // 5 minutes in nanoseconds? No, it's time.Duration
	// Actually Pause takes time.Duration which is nanoseconds
	// Let's just test with the actual function
	Resume()
	if IsPaused() {
		t.Error("should not be paused after resume")
	}
}

func TestIsAppIgnored(t *testing.T) {
	dir := t.TempDir()
	Load(dir)

	if !IsAppIgnored("com.1password.1password") {
		t.Error("expected com.1password.1password to be ignored")
	}
	if !IsAppIgnored("com.apple.systempreferences") {
		t.Error("expected System Settings to be ignored")
	}
	if !IsAppIgnored("com.apple.Passbook") {
		t.Error("expected Wallet to be ignored")
	}
	if !IsAppIgnored("com.tencent.xinWeChat") {
		t.Error("expected WeChat to be ignored as a work-content sensitive source")
	}
	if IsAppIgnored("com.apple.finder") {
		t.Error("expected com.apple.finder to NOT be ignored")
	}
}

func TestUpdateSettings(t *testing.T) {
	dir := t.TempDir()
	Load(dir)

	newCfg := &Config{
		RetentionHours: 24,
		IgnoredApps:    []string{"com.test.app"},
		MaxItems:       500,
		PasteDirectly:  false,
	}
	err := Update(newCfg)
	if err != nil {
		t.Fatal(err)
	}

	cfg := Get()
	if cfg.RetentionHours != 24 {
		t.Errorf("expected retention 24, got %d", cfg.RetentionHours)
	}
	if cfg.MaxItems != 500 {
		t.Errorf("expected max_items 500, got %d", cfg.MaxItems)
	}
	if cfg.PasteDirectly != false {
		t.Error("expected paste_directly false")
	}
}

func TestUpdateNilIgnoredAppsGetsDefaults(t *testing.T) {
	dir := t.TempDir()
	Load(dir)

	newCfg := &Config{
		RetentionHours: 168,
		IgnoredApps:    nil,
		MaxItems:       1000,
		PasteDirectly:  true,
	}
	err := Update(newCfg)
	if err != nil {
		t.Fatal(err)
	}

	cfg := Get()
	if len(cfg.IgnoredApps) != len(DefaultIgnoredApps) {
		t.Errorf("expected defaults when nil, got %d apps", len(cfg.IgnoredApps))
	}
}
