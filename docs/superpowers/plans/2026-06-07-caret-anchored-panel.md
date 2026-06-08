# Caret-Anchored Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Clippy's hotkey-opened panel appear near the current text caret when possible, while preserving menu-bar clicks as a menu-bar anchored list.

**Architecture:** Add an explicit panel presentation source so hotkeys and status-item clicks do not share the same placement path. Resolve the panel anchor in Swift using Accessibility caret bounds first, then mouse location, then the status item. Keep placement clamped inside the active screen's visible frame.

**Tech Stack:** Swift/AppKit, macOS Accessibility APIs, existing `NSPanel`, existing shell regression checks.

---

### Task 1: Lock Placement Contract

**Files:**
- Create: `swift-frontend/Tests/caret-panel-placement-contract.sh`
- Modify: `swift-frontend/Sources/ClippyApp.swift`

- [ ] **Step 1: Write failing contract check**

```sh
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
```

- [ ] **Step 2: Verify contract fails**

Run: `sh swift-frontend/Tests/caret-panel-placement-contract.sh swift-frontend/Sources/ClippyApp.swift`

Expected: non-zero because the source enum and placement helpers do not exist yet.

### Task 2: Add Source-Specific Presentation

**Files:**
- Modify: `swift-frontend/Sources/ClippyApp.swift`
- Test: `swift-frontend/Tests/caret-panel-placement-contract.sh`

- [ ] **Step 1: Implement minimal source enum and route call sites**

Code shape:

```swift
enum PanelPresentationSource {
    case statusItem
    case typingContext
}

func togglePanel(source: PanelPresentationSource) { ... }
func showPanel(source: PanelPresentationSource) { ... }
```

Hotkey handlers call `togglePanel(source: .typingContext)`. Status item left-click and double-click call `.statusItem`.

- [ ] **Step 2: Verify contract still fails for missing anchor helpers**

Run: `sh swift-frontend/Tests/caret-panel-placement-contract.sh swift-frontend/Sources/ClippyApp.swift`

Expected: non-zero until placement helpers exist.

### Task 3: Add Anchor Resolution and Clamping

**Files:**
- Modify: `swift-frontend/Sources/ClippyApp.swift`
- Test: `swift-frontend/Tests/caret-panel-placement-contract.sh`

- [ ] **Step 1: Implement placement helpers**

Code shape:

```swift
private func positionPanel(_ panel: NSPanel, source: PanelPresentationSource) {
    let panelSize = panel.frame.size
    let anchor = source == .typingContext
        ? (resolveTypingAnchor() ?? resolveMouseAnchor() ?? resolveStatusItemAnchor())
        : resolveStatusItemAnchor()
    guard let anchor else { return }
    panel.setFrameOrigin(clampedPanelOrigin(anchor: anchor, panelSize: panelSize))
}
```

- [ ] **Step 2: Run contract check**

Run: `sh swift-frontend/Tests/caret-panel-placement-contract.sh swift-frontend/Sources/ClippyApp.swift`

Expected: exit 0.

### Task 4: Build and Installed-App Verification

**Files:**
- Modify: `swift-frontend/Sources/ClippyApp.swift`
- Test: `swift-frontend/Tests/caret-panel-placement-contract.sh`

- [ ] **Step 1: Build/install**

Run: `./start.sh`

Expected: Clippy 1.2.1 installs and launches.

- [ ] **Step 2: Verify runtime health**

Run: `curl -fsS http://127.0.0.1:5100/api/health`

Expected: `{"paused":false,"status":"ok","version":"1.2.1"}`.

- [ ] **Step 3: Verify menu-bar entry remains available**

Use System Events or manual observation to confirm right-click still shows `退出 Clippy`, and left-click still opens the list from the status item.

### Task 5: Restore Paste Target Before Direct Paste

**Files:**
- Modify: `swift-frontend/Sources/ClippyApp.swift`
- Test: `swift-frontend/Tests/paste-target-contract.sh`

- [ ] **Step 1: Write failing paste-target contract**

```sh
#!/usr/bin/env sh
set -eu

src="${1:-swift-frontend/Sources/ClippyApp.swift}"

grep -q 'lastPasteTargetApp' "$src"
grep -q 'capturePasteTargetApp()' "$src"
grep -q 'restorePasteTargetApp()' "$src"
grep -q 'restorePasteTargetApp()' "$src"
grep -q 'simulatePaste()' "$src"

if ! sed -n '/case \\.typingContext:/,/case \\.statusItem:/p' "$src" | grep -q 'capturePasteTargetApp()'; then
  echo "typing-context panel opens must capture the original paste target app" >&2
  exit 1
fi

if ! sed -n '/private func pasteTextToActiveApp/,/private func copyImageToClipboard/p' "$src" | grep -q 'pasteToLastTargetApp'; then
  echo "text clip selection must restore the captured target before paste" >&2
  exit 1
fi

if ! sed -n '/private func copyImageToClipboard/,/private func sendPasteResult/p' "$src" | grep -q 'pasteToLastTargetApp'; then
  echo "image clip selection must restore the captured target before paste" >&2
  exit 1
fi
```

- [ ] **Step 2: Implement minimal paste-target restoration**

Add `lastPasteTargetApp: NSRunningApplication?`. When opening from `.typingContext`, capture `NSWorkspace.shared.frontmostApplication` before activating Clippy. When a clip is selected and direct paste is enabled, hide Clippy, activate the captured target app, then post Cmd+V.

- [ ] **Step 3: Verify contract and build**

Run:

```sh
sh swift-frontend/Tests/paste-target-contract.sh swift-frontend/Sources/ClippyApp.swift
./build.sh
```

Expected: both exit 0.
