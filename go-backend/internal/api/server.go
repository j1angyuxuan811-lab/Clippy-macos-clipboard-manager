package api

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"clippy-backend/internal/buildinfo"
	"clippy-backend/internal/clipboard"
	"clippy-backend/internal/config"
	"clippy-backend/internal/db"

	"github.com/gorilla/mux"
)

type Server struct {
	store     *db.Store
	router    *mux.Router
	imagesDir string
	apiToken  string
}

func New(store *db.Store, staticDir string, imagesDir string, dataDir string, apiToken string) *Server {
	config.Load(dataDir)

	s := &Server{
		store:     store,
		router:    mux.NewRouter(),
		imagesDir: imagesDir,
		apiToken:  apiToken,
	}
	s.routes(staticDir)
	return s
}

func (s *Server) routes(staticDir string) {
	// Auth + CORS middleware
	s.router.Use(func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// Allow static UI files and images without token (served to local WebView)
			path := r.URL.Path
			isAPI := strings.HasPrefix(path, "/api/")
			isSensitiveAsset := strings.HasPrefix(path, "/images/")

			// Tighten CORS — only allow local origins
			origin := r.Header.Get("Origin")
			allowedOrigin := false
			if origin == "" || origin == "null" || origin == "file://" {
				allowedOrigin = true
			} else if origin == "http://localhost" || strings.HasPrefix(origin, "http://localhost:") {
				allowedOrigin = true
			} else if origin == "http://127.0.0.1" || strings.HasPrefix(origin, "http://127.0.0.1:") {
				allowedOrigin = true
			}
			if allowedOrigin {
				if origin == "null" || origin == "" {
					w.Header().Set("Access-Control-Allow-Origin", "null")
				} else {
					w.Header().Set("Access-Control-Allow-Origin", origin)
				}
			}
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-Clippy-Token")
			if r.Method == "OPTIONS" {
				w.WriteHeader(200)
				return
			}

			// Token validation for API routes (except /api/health for liveness check)
			if (isAPI && path != "/api/health") || isSensitiveAsset {
				token := r.Header.Get("X-Clippy-Token")
				if token != s.apiToken {
					http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
					return
				}
			}

			next.ServeHTTP(w, r)
		})
	})

	// API routes
	api := s.router.PathPrefix("/api").Subrouter()
	api.HandleFunc("/clips", s.handleList).Methods("GET")
	api.HandleFunc("/clips", s.handleCreate).Methods("POST")
	api.HandleFunc("/clips/image", s.handleImageUpload).Methods("POST")
	api.HandleFunc("/clips/recent", s.handleDeleteRecent).Methods("DELETE")
	api.HandleFunc("/clips/export", s.handleExport).Methods("GET")
	api.HandleFunc("/clips/{id}", s.handleDelete).Methods("DELETE")
	api.HandleFunc("/clips/{id}/pin", s.handlePin).Methods("PUT")
	api.HandleFunc("/clips/{id}/copy", s.handleCopy).Methods("POST")
	api.HandleFunc("/health", s.handleHealth).Methods("GET")
	api.HandleFunc("/settings", s.handleGetSettings).Methods("GET")
	api.HandleFunc("/settings", s.handleUpdateSettings).Methods("PUT")
	api.HandleFunc("/pause", s.handlePause).Methods("POST")
	api.HandleFunc("/resume", s.handleResume).Methods("POST")
	api.HandleFunc("/privacy/status", s.handlePrivacyStatus).Methods("GET")

	// Image serving
	s.router.HandleFunc("/images/{filename}", s.handleImage).Methods("GET")

	// Static UI files
	if staticDir != "" {
		s.router.PathPrefix("/").Handler(http.FileServer(http.Dir(staticDir)))
	}
}

func (s *Server) ListenAndServe(addr string) error {
	log.Printf("🌐 API server at %s", addr)
	return http.ListenAndServe(addr, s.router)
}

func (s *Server) handleList(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query().Get("q")
	var clips []db.Item
	var err error

	if query != "" {
		clips, err = s.store.Search(query)
	} else {
		clips, err = s.store.List(200)
	}

	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	if clips == nil {
		clips = []db.Item{}
	}

	// Add absolute image paths for WebView access
	type ClipJSON struct {
		ID           int    `json:"id"`
		Content      string `json:"content"`
		ContentType  string `json:"content_type"`
		ImagePath    string `json:"image_path,omitempty"`
		ImageAbsPath string `json:"image_abs_path,omitempty"`
		Tags         string `json:"tags"`
		IsPinned     bool   `json:"pinned"`
		HotCount     int    `json:"hot_count"`
		CreatedAt    string `json:"created_at"`
	}
	result := make([]ClipJSON, 0, len(clips))
	for _, c := range clips {
		cj := ClipJSON{
			ID: c.ID, Content: c.Content, ContentType: c.ContentType,
			ImagePath: c.ImagePath, Tags: c.Tags, IsPinned: c.IsPinned,
			HotCount: c.HotCount, CreatedAt: c.CreatedAt,
		}
		if c.ImagePath != "" {
			absPath := filepath.Join(s.imagesDir, filepath.Base(c.ImagePath))
			cj.ImageAbsPath = absPath
		}
		result = append(result, cj)
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"clips": result,
		"count": len(result),
	})
}

func (s *Server) handleCreate(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Content string `json:"content"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid body", 400)
		return
	}

	contentType := detectType(req.Content)
	item, err := s.store.Create(req.Content, contentType, "")
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	if item == nil {
		json.NewEncoder(w).Encode(map[string]string{"status": "duplicate"})
		return
	}
	json.NewEncoder(w).Encode(item)
}

func (s *Server) handleImageUpload(w http.ResponseWriter, r *http.Request) {
	// Max 10MB
	r.ParseMultipartForm(10 << 20)

	file, header, err := r.FormFile("image")
	if err != nil {
		http.Error(w, "missing image file", 400)
		return
	}
	defer file.Close()

	// Validate extension
	ext := strings.ToLower(filepath.Ext(header.Filename))
	if ext != ".png" && ext != ".jpg" && ext != ".jpeg" && ext != ".gif" && ext != ".webp" {
		http.Error(w, "unsupported image type", 400)
		return
	}

	// Save with unique name
	filename := fmt.Sprintf("clip_%d%s", time.Now().UnixNano(), ext)
	dst := filepath.Join(s.imagesDir, filename)

	out, err := os.Create(dst)
	if err != nil {
		http.Error(w, "failed to save image", 500)
		return
	}
	defer out.Close()
	io.Copy(out, file)

	// Get file size for logging
	info, _ := os.Stat(dst)
	sizeKB := float64(info.Size()) / 1024

	// Store in DB
	content := "[图片]"
	item, err := s.store.Create(content, "image", filename)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	if item == nil {
		json.NewEncoder(w).Encode(map[string]string{"status": "duplicate"})
		return
	}

	log.Printf("🖼️ Image received: %s (%.1f KB)", filename, sizeKB)
	json.NewEncoder(w).Encode(item)
}

func (s *Server) handleDelete(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.Atoi(mux.Vars(r)["id"])
	err := s.store.Delete(id)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	json.NewEncoder(w).Encode(map[string]string{"status": "deleted"})
}

func (s *Server) handlePin(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.Atoi(mux.Vars(r)["id"])
	err := s.store.TogglePin(id)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	json.NewEncoder(w).Encode(map[string]string{"status": "toggled"})
}

// handleCopy - returns clip data. For images, also returns the full image path
// so Swift can read it and put it on the system clipboard via NSPasteboard.
func (s *Server) handleCopy(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.Atoi(mux.Vars(r)["id"])
	item, err := s.store.Get(id)
	if err != nil {
		http.Error(w, err.Error(), 404)
		return
	}

	// For image clips, return the absolute image file path
	response := map[string]interface{}{
		"id":           item.ID,
		"content":      item.Content,
		"content_type": item.ContentType,
		"image_path":   item.ImagePath,
		"pinned":       item.IsPinned,
		"created_at":   item.CreatedAt,
	}

	if item.ContentType == "image" && item.ImagePath != "" {
		absPath := filepath.Join(s.imagesDir, filepath.Base(item.ImagePath))
		response["image_abs_path"] = absPath
		log.Printf("📋 Copy requested for image: %s", absPath)
	}

	json.NewEncoder(w).Encode(response)
}

func (s *Server) handleExport(w http.ResponseWriter, r *http.Request) {
	clips, err := s.store.List(200)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	if clips == nil {
		clips = []db.Item{}
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Disposition", "attachment; filename=clippy-export.json")
	json.NewEncoder(w).Encode(clips)
}

func (s *Server) handleImage(w http.ResponseWriter, r *http.Request) {
	filename := mux.Vars(r)["filename"]
	// Strip any directory prefix (e.g., "data/images/xxx.png" -> "xxx.png")
	filename = filepath.Base(filename)
	path := filepath.Join(s.imagesDir, filename)

	if _, err := os.Stat(path); os.IsNotExist(err) {
		http.Error(w, "not found", 404)
		return
	}

	http.ServeFile(w, r, path)
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	paused := config.IsPaused()
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":  "ok",
		"version": buildinfo.Version,
		"paused":  paused,
	})
}

func (s *Server) handleGetSettings(w http.ResponseWriter, r *http.Request) {
	cfg := config.Get()
	response := map[string]interface{}{
		"retention_hours": cfg.RetentionHours,
		"ignored_apps":    cfg.IgnoredApps,
		"max_items":       cfg.MaxItems,
		"paste_directly":  cfg.PasteDirectly,
		"paused_until":    cfg.PausedUntil,
		"is_paused":       config.IsPaused(),
		"hotkey_combo":    cfg.HotkeyCombo,
	}
	json.NewEncoder(w).Encode(response)
}

func (s *Server) handleUpdateSettings(w http.ResponseWriter, r *http.Request) {
	var newCfg config.Config
	if err := json.NewDecoder(r.Body).Decode(&newCfg); err != nil {
		http.Error(w, "invalid body", 400)
		return
	}
	if err := config.Update(&newCfg); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	log.Printf("⚙️ Settings updated: retention=%dh, ignored=%v, paste_directly=%v",
		newCfg.RetentionHours, newCfg.IgnoredApps, newCfg.PasteDirectly)
	json.NewEncoder(w).Encode(config.Get())
}

func (s *Server) handlePause(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Minutes int `json:"minutes"` // 5, 15, 30, 60
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Minutes <= 0 {
		http.Error(w, "invalid body: need {\"minutes\": N}", 400)
		return
	}
	if req.Minutes > 1440 { // max 24h
		req.Minutes = 1440
	}
	config.Pause(time.Duration(req.Minutes) * time.Minute)
	log.Printf("⏸️ Recording paused for %d minutes", req.Minutes)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":       "paused",
		"minutes":      req.Minutes,
		"paused_until": config.Get().PausedUntil,
	})
}

func (s *Server) handleResume(w http.ResponseWriter, r *http.Request) {
	config.Resume()
	log.Printf("▶️ Recording resumed")
	json.NewEncoder(w).Encode(map[string]string{"status": "resumed"})
}

func (s *Server) handlePrivacyStatus(w http.ResponseWriter, r *http.Request) {
	json.NewEncoder(w).Encode(clipboard.CurrentStatus())
}

func (s *Server) handleDeleteRecent(w http.ResponseWriter, r *http.Request) {
	minutesStr := r.URL.Query().Get("minutes")
	minutes, err := strconv.Atoi(minutesStr)
	if err != nil || minutes <= 0 {
		http.Error(w, "need ?minutes=N (5, 15, 30)", 400)
		return
	}
	if minutes > 1440 {
		minutes = 1440
	}
	count, err := s.store.DeleteRecent(minutes)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	log.Printf("🗑️ Cleared %d clips from last %d minutes", count, minutes)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":  "cleared",
		"deleted": count,
		"minutes": minutes,
	})
}

func detectType(content string) string {
	lower := strings.ToLower(strings.TrimSpace(content))

	// URL
	if strings.HasPrefix(lower, "http://") || strings.HasPrefix(lower, "https://") {
		return "link"
	}

	// Code indicators
	codeIndicators := []string{"func ", "function ", "def ", "class ", "import ", "package ",
		"const ", "let ", "var ", "{", "}", "//", "/*", "*/", "=>"}
	for _, ind := range codeIndicators {
		if strings.Contains(lower, ind) {
			return "code"
		}
	}

	return "text"
}
