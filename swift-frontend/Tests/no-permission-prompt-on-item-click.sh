#!/usr/bin/env sh
set -eu

src="${1:-swift-frontend/Sources/ClippyApp.swift}"

paste_block="$(sed -n '/private func pasteTextToActiveApp/,/private func copyImageToClipboard/p' "$src")"
image_block="$(sed -n '/private func copyImageToClipboard/,/private func sendPasteResult/p' "$src")"

if printf '%s\n' "$paste_block" | grep -q 'requestAccessibilityIfNeeded'; then
  echo "pasteTextToActiveApp must not open the Accessibility prompt while clicking a clipboard item." >&2
  exit 1
fi

if printf '%s\n' "$image_block" | grep -q 'requestAccessibilityIfNeeded'; then
  echo "copyImageToClipboard must not open the Accessibility prompt while clicking a clipboard item." >&2
  exit 1
fi

if ! grep -q 'func refreshAccessibilityStatus() -> Bool' "$src"; then
  echo "AppDelegate should refresh AXIsProcessTrusted before paste decisions." >&2
  exit 1
fi
