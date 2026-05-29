package api

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"clippy-backend/internal/db"
)

func setupTestServer(t *testing.T) (*Server, string) {
	t.Helper()
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "test.db")
	store, err := db.New(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })

	imagesDir := filepath.Join(dir, "images")
	_ = os.MkdirAll(imagesDir, 0755)

	token := "test-token-abc123"
	srv := New(store, "", imagesDir, dir, token)
	return srv, token
}

func TestHealthNoTokenRequired(t *testing.T) {
	srv, _ := setupTestServer(t)

	req := httptest.NewRequest("GET", "/api/health", nil)
	w := httptest.NewRecorder()
	srv.router.ServeHTTP(w, req)

	if w.Code != 200 {
		t.Errorf("expected 200, got %d", w.Code)
	}

	var resp map[string]interface{}
	json.NewDecoder(w.Body).Decode(&resp)
	if resp["version"] != "1.2.1" {
		t.Errorf("expected version 1.2.1, got %v", resp["version"])
	}
}

func TestAPIRequiresToken(t *testing.T) {
	srv, _ := setupTestServer(t)

	endpoints := []struct {
		method string
		path   string
	}{
		{"GET", "/api/clips"},
		{"GET", "/api/settings"},
		{"PUT", "/api/settings"},
		{"POST", "/api/pause"},
		{"POST", "/api/resume"},
		{"GET", "/api/clips/export"},
	}

	for _, ep := range endpoints {
		req := httptest.NewRequest(ep.method, ep.path, nil)
		w := httptest.NewRecorder()
		srv.router.ServeHTTP(w, req)

		if w.Code != 401 {
			t.Errorf("%s %s: expected 401 without token, got %d", ep.method, ep.path, w.Code)
		}
	}
}

func TestAPIAcceptsValidToken(t *testing.T) {
	srv, token := setupTestServer(t)

	req := httptest.NewRequest("GET", "/api/clips", nil)
	req.Header.Set("X-Clippy-Token", token)
	w := httptest.NewRecorder()
	srv.router.ServeHTTP(w, req)

	if w.Code != 200 {
		t.Errorf("expected 200 with valid token, got %d", w.Code)
	}
}

func TestAPIAcceptsTokenInQuery(t *testing.T) {
	srv, token := setupTestServer(t)

	req := httptest.NewRequest("GET", "/api/clips?token="+token, nil)
	w := httptest.NewRecorder()
	srv.router.ServeHTTP(w, req)

	if w.Code != 200 {
		t.Errorf("expected 200 with token in query, got %d", w.Code)
	}
}

func TestAPIRejectsInvalidToken(t *testing.T) {
	srv, _ := setupTestServer(t)

	req := httptest.NewRequest("GET", "/api/clips", nil)
	req.Header.Set("X-Clippy-Token", "wrong-token")
	w := httptest.NewRecorder()
	srv.router.ServeHTTP(w, req)

	if w.Code != 401 {
		t.Errorf("expected 401 with invalid token, got %d", w.Code)
	}
}

func TestCORSOnlyAllowsLocalOrigins(t *testing.T) {
	srv, token := setupTestServer(t)

	tests := []struct {
		origin        string
		expectAllowed bool
	}{
		{"http://localhost:5100", true},
		{"http://127.0.0.1:5100", true},
		{"file://", true},
		{"null", true}, // WKWebView file:// pages send Origin: null
		{"", true},
		{"http://evil.com", false},
		{"http://localhost.evil.com", false},
	}

	for _, tc := range tests {
		req := httptest.NewRequest("GET", "/api/health", nil)
		req.Header.Set("X-Clippy-Token", token)
		if tc.origin != "" {
			req.Header.Set("Origin", tc.origin)
		}
		w := httptest.NewRecorder()
		srv.router.ServeHTTP(w, req)

		acao := w.Header().Get("Access-Control-Allow-Origin")
		if tc.expectAllowed && acao == "" && tc.origin != "" {
			t.Errorf("origin %q should be allowed but got empty ACAO", tc.origin)
		}
		if !tc.expectAllowed && acao != "" {
			t.Errorf("origin %q should NOT be allowed but got ACAO=%q", tc.origin, acao)
		}
	}
}

func TestSettingsEndpoint(t *testing.T) {
	srv, token := setupTestServer(t)

	// GET settings
	req := httptest.NewRequest("GET", "/api/settings", nil)
	req.Header.Set("X-Clippy-Token", token)
	w := httptest.NewRecorder()
	srv.router.ServeHTTP(w, req)

	if w.Code != 200 {
		t.Fatalf("GET /api/settings: expected 200, got %d", w.Code)
	}

	var settings map[string]interface{}
	json.NewDecoder(w.Body).Decode(&settings)
	if settings["paste_directly"] != true {
		t.Errorf("expected paste_directly true, got %v", settings["paste_directly"])
	}

	// PUT settings
	body := `{"retention_hours":24,"ignored_apps":["com.test"],"max_items":500,"paste_directly":false}`
	req = httptest.NewRequest("PUT", "/api/settings", strings.NewReader(body))
	req.Header.Set("X-Clippy-Token", token)
	req.Header.Set("Content-Type", "application/json")
	w = httptest.NewRecorder()
	srv.router.ServeHTTP(w, req)

	if w.Code != 200 {
		t.Fatalf("PUT /api/settings: expected 200, got %d", w.Code)
	}
}

func TestPauseResumeEndpoint(t *testing.T) {
	srv, token := setupTestServer(t)

	// Pause
	body := `{"minutes":5}`
	req := httptest.NewRequest("POST", "/api/pause", strings.NewReader(body))
	req.Header.Set("X-Clippy-Token", token)
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	srv.router.ServeHTTP(w, req)

	if w.Code != 200 {
		t.Fatalf("POST /api/pause: expected 200, got %d", w.Code)
	}

	var pauseResp map[string]interface{}
	json.NewDecoder(w.Body).Decode(&pauseResp)
	if pauseResp["status"] != "paused" {
		t.Errorf("expected status 'paused', got %v", pauseResp["status"])
	}

	// Resume
	req = httptest.NewRequest("POST", "/api/resume", nil)
	req.Header.Set("X-Clippy-Token", token)
	w = httptest.NewRecorder()
	srv.router.ServeHTTP(w, req)

	if w.Code != 200 {
		t.Fatalf("POST /api/resume: expected 200, got %d", w.Code)
	}
}

func TestDeleteRecentRequiresMinutes(t *testing.T) {
	srv, token := setupTestServer(t)

	req := httptest.NewRequest("DELETE", "/api/clips/recent", nil)
	req.Header.Set("X-Clippy-Token", token)
	w := httptest.NewRecorder()
	srv.router.ServeHTTP(w, req)

	if w.Code != 400 {
		t.Errorf("expected 400 without minutes param, got %d", w.Code)
	}
}
