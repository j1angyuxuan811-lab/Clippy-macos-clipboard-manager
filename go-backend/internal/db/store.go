package db

import (
	"database/sql"
	"fmt"
	"log"
	"os"
	"path/filepath"

	"clippy-backend/internal/config"

	_ "github.com/mattn/go-sqlite3"
)

type Item struct {
	ID          int    `json:"id"`
	Content     string `json:"content"`
	ContentType string `json:"content_type"`
	ImagePath   string `json:"image_path,omitempty"`
	Tags        string `json:"tags"`
	IsPinned    bool   `json:"pinned"`
	HotCount    int    `json:"hot_count"`
	CreatedAt   string `json:"created_at"`
}

type Store struct {
	db *sql.DB
}

func New(dbPath string) (*Store, error) {
	db, err := sql.Open("sqlite3", dbPath+"?_journal_mode=WAL")
	if err != nil {
		return nil, err
	}

	s := &Store{db: db}
	s.init()
	return s, nil
}

func (s *Store) init() {
	s.db.Exec(`CREATE TABLE IF NOT EXISTS items (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		content TEXT NOT NULL,
		content_type TEXT DEFAULT 'text',
		image_path TEXT,
		content_hash TEXT DEFAULT '',
		tags TEXT DEFAULT '',
		pinned INTEGER DEFAULT 0,
		hot_count INTEGER DEFAULT 0,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP
	)`)
	s.db.Exec("CREATE INDEX IF NOT EXISTS idx_items_created_at ON items(created_at)")
	s.db.Exec("CREATE INDEX IF NOT EXISTS idx_items_pinned ON items(pinned)")
	s.db.Exec("CREATE INDEX IF NOT EXISTS idx_items_content_hash ON items(content_hash)")
	// Migration: add image_path column if missing
	s.db.Exec("ALTER TABLE items ADD COLUMN image_path TEXT DEFAULT ''")
	// Migration: add content_hash column if missing
	s.db.Exec("ALTER TABLE items ADD COLUMN content_hash TEXT DEFAULT ''")
	// Migration: rename access_count to hot_count if needed
	s.db.Exec("ALTER TABLE items RENAME COLUMN access_count TO hot_count")
}

func (s *Store) Create(content string, contentType string, imagePath string) (*Item, error) {
	return s.CreateWithHash(content, contentType, imagePath, "")
}

func (s *Store) CreateWithHash(content string, contentType string, imagePath string, contentHash string) (*Item, error) {
	// Permanent dedup: if content already exists, update its timestamp instead of inserting
	var existingID int
	if contentHash != "" {
		// Image dedup by content hash
		s.db.QueryRow("SELECT id FROM items WHERE content_hash = ? AND content_hash != '' LIMIT 1", contentHash).Scan(&existingID)
	} else if imagePath != "" {
		s.db.QueryRow("SELECT id FROM items WHERE image_path = ? LIMIT 1", imagePath).Scan(&existingID)
	} else {
		s.db.QueryRow("SELECT id FROM items WHERE content = ? LIMIT 1", content).Scan(&existingID)
	}

	if existingID > 0 {
		// Update timestamp and move to top
		s.db.Exec("UPDATE items SET created_at = datetime('now') WHERE id = ?", existingID)
		return s.Get(existingID)
	}

	res, err := s.db.Exec(
		"INSERT INTO items (content, content_type, image_path, content_hash) VALUES (?, ?, ?, ?)",
		content, contentType, imagePath, contentHash,
	)
	if err != nil {
		return nil, err
	}
	id, _ := res.LastInsertId()

	// Auto cleanup
	s.cleanup()

	return s.Get(int(id))
}

func (s *Store) Get(id int) (*Item, error) {
	item := &Item{}
	err := s.db.QueryRow(
		"SELECT id, content, content_type, COALESCE(image_path,''), COALESCE(tags,''), pinned, hot_count, created_at FROM items WHERE id = ?", id,
	).Scan(&item.ID, &item.Content, &item.ContentType, &item.ImagePath, &item.Tags, &item.IsPinned, &item.HotCount, &item.CreatedAt)
	if err != nil {
		return nil, err
	}
	return item, nil
}

func (s *Store) List(limit int) ([]Item, error) {
	rows, err := s.db.Query(
		"SELECT id, content, content_type, COALESCE(image_path,''), COALESCE(tags,''), pinned, hot_count, created_at FROM items ORDER BY pinned DESC, created_at DESC LIMIT ?", limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var items []Item
	for rows.Next() {
		var item Item
		err := rows.Scan(&item.ID, &item.Content, &item.ContentType, &item.ImagePath, &item.Tags, &item.IsPinned, &item.HotCount, &item.CreatedAt)
		if err != nil {
			continue
		}
		items = append(items, item)
	}
	return items, nil
}

func (s *Store) Delete(id int) error {
	// Get image path before deleting
	var imagePath string
	_ = s.db.QueryRow("SELECT COALESCE(image_path,'') FROM items WHERE id = ?", id).Scan(&imagePath)

	_, err := s.db.Exec("DELETE FROM items WHERE id = ?", id)

	// Delete associated image file
	if imagePath != "" {
		_ = os.Remove(imagePath)
	}

	return err
}

func (s *Store) TogglePin(id int) error {
	_, err := s.db.Exec("UPDATE items SET pinned = NOT pinned WHERE id = ?", id)
	return err
}

func (s *Store) IncrementHot(id int) error {
	_, err := s.db.Exec("UPDATE items SET hot_count = hot_count + 1 WHERE id = ?", id)
	return err
}

func (s *Store) Search(query string) ([]Item, error) {
	rows, err := s.db.Query(
		"SELECT id, content, content_type, COALESCE(image_path,''), COALESCE(tags,''), pinned, hot_count, created_at FROM items WHERE content LIKE ? ORDER BY pinned DESC, created_at DESC LIMIT 50",
		"%"+query+"%",
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var items []Item
	for rows.Next() {
		var item Item
		err := rows.Scan(&item.ID, &item.Content, &item.ContentType, &item.ImagePath, &item.Tags, &item.IsPinned, &item.HotCount, &item.CreatedAt)
		if err != nil {
			continue
		}
		items = append(items, item)
	}
	return items, nil
}

// Delete old unpinned items based on configured retention
func (s *Store) cleanup() {
	cfg := config.Get()

	// Time-based cleanup: use configured retention (0 = keep forever)
	if cfg.RetentionHours > 0 {
		interval := fmt.Sprintf("-%d hours", cfg.RetentionHours)
		rows, _ := s.db.Query(
			"SELECT id, COALESCE(image_path,'') FROM items WHERE pinned = 0 AND created_at < datetime('now', ?)",
			interval,
		)
		if rows != nil {
			defer rows.Close()
			var ids []int
			var paths []string
			for rows.Next() {
				var id int
				var path string
				rows.Scan(&id, &path)
				ids = append(ids, id)
				if path != "" {
					paths = append(paths, path)
				}
			}
			for _, id := range ids {
				s.db.Exec("DELETE FROM items WHERE id = ?", id)
			}
			for _, path := range paths {
				_ = os.Remove(path)
			}
			if len(ids) > 0 {
				log.Printf("🧹 Cleaned up %d items older than %d hours", len(ids), cfg.RetentionHours)
			}
		}
	}

	// Count-based cleanup: cap at configured max items
	maxItems := cfg.MaxItems
	var count int
	s.db.QueryRow("SELECT COUNT(*) FROM items").Scan(&count)
	if count <= maxItems {
		return
	}

	rows2, _ := s.db.Query(
		"SELECT id, COALESCE(image_path,'') FROM items WHERE pinned = 0 ORDER BY created_at ASC LIMIT ?",
		count-maxItems,
	)
	if rows2 == nil {
		return
	}
	defer rows2.Close()

	var ids2 []int
	var paths2 []string
	for rows2.Next() {
		var id int
		var path string
		rows2.Scan(&id, &path)
		ids2 = append(ids2, id)
		if path != "" {
			paths2 = append(paths2, path)
		}
	}

	for _, id := range ids2 {
		s.db.Exec("DELETE FROM items WHERE id = ?", id)
	}
	for _, path := range paths2 {
		_ = os.Remove(path)
	}

	if len(ids2) > 0 {
		log.Printf("🧹 Cleaned up %d items over %d cap", len(ids2), maxItems)
	}
}

// CleanupExpired removes all unpinned items past retention period (called at startup)
func (s *Store) CleanupExpired() {
	cfg := config.Get()
	if cfg.RetentionHours <= 0 {
		return
	}

	interval := fmt.Sprintf("-%d hours", cfg.RetentionHours)
	rows, _ := s.db.Query(
		"SELECT id, COALESCE(image_path,'') FROM items WHERE pinned = 0 AND created_at < datetime('now', ?)",
		interval,
	)
	if rows == nil {
		return
	}
	defer rows.Close()

	var ids []int
	var paths []string
	for rows.Next() {
		var id int
		var path string
		rows.Scan(&id, &path)
		ids = append(ids, id)
		if path != "" {
			paths = append(paths, path)
		}
	}
	for _, id := range ids {
		s.db.Exec("DELETE FROM items WHERE id = ?", id)
	}
	for _, path := range paths {
		_ = os.Remove(path)
	}
	if len(ids) > 0 {
		log.Printf("🧹 Startup: cleaned %d expired items (retention: %d hours)", len(ids), cfg.RetentionHours)
	}
}

// Clean up orphan images (images on disk not referenced in DB)
func (s *Store) CleanupOrphanImages(imagesDir string) {
	if imagesDir == "" {
		return
	}
	entries, err := os.ReadDir(imagesDir)
	if err != nil {
		return
	}

	// Get all referenced image paths
	rows, _ := s.db.Query("SELECT DISTINCT image_path FROM items WHERE image_path != ''")
	defer rows.Close()

	referenced := make(map[string]bool)
	for rows.Next() {
		var path string
		rows.Scan(&path)
		referenced[path] = true
	}

	cleaned := 0
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		fullPath := filepath.Join(imagesDir, entry.Name())
		relPath := filepath.Join("data", "images", entry.Name())
		if !referenced[relPath] {
			_ = os.Remove(fullPath)
			cleaned++
		}
	}
	if cleaned > 0 {
		log.Printf("🧹 Cleaned %d orphan images", cleaned)
	}
}

// Total image size
func (s *Store) ImageDirSize(imagesDir string) int64 {
	var size int64
	_ = filepath.Walk(imagesDir, func(path string, info os.FileInfo, err error) error {
		if !info.IsDir() {
			size += info.Size()
		}
		return nil
	})
	return size
}

// Evict oldest images if total exceeds limit (200MB)
func (s *Store) EnforceImageLimit(imagesDir string, maxBytes int64) {
	size := s.ImageDirSize(imagesDir)
	if size <= maxBytes {
		return
	}

	rows, _ := s.db.Query(
		"SELECT id, COALESCE(image_path,'') FROM items WHERE image_path != '' AND pinned = 0 ORDER BY created_at ASC",
	)
	defer rows.Close()

	for rows.Next() && size > maxBytes {
		var id int
		var path string
		rows.Scan(&id, &path)
		if path != "" {
			if info, err := os.Stat(path); err == nil {
				_ = os.Remove(path)
				size -= info.Size()
				s.db.Exec("UPDATE items SET image_path = '' WHERE id = ?", id)
				log.Printf("🗑️ Evicted image: %s", filepath.Base(path))
			}
		}
	}
}

func (s *Store) Close() {
	_ = s.db.Close()
}

// DeleteRecent removes all unpinned items created within the last N minutes
func (s *Store) DeleteRecent(minutes int) (int, error) {
	interval := fmt.Sprintf("-%d minutes", minutes)
	rows, err := s.db.Query(
		"SELECT id, COALESCE(image_path,'') FROM items WHERE pinned = 0 AND created_at > datetime('now', ?)",
		interval,
	)
	if err != nil {
		return 0, err
	}
	defer rows.Close()

	var ids []int
	var paths []string
	for rows.Next() {
		var id int
		var path string
		rows.Scan(&id, &path)
		ids = append(ids, id)
		if path != "" {
			paths = append(paths, path)
		}
	}
	for _, id := range ids {
		s.db.Exec("DELETE FROM items WHERE id = ?", id)
	}
	for _, path := range paths {
		_ = os.Remove(path)
	}
	return len(ids), nil
}
