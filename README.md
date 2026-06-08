# Clippy - macOS Clipboard Manager

Clippy is a local-first macOS clipboard manager for keyboard-first paste workflows. It runs as a menu bar app and focuses on a Windows-style clipboard interaction: press `Command + Shift + V` in any text field, choose an item with the keyboard, and paste it back into the original app.

Current version: `1.2.1`

## Features

- **Global shortcut**: `Command + Shift + V` opens the clipboard panel from any app.
- **Caret-aware panel placement**: in typing contexts, the panel is positioned near the input caret and avoids covering the active input area when Accessibility data is available.
- **Keyboard-first workflow**: `Up` / `Down` selects items, `Enter` pastes, `Esc` closes.
- **Direct paste flow**: Clippy captures the source app before opening the panel, then restores it and triggers paste after selection.
- **Stable keyboard fallback**: AppKit local key handling backs up WKWebView keyboard events for Arrow / Enter / Esc navigation.
- **Local clipboard history**: Go backend polls the macOS clipboard, stores items in SQLite, and deduplicates repeated content.
- **Text, code, URL, and image support**: image captures are stored locally and deduplicated by hash.
- **UTF-8 text handling**: clipboard text is read through UTF-8 plain-text candidates first, with replacement-character noise filtered before storage.
- **Privacy controls**: local-only API on `127.0.0.1`, random session token for sensitive API calls, default ignored sensitive apps, pause/resume, and recent-history cleanup.
- **Configurable retention**: default retention is 7 days, with pinned items preserved.
- **Liquid glass UI**: AppKit `NSVisualEffectView` shell with a lightweight WKWebView interface.

## Install

Build and install locally:

```bash
git clone https://github.com/j1angyuxuan811-lab/clippy-macos-clipboard-manager.git
cd clippy-macos-clipboard-manager
./start.sh
```

`./start.sh` builds the Go backend, builds the Swift app, assembles `Clippy.app`, installs it to `/Applications`, stops older Clippy processes, launches the app, and checks the backend version.

If you only want to build the app bundle:

```bash
./build.sh
```

The built app is written to `.clippy-build/Clippy.app`.

## First Run

For direct paste and caret-aware placement, grant Accessibility permission:

System Settings -> Privacy & Security -> Accessibility -> enable Clippy

Without Accessibility permission, Clippy can still keep clipboard history and copy selected text, but direct paste and caret-based targeting may fall back to less precise behavior.

## Usage

| Action | Shortcut / Control |
|---|---|
| Open clipboard panel | `Command + Shift + V` |
| Open from menu bar | Click the Clippy menu bar icon |
| Move selection | `Up` / `Down` |
| Paste selected item | `Enter` |
| Close panel | `Esc` |
| Quick paste visible items | `Command + 1` through `Command + 9` |
| Paste as plain text | `Shift + Enter` |
| Search | Type in the search field |
| Pin / delete | Hover an item and use the item actions |
| Quit | Menu bar context menu -> `退出 Clippy` |

## Architecture

```text
Clippy.app
├── Swift / AppKit
│   ├── menu bar app
│   ├── NSPanel positioning
│   ├── global hotkey via HotKey
│   ├── Accessibility target capture
│   └── paste simulation
├── WKWebView UI
│   ├── clipboard list
│   ├── search and settings
│   └── keyboard bridge
└── Go backend
    ├── clipboard polling
    ├── SQLite persistence
    ├── local REST API
    └── image storage / cleanup
```

### Tech Stack

| Layer | Tech | Responsibility |
|---|---|---|
| Shell | Swift + AppKit | Menu bar app, panel lifecycle, hotkey, paste target restore |
| UI | WKWebView + HTML/CSS/JS | Clipboard list, search, settings, keyboard navigation |
| Backend | Go | Clipboard monitor, SQLite store, REST API |
| Storage | SQLite + local image files | History, pins, image paths, cleanup |

## Local API

The backend listens only on `127.0.0.1:5100`. Sensitive endpoints require the session token injected into the WebView as `X-Clippy-Token`.

Common endpoints:

| Method | Path | Description |
|---|---|---|
| GET | `/api/health` | Health and version |
| GET | `/api/clips` | List clipboard items |
| POST | `/api/clips` | Add a text item |
| POST | `/api/clips/{id}/copy` | Mark / return an item for paste |
| PUT | `/api/clips/{id}/pin` | Toggle pin |
| DELETE | `/api/clips/{id}` | Delete item |
| DELETE | `/api/clips/recent?minutes=...` | Delete recent items |
| GET / PUT | `/api/settings` | Read or update settings |
| POST | `/api/pause` | Pause recording |
| POST | `/api/resume` | Resume recording |

## Development

Requirements:

- macOS 13+
- Go 1.21+
- Xcode Command Line Tools
- Swift Package Manager

Useful commands:

```bash
# Go tests
cd go-backend
go test ./...

# Swift release build
cd swift-frontend
swift build -c release

# Contract tests
cd ..
for test in swift-frontend/Tests/*.sh; do sh "$test"; done

# Build, install, and launch
./start.sh
```

## Verification Status

The current local build has been verified with:

- `go test ./...`
- `swift build -c release`
- `swift-frontend/Tests/*.sh`
- `/api/health` returning `version: 1.2.1`
- single running Clippy app process and single backend process

## Notes

Clippy is still a personal project and local prototype. The most important remaining product decisions are packaging, update flow, paid distribution model, and whether to add account-based licensing.

## License

MIT
