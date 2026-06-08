#!/usr/bin/env sh
set -eu

src="${1:-swift-frontend/Sources/ClippyApp.swift}"

grep -q 'preferredPanelOrigin' "$src" || {
  echo "caret placement must use a named preferredPanelOrigin helper" >&2
  exit 1
}

grep -q 'anchor.x - panelSize.width / 2' "$src" || {
  echo "caret panel should be horizontally centered around the caret, not forced to the right" >&2
  exit 1
}

grep -q 'originBelowCaret' "$src" || {
  echo "caret panel should model a below-caret candidate like Windows clipboard" >&2
  exit 1
}

grep -q 'originAboveCaret' "$src" || {
  echo "caret panel should have an above-caret fallback when there is no room below" >&2
  exit 1
}

grep -q 'if fits(originBelowCaret' "$src" || {
  echo "caret panel should prefer below-caret placement when it fits" >&2
  exit 1
}

grep -q 'if fits(originAboveCaret' "$src" || {
  echo "caret panel should fall back above the caret when below does not fit" >&2
  exit 1
}

grep -q 'reliableTypingAnchor' "$src" || {
  echo "typing placement must reject unreliable AX anchors before clamping to screen corners" >&2
  exit 1
}

grep -q 'lastFocusedElementFrame' "$src" || {
  echo "typing placement must capture the focused input frame, not only the caret point" >&2
  exit 1
}

grep -q 'focusedElementFrame' "$src" || {
  echo "typing placement must read the focused element frame from Accessibility" >&2
  exit 1
}

grep -q 'accessibilityParent' "$src" || {
  echo "typing placement must climb to an Accessibility parent frame when the focused text node has no size" >&2
  exit 1
}

grep -q 'avoidRect:' "$src" || {
  echo "panel placement must accept an avoidRect so it can avoid the full input box" >&2
  exit 1
}

grep -q 'lastPanelAvoidanceSource' "$src" || {
  echo "panel logs must report whether avoidance came from a focused frame or caret-band fallback" >&2
  exit 1
}

grep -q 'inferredCaretAvoidanceRect' "$src" || {
  echo "typing placement must infer a caret-band avoid rect when apps do not expose an input frame" >&2
  exit 1
}

grep -q 'inputAvoidanceRect' "$src" || {
  echo "typing placement must expand thin focused frames into an input-area avoidance rect" >&2
  exit 1
}

grep -q 'anchorFromFocusedElementFrame' "$src" || {
  echo "typing placement must prefer a focused-frame anchor before falling back to mouse position" >&2
  exit 1
}

grep -q 'originAboveAvoidRect' "$src" || {
  echo "panel placement must try above the focused input box when the input box is tall" >&2
  exit 1
}

grep -q 'originBelowAvoidRect' "$src" || {
  echo "panel placement must try below the inferred input band when there is no room above" >&2
  exit 1
}

grep -q 'originRightOfAvoidRect' "$src" || {
  echo "panel placement must have a side fallback when vertical avoid-rect placement cannot fit" >&2
  exit 1
}

grep -q 'doesNotIntersect' "$src" || {
  echo "panel placement candidates must reject overlap with the focused input box" >&2
  exit 1
}

grep -q 'let panelHeight: CGFloat = 360' "$src" || {
  echo "typing panel should stay compact enough not to cover chat input rows" >&2
  exit 1
}

paste_block="$(sed -n '/private func pasteTextToActiveApp/,/private func copyImageToClipboard/p' "$src")"
cmd_line="$(printf '%s\n' "$paste_block" | grep -n 'pasteToLastTargetApp' | head -1 | cut -d: -f1)"
insert_line="$(printf '%s\n' "$paste_block" | grep -n 'insertTextIntoCapturedTextElement' | head -1 | cut -d: -f1)"

if [ -z "$cmd_line" ] || [ -z "$insert_line" ] || [ "$cmd_line" -ge "$insert_line" ]; then
  echo "text selection should prefer system Cmd+V before AXValue direct insertion so editors keep the caret position" >&2
  exit 1
fi
