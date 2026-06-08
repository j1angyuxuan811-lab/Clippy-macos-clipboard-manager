#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="1.2.1"

echo "Building Clippy $VERSION..."
"$PROJECT_DIR/build.sh"

echo "Installing and launching /Applications/Clippy.app..."
"$PROJECT_DIR/install.sh"
