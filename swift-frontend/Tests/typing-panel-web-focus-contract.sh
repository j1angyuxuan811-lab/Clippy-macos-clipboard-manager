#!/usr/bin/env sh
set -eu

swift_src="${1:-swift-frontend/Sources/ClippyApp.swift}"
html_src="${2:-ui-prototype/index.html}"

if grep -q 'autofocus' "$html_src"; then
  echo "hotkey panel must not autofocus the WebView search input because it hides the source input caret" >&2
  exit 1
fi

grep -q 'syncPanelInputFocus(source:' "$swift_src" || {
  echo "panel presentation must explicitly sync WebView keyboard focus for typing-context opens" >&2
  exit 1
}

focus_block="$(sed -n '/private func syncPanelInputFocus/,/private func prepareForPanelPresentation/p' "$swift_src")"
printf '%s\n' "$focus_block" | grep -q 'focusPanelForKeyboardNavigation(source: source)' || {
  echo "typing-context opens must focus the Clippy keyboard navigation surface" >&2
  exit 1
}

focus_func="$(sed -n '/private func focusPanelForKeyboardNavigation/,/private func logPanelShown/p' "$swift_src")"
printf '%s\n' "$focus_func" | grep -q 'guard source == \.typingContext' || {
  echo "keyboard focus helper must only auto-focus the WebView for typing-context opens" >&2
  exit 1
}
printf '%s\n' "$focus_func" | grep -q 'makeFirstResponder(webView)' || {
  echo "keyboard focus helper must make WKWebView the first responder" >&2
  exit 1
}

grep -q 'document.body.focus' "$html_src" || {
  echo "WebView must focus the document body so Arrow/Enter/Escape are handled by Clippy" >&2
  exit 1
}
