#!/bin/bash
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/.clippy-build/Clippy.app"
GO_BIN="$ROOT/go-backend"
BUNDLE_ID="com.iris.clippy"
VERSION="1.2.1"

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
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
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

# Prefer a stable local identity so macOS Accessibility (TCC) permissions survive rebuilds.
SIGN_IDENTITY="${CLIPPY_CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Clippy Local Code Signing/ { print $2; exit }')"
fi

if [ -n "$SIGN_IDENTITY" ]; then
  echo "🔏 Signing with stable identity: $SIGN_IDENTITY"
  codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
  echo "⚠️ No stable code signing identity found; falling back to ad-hoc signing."
  echo "⚠️ Accessibility permission may need to be re-enabled after each rebuild."
  ADHOC_IDENTITY="-"
  codesign --force --deep --sign "$ADHOC_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
fi

# Keep the staging bundle hidden and out of Spotlight so it does not appear as a second app.
touch "$ROOT/.clippy-build/.metadata_never_index"

echo "✅ Build complete: $APP"
echo ""
echo "Install:"
echo "  ./install.sh"
