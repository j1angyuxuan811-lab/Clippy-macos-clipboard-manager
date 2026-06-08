#!/usr/bin/env sh
set -eu

src="${1:-swift-frontend/Sources/ClippyApp.swift}"
html="${2:-ui-prototype/index.html}"

grep -q 'setupTypingKeyboardMonitor(source: source)' "$src" || {
  echo "typing-context presentation must enable keyboard navigation routing" >&2
  exit 1
}

grep -q 'cleanupTypingKeyboardMonitor()' "$src" || {
  echo "panel hide/cleanup must remove the temporary keyboard navigation monitor" >&2
  exit 1
}

grep -q 'typingKeyboardLocalMonitor' "$src" || {
  echo "typing-context keyboard navigation must install an AppKit local keyDown fallback because WKWebView keydown can be intermittent" >&2
  exit 1
}

grep -q 'NSEvent.addLocalMonitorForEvents(matching: .keyDown)' "$src" || {
  echo "typing-context keyboard navigation must use a local keyDown monitor while the panel is visible" >&2
  exit 1
}

grep -q 'handleTypingKeyboardNavigation(event)' "$src" || {
  echo "local keyDown monitor must route Arrow/Enter/Escape through the same keyboard bridge" >&2
  exit 1
}

grep -q 'NSEvent.removeMonitor(monitor)' "$src" || {
  echo "typing-context keyboard navigation cleanup must remove the local keyDown monitor" >&2
  exit 1
}

grep -q 'acceptsKeyboardNavigationFocus' "$src" || {
  echo "typing-context presentation must allow the panel to temporarily receive keyboard navigation" >&2
  exit 1
}

grep -q 'focusPanelForKeyboardNavigation(source: source)' "$src" || {
  echo "typing-context presentation must focus the panel/WebView after positioning" >&2
  exit 1
}

show_panel_block="$(sed -n '/func showPanel(source:/,/private func syncPanelInputFocus/p' "$src")"
if printf '%s\n' "$show_panel_block" | grep -q 'webView?.reload()'; then
  echo "typing-context presentation must not reload WKWebView on every show; it can race with Arrow/Enter bridge setup" >&2
  exit 1
fi

grep -q 'refreshPanelContent(source: source)' "$src" || {
  echo "typing-context presentation must refresh content without rebuilding the WebView keyboard bridge" >&2
  exit 1
}

grep -q 'makeFirstResponder(webView)' "$src" || {
  echo "typing-context keyboard navigation must make WKWebView the first responder" >&2
  exit 1
}

grep -q 'clippyFocusKeyboardSurface' "$src" || {
  echo "Swift must ask the WebView to focus its keyboard navigation surface" >&2
  exit 1
}

if grep -q 'typingNavigationHotkeyRefs' "$src"; then
  echo "typing-context keyboard navigation must not use temporary bare Carbon hotkeys; they can swallow Arrow/Enter/Escape without dispatching" >&2
  exit 1
fi

if grep -q 'Typing navigation Carbon' "$src"; then
  echo "typing-context keyboard navigation must not rely on Carbon Arrow/Enter/Escape hotkeys" >&2
  exit 1
fi

grep -q 'handleTypingKeyboardNavigation' "$src" || {
  echo "Swift should retain CGEventTap keyboard routing only as a fallback while the key panel is visible" >&2
  exit 1
}

grep -q 'kVK_DownArrow' "$src" || {
  echo "fallback keyboard routing must include ArrowDown" >&2
  exit 1
}

grep -q 'kVK_Return' "$src" || {
  echo "fallback keyboard routing must include Enter" >&2
  exit 1
}

grep -q 'clippyKeyboardMove' "$src" || {
  echo "Swift keyboard bridge must call the WebView move-selection function" >&2
  exit 1
}

grep -q 'clippyKeyboardPasteSelected' "$src" || {
  echo "Swift keyboard bridge must call the WebView paste-selected function" >&2
  exit 1
}

grep -q 'clippyKeyboardMove' "$html" || {
  echo "WebView must expose clippyKeyboardMove for Swift-driven keyboard navigation" >&2
  exit 1
}

grep -q 'clippyKeyboardPasteSelected' "$html" || {
  echo "WebView must expose clippyKeyboardPasteSelected for Swift-driven Enter paste" >&2
  exit 1
}

grep -q 'clippyKeyboardClose' "$html" || {
  echo "WebView must expose clippyKeyboardClose for Swift-driven Escape close" >&2
  exit 1
}

grep -q 'clippyFocusKeyboardSurface' "$html" || {
  echo "WebView must expose clippyFocusKeyboardSurface so the panel can receive Arrow/Enter/Escape" >&2
  exit 1
}
