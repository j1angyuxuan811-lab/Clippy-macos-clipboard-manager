#!/usr/bin/env sh
set -eu

src="${1:-swift-frontend/Sources/ClippyApp.swift}"

grep -q 'nonactivatingPanel' "$src" || {
  echo "typing-context panel must use .nonactivatingPanel so the source input keeps focus" >&2
  exit 1
}

grep -q 'preservesSourceInputFocus' "$src" || {
  echo "ClippyPanel must track whether the current presentation preserves source input focus" >&2
  exit 1
}

grep -q 'acceptsKeyboardNavigationFocus' "$src" || {
  echo "ClippyPanel must distinguish captured paste-target focus from temporary keyboard navigation focus" >&2
  exit 1
}

grep -q 'override var canBecomeKey: Bool { acceptsKeyboardNavigationFocus || !preservesSourceInputFocus }' "$src" || {
  echo "ClippyPanel must become key for typing-context keyboard navigation without losing the captured paste target" >&2
  exit 1
}

grep -q 'override var canBecomeMain: Bool { acceptsKeyboardNavigationFocus || !preservesSourceInputFocus }' "$src" || {
  echo "ClippyPanel must be able to receive key navigation while keeping the captured paste target separate" >&2
  exit 1
}

focus_block="$(sed -n '/private func configurePanelFocus/,/private func presentPanel/p' "$src")"
printf '%s\n' "$focus_block" | grep -q 'case \.typingContext:' || {
  echo "panel focus mode must handle typing-context presentation explicitly" >&2
  exit 1
}
printf '%s\n' "$focus_block" | grep -q 'preservesSourceInputFocus = true' || {
  echo "typing-context presentation must preserve the source paste target before taking keyboard focus" >&2
  exit 1
}
printf '%s\n' "$focus_block" | grep -q 'acceptsKeyboardNavigationFocus = true' || {
  echo "typing-context presentation must enable temporary keyboard navigation focus" >&2
  exit 1
}
present_typing_block="$(sed -n '/private func presentPanel/,/case \.statusItem:/p' "$src")"

if printf '%s\n' "$present_typing_block" | grep -q 'NSApp.activate'; then
  echo "showPanel must not activate Clippy because that hides the original input caret" >&2
  exit 1
fi

if ! printf '%s\n' "$present_typing_block" | grep -q 'makeKeyAndOrderFront'; then
  echo "typing-context presentation must make the nonactivating panel key so Arrow/Enter/Escape reach Clippy" >&2
  exit 1
fi

prepare_block="$(sed -n '/private func prepareForPanelPresentation/,/private func configurePanelFocus/p' "$src")"
printf '%s\n' "$prepare_block" | grep -q 'capturePasteTargetApp()' || {
  echo "typing-context presentation must capture the original app before the panel takes keyboard focus" >&2
  exit 1
}
printf '%s\n' "$prepare_block" | grep -q 'captureFocusedTextElement()' || {
  echo "typing-context presentation must capture the original focused text element before the panel takes keyboard focus" >&2
  exit 1
}

grep -q 'Panel shown source=' "$src" || {
  echo "panel show logs must include source and focus state for runtime verification" >&2
  exit 1
}
