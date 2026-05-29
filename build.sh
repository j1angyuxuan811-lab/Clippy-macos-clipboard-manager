#!/bin/bash
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Clippy.app"
GO_BIN="$ROOT/go-backend"
BUNDLE_ID="com.iris.clippy"

echo "🔨 Building Go backend..."
cd "$GO_BIN"
CGO_ENABLED=1 go build -ldflags="-s -w" -o clippy-server ./main.go
echo "✅ Go backend compiled"

echo "🔨 Building Swift frontend..."
cd "$ROOT/swift-frontend"
swift build -c release 2>&1 | tail -3
echo "✅ Swift frontend compiled"

echo "📦 Assembling .app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Copy Swift binary
cp -f "$ROOT/swift-frontend/.build/release/Clippy" "$APP/Contents/MacOS/Clippy"
chmod +x "$APP/Contents/MacOS/Clippy"
# Copy Go backend binary
mkdir -p "$APP/Contents/Resources/go-backend"
cp "$GO_BIN/clippy-server" "$APP/Contents/Resources/go-backend/"

# Copy UI files
cp -r "$ROOT/ui-prototype" "$APP/Contents/Resources/"

# Write Info.plist with stable bundle identifier (required for accessibility persistence)
cat > "$APP/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>Clippy</string>
    <key>CFBundleDisplayName</key>
    <string>Clippy</string>
    <key>CFBundleExecutable</key>
    <string>Clippy</string>
    <key>CFBundleVersion</key>
    <string>1.2.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Code sign with stable identity (ad-hoc) — keeps accessibility permission across rebuilds
echo "🔏 Signing with stable identifier ($BUNDLE_ID)..."
codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"

# Prevent Spotlight from indexing the build directory (avoids duplicate in Launchpad)
touch "$ROOT/build/.metadata_never_index"

echo "✅ Build complete: $APP"
echo ""
echo "Install:"
echo "  cp -r \"$APP\" /Applications/"
echo "  open /Applications/Clippy.app"
