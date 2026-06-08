# Caret-Anchored Panel Design

## Goal

When the user presses the Clippy hotkey while typing in another app, the panel should appear near the current text insertion caret, similar to the Windows clipboard panel. The menu-bar position should become a fallback, not the primary placement.

## Placement Priority

1. Caret anchor: if the focused app exposes a text caret rectangle through Accessibility, place the panel below or to the lower-right of that caret.
2. Mouse anchor: if the caret rectangle is unavailable, place the panel near the current mouse position.
3. Status-item anchor: if neither caret nor mouse placement is suitable, fall back to the current menu-bar status item placement.

## Positioning Rules

- Keep the full panel inside the active screen's visible frame.
- Flip horizontally or vertically when the caret is near the right or bottom screen edge.
- Support multiple displays by using the screen that contains the resolved anchor point.
- Use a small offset from the caret so the panel does not cover the current insertion point.
- Preserve the existing menu-bar placement as the final fallback.

## Focus Behavior

The panel should avoid stealing focus from the original input field when possible. Direct paste depends on the original target app remaining the intended paste destination after the user selects a clip.

## Accessibility Constraints

Caret placement depends on macOS Accessibility APIs. Some apps may not expose focused elements, selected text ranges, or caret bounds. Those cases should not block Clippy; they should route to the fallback placement path.

## Success Criteria

- Pressing the hotkey in a normal text field opens Clippy near the insertion caret.
- Pressing the hotkey in an app that does not expose caret bounds still opens Clippy predictably near the mouse or menu bar.
- The panel never opens off-screen.
- Selecting a clip still copies the item and, when Accessibility direct paste is active, pastes into the original text field.
