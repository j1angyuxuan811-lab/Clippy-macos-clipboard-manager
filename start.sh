#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$PROJECT_DIR/build/Clippy.app"
BACKEND_BIN="$APP_BUNDLE/Contents/Resources/go-backend/clippy-server"
DB_DIR="$HOME/Library/Application Support/Clippy"
IMAGES_DIR="$DB_DIR/images"
STATIC_DIR="$APP_BUNDLE/Contents/Resources/ui-prototype"
LOG_FILE="$DB_DIR/backend.log"

# Kill existing processes
echo "🛑 Stopping existing Clippy processes..."
pkill -f "clippy-server" 2>/dev/null || true
pkill -f "Contents/MacOS/Clippy" 2>/dev/null || true
sleep 1

# Create directories
mkdir -p "$DB_DIR"
mkdir -p "$IMAGES_DIR"

# Start backend
echo "🚀 Starting Go backend..."
"$BACKEND_BIN" -port 5100 -data "$DB_DIR" -images "$IMAGES_DIR" -static "$STATIC_DIR" > "$LOG_FILE" 2>&1 &
BACKEND_PID=$!
echo "   Backend PID: $BACKEND_PID"

# Wait for backend to start
echo "⏳ Waiting for backend to start..."
for i in {1..10}; do
    if curl -s http://localhost:5100/api/health > /dev/null 2>&1; then
        echo "   ✅ Backend is ready!"
        break
    fi
    sleep 0.5
done

# Start frontend
echo "🍎 Starting Swift frontend..."
open "$APP_BUNDLE"

echo ""
echo "✅ Clippy v2 started!"
echo "📋 Menu bar icon should appear shortly"
echo "⌨️  Press ⌘+Shift+V to open clipboard panel"
echo ""
echo "Backend API: http://localhost:5100"
echo "Log file: $LOG_FILE"
