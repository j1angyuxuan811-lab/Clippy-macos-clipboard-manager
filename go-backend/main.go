package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"

	"clippy-backend/internal/api"
	"clippy-backend/internal/buildinfo"
	"clippy-backend/internal/clipboard"
	"clippy-backend/internal/db"
)

func main() {
	port := flag.String("port", "5100", "API server port")
	dataDir := flag.String("data", "./data", "Data directory")
	staticDir := flag.String("static", "./ui-prototype", "Static files directory")
	imagesDir := flag.String("images", "./data/images", "Images directory")
	flag.Parse()

	_ = os.MkdirAll(*dataDir, 0755)
	_ = os.MkdirAll(*imagesDir, 0755)

	absDataDir, _ := filepath.Abs(*dataDir)

	// ── Single instance: check if another server is already running ──
	if isBackendAlive(*port) {
		log.Printf("✅ Clippy backend already running on port %s, exiting.", *port)
		os.Exit(0)
	}

	// Write PID file
	pidFile := filepath.Join(absDataDir, "clippy.pid")
	_ = os.WriteFile(pidFile, []byte(strconv.Itoa(os.Getpid())), 0644)
	defer os.Remove(pidFile)

	// Generate random API token for this session
	tokenBytes := make([]byte, 32)
	if _, err := rand.Read(tokenBytes); err != nil {
		log.Fatalf("Failed to generate API token: %v", err)
	}
	apiToken := hex.EncodeToString(tokenBytes)
	tokenFile := filepath.Join(absDataDir, "api_token")
	_ = os.WriteFile(tokenFile, []byte(apiToken), 0600)
	defer os.Remove(tokenFile)

	// Check port available
	ln, err := net.Listen("tcp", "127.0.0.1:"+*port)
	if err != nil {
		log.Fatalf("❌ Port %s is occupied: %v", *port, err)
	}
	ln.Close()

	dbPath := filepath.Join(absDataDir, "clippy.db")

	store, err := db.New(dbPath)
	if err != nil {
		log.Fatalf("Failed to open database: %v", err)
	}

	// Startup cleanup using configured retention
	store.CleanupExpired()
	store.CleanupOrphanImages(*imagesDir)
	store.EnforceImageLimit(*imagesDir, 200*1024*1024) // 200MB limit

	monitor := clipboard.New(store, *imagesDir)
	go monitor.Start()

	server := api.New(store, *staticDir, *imagesDir, absDataDir, apiToken)

	go func() {
		if err := server.ListenAndServe("127.0.0.1:" + *port); err != nil {
			log.Printf("Server error: %v", err)
		}
	}()

	log.Printf("✅ Clippy backend started on port %s (PID %d)", *port, os.Getpid())

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig

	log.Println("👋 Shutting down...")
	store.Close()
}

func isBackendAlive(port string) bool {
	resp, err := http.Get(fmt.Sprintf("http://localhost:%s/api/health", port))
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return false
	}
	var health struct {
		Version string `json:"version"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&health); err != nil {
		return false
	}
	return health.Version == buildinfo.Version
}
