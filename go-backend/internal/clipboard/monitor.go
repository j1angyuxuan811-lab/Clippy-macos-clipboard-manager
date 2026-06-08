package clipboard

import (
	"crypto/sha256"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"clippy-backend/internal/config"
	"clippy-backend/internal/db"
)

type Monitor struct {
	store         *db.Store
	interval      time.Duration
	lastTextHash  string
	lastImageHash string
	imagesDir     string
}

type Status struct {
	FrontAppBundleID string `json:"front_app_bundle_id"`
	FrontAppKnown    bool   `json:"front_app_known"`
	Ignored          bool   `json:"ignored"`
	Paused           bool   `json:"paused"`
}

type clipboardTextCandidate struct {
	Text   string
	Source string
}

func New(store *db.Store, imagesDir string) *Monitor {
	_ = os.MkdirAll(imagesDir, 0755)
	return &Monitor{
		store:     store,
		interval:  800 * time.Millisecond,
		imagesDir: imagesDir,
	}
}

func (m *Monitor) Start() {
	log.Println("📋 Clipboard monitor started")
	m.check()
	for {
		time.Sleep(m.interval)
		m.check()
	}
}

func (m *Monitor) check() {
	// Skip if recording is paused
	if config.IsPaused() {
		return
	}

	// Skip if front app is in ignored list
	if bundleID := getFrontAppBundleID(); bundleID != "" {
		if config.IsAppIgnored(bundleID) {
			return
		}
	}

	if m.checkImage() {
		return
	}
	m.checkText()
}

func CurrentStatus() Status {
	bundleID := getFrontAppBundleID()
	return Status{
		FrontAppBundleID: bundleID,
		FrontAppKnown:    bundleID != "",
		Ignored:          bundleID != "" && config.IsAppIgnored(bundleID),
		Paused:           config.IsPaused(),
	}
}

// getFrontAppBundleID returns the bundle ID of the frontmost app using osascript
func getFrontAppBundleID() string {
	out, err := exec.Command("osascript", "-e",
		`tell application "System Events" to get bundle identifier of first application process whose frontmost is true`).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func (m *Monitor) checkText() {
	text := readClipboardText()
	if text == "" || len(text) > 100_000 {
		return
	}

	hash := hashStr(text)
	if hash == m.lastTextHash {
		return
	}
	m.lastTextHash = hash
	m.lastImageHash = "" // reset image hash when text changes
	m.store.Create(text, "text", "")
}

func readClipboardText() string {
	candidates := make([]clipboardTextCandidate, 0, 3)

	if out, err := exec.Command("osascript", "-e", `try
the clipboard as «class utf8»
on error
""
end try`).Output(); err == nil {
		candidates = append(candidates, clipboardTextCandidate{
			Text:   string(out),
			Source: "public.utf8-plain-text",
		})
	}

	if out, err := exec.Command("osascript", "-e", `try
the clipboard as text
on error
""
end try`).Output(); err == nil {
		candidates = append(candidates, clipboardTextCandidate{
			Text:   string(out),
			Source: "osascript-text",
		})
	}

	if out, err := exec.Command("pbpaste").Output(); err == nil {
		candidates = append(candidates, clipboardTextCandidate{
			Text:   string(out),
			Source: "pbpaste",
		})
	}

	return bestClipboardText(candidates)
}

func bestClipboardText(candidates []clipboardTextCandidate) string {
	cleaned := make([]clipboardTextCandidate, 0, len(candidates))
	for _, candidate := range candidates {
		text := strings.TrimSpace(candidate.Text)
		if text == "" {
			continue
		}
		if replacementCharacterRatio(text) > 0.2 {
			continue
		}
		cleaned = append(cleaned, clipboardTextCandidate{
			Text:   text,
			Source: candidate.Source,
		})
	}
	if len(cleaned) == 0 {
		return ""
	}

	sort.SliceStable(cleaned, func(i, j int) bool {
		return replacementCharacterCount(cleaned[i].Text) < replacementCharacterCount(cleaned[j].Text)
	})
	return cleaned[0].Text
}

func replacementCharacterRatio(text string) float64 {
	total := 0
	replacements := 0
	for _, r := range text {
		total++
		if r == '\uFFFD' {
			replacements++
		}
	}
	if total == 0 {
		return 0
	}
	return float64(replacements) / float64(total)
}

func replacementCharacterCount(text string) int {
	count := 0
	for _, r := range text {
		if r == '\uFFFD' {
			count++
		}
	}
	return count
}

func (m *Monitor) checkImage() bool {
	// Check clipboard info for image types using osascript
	infoOut, err := exec.Command("osascript", "-e", "clipboard info as text").Output()
	if err != nil {
		return false
	}
	info := string(infoOut)

	hasImage := strings.Contains(info, "PNGf") ||
		strings.Contains(info, "TIFF") ||
		strings.Contains(info, "JPEG") ||
		strings.Contains(info, "GIFf") ||
		strings.Contains(info, "8BPS")
	if !hasImage {
		return false
	}

	log.Printf("🖼️ Image detected in clipboard")

	// Export as PNG using osascript
	tmpFile := filepath.Join(m.imagesDir, fmt.Sprintf("clip_%d.png", time.Now().UnixNano()))
	exportScript := fmt.Sprintf(`set theData to the clipboard as «class PNGf»
set f to open for access POSIX file "%s" with write permission
set eof f to 0
write theData to f
close access f`, tmpFile)

	_, err = exec.Command("osascript", "-e", exportScript).CombinedOutput()
	if err != nil {
		// Fallback to TIFF
		_ = os.Remove(tmpFile)
		tmpFile = filepath.Join(m.imagesDir, fmt.Sprintf("clip_%d.tiff", time.Now().UnixNano()))
		exportScript = fmt.Sprintf(`set theData to the clipboard as TIFF picture
set f to open for access POSIX file "%s" with write permission
set eof f to 0
write theData to f
close access f`, tmpFile)
		_, err = exec.Command("osascript", "-e", exportScript).CombinedOutput()
		if err != nil {
			_ = os.Remove(tmpFile)
			return false
		}
	}

	// Check file size (max 5MB, min 100 bytes)
	finfo, err := os.Stat(tmpFile)
	if err != nil || finfo.Size() > 5*1024*1024 || finfo.Size() < 100 {
		_ = os.Remove(tmpFile)
		return false
	}

	// Dedup by content hash
	hash := hashFile(tmpFile)
	if hash == m.lastImageHash {
		_ = os.Remove(tmpFile)
		return true
	}
	m.lastImageHash = hash
	m.lastTextHash = "" // reset text hash when image changes

	relPath := filepath.Join("data", "images", filepath.Base(tmpFile))
	item, _ := m.store.CreateWithHash("[图片]", "image", relPath, hash)
	// If DB dedup found existing item with different path, delete the new file
	if item != nil && item.ImagePath != relPath {
		_ = os.Remove(tmpFile)
		log.Printf("🔁 Image dedup: reused existing %s", item.ImagePath)
	} else {
		log.Printf("🖼️ Image captured: %s (%.1f KB)", filepath.Base(tmpFile), float64(finfo.Size())/1024)
	}
	return true
}

func hashStr(s string) string {
	h := sha256.Sum256([]byte(s))
	return fmt.Sprintf("%x", h[:8])
}

func hashFile(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	h := sha256.Sum256(data)
	return fmt.Sprintf("%x", h[:8])
}
