#!/usr/bin/env sh
set -eu

src="${1:-build.sh}"

grep -q 'CLIPPY_CODESIGN_IDENTITY' "$src" || {
  echo "build.sh must allow a stable CLIPPY_CODESIGN_IDENTITY for TCC persistence" >&2
  exit 1
}

grep -q 'Clippy Local Code Signing' "$src" || {
  echo "build.sh must auto-detect the local Clippy code signing identity" >&2
  exit 1
}

grep -q 'codesign --force --deep --sign "$SIGN_IDENTITY"' "$src" || {
  echo "build.sh must sign with the resolved stable identity when available" >&2
  exit 1
}

if grep -q 'codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"' "$src"; then
  echo "build.sh must not unconditionally ad-hoc sign; that changes cdhash and breaks Accessibility permission" >&2
  exit 1
fi
