#!/usr/bin/env sh
set -eu

src="${1:-swift-frontend/Sources/ClippyApp.swift}"

grep -q 'lastPasteTargetApp' "$src"
grep -q 'capturePasteTargetApp()' "$src"
grep -q 'restorePasteTargetApp()' "$src"
grep -q 'pasteToLastTargetApp' "$src"
grep -q 'simulatePaste()' "$src"
grep -q 'logPasteDecision' "$src"
grep -q 'lastFocusedTextElement' "$src"
grep -q 'lastSelectedTextRange' "$src"
grep -q 'insertTextIntoCapturedTextElement' "$src"

if ! sed -n '/case \.typingContext:/,/case \.statusItem:/p' "$src" | grep -q 'capturePasteTargetApp()'; then
  echo "typing-context panel opens must capture the original paste target app" >&2
  exit 1
fi

if ! sed -n '/private func pasteTextToActiveApp/,/private func copyImageToClipboard/p' "$src" | grep -q 'pasteToLastTargetApp'; then
  echo "text clip selection must restore the captured target before paste" >&2
  exit 1
fi

if ! sed -n '/private func pasteTextToActiveApp/,/private func copyImageToClipboard/p' "$src" | grep -q 'insertTextIntoCapturedTextElement'; then
  echo "text clip selection must first try direct insertion into the captured input element" >&2
  exit 1
fi

if ! sed -n '/private func copyImageToClipboard/,/private func sendPasteResult/p' "$src" | grep -q 'pasteToLastTargetApp'; then
  echo "image clip selection must restore the captured target before paste" >&2
  exit 1
fi
