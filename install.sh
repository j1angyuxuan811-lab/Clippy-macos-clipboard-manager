#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/.clippy-build/Clippy.app"
TARGET="/Applications/Clippy.app"
VERSION="1.2.1"

if [ ! -d "$APP" ]; then
  echo "Missing build bundle: $APP"
  echo "Run ./build.sh first."
  exit 1
fi

echo "Stopping existing Clippy processes..."
pkill -f "/Applications/Clippy.app/Contents/MacOS/Clippy" 2>/dev/null || true
pkill -f "/Applications/Clippy.app/Contents/Resources/go-backend/clippy-server" 2>/dev/null || true
pkill -f "$ROOT/build/Clippy.app/Contents/MacOS/Clippy" 2>/dev/null || true
pkill -f "$ROOT/build/Clippy.app/Contents/Resources/go-backend/clippy-server" 2>/dev/null || true
pkill -f "Clippy.app/Contents/MacOS/Clippy" 2>/dev/null || true
pkill -f "Clippy.app/Contents/Resources/go-backend/clippy-server" 2>/dev/null || true
pkill -f "clippy-server -port 5100" 2>/dev/null || true
sleep 1

echo "Installing $APP -> $TARGET..."
rm -rf "$TARGET"
ditto "$APP" "$TARGET"
rm -rf "$APP"
rm -rf "$ROOT/build/Clippy.app"
touch "$ROOT/.clippy-build/.metadata_never_index"

echo "Launching Clippy..."
open "$TARGET"

echo "Checking backend version..."
for _ in {1..30}; do
  if curl -fsS "http://127.0.0.1:5100/api/health" | grep -q "\"version\":\"$VERSION\""; then
    echo "Clippy $VERSION installed and running."
    exit 0
  fi
  sleep 0.5
done

echo "Install finished, but /api/health did not report version $VERSION."
echo "Check ~/Library/Application Support/Clippy and /tmp/clippy-backend-*.log."
exit 1
