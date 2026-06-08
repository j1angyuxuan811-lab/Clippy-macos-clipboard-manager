#!/usr/bin/env sh
set -eu

src="${1:-swift-frontend/Sources/ClippyApp.swift}"

grep -q 'enum PanelPresentationSource' "$src"
grep -q 'showPanel(source: .typingContext)' "$src"
grep -q 'showPanel(source: .statusItem)' "$src"
grep -q 'resolveTypingAnchor' "$src"
grep -q 'resolveMouseAnchor' "$src"
grep -q 'positionPanel' "$src"

if sed -n '/@objc func statusItemClicked/,/func setupPanel/p' "$src" | grep -q 'togglePanel(source: .typingContext)'; then
  echo "status item clicks must not use typing-context placement" >&2
  exit 1
fi
