import SwiftUI
import WebKit
import Cocoa
import Foundation
import Carbon.HIToolbox
import Darwin
import HotKey

// ── JS Bridge: handles clipboard operations from WebView ──
class ClippyBridge: NSObject, WKScriptMessageHandler {
    weak var appDelegate: AppDelegate?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let action = dict["action"] as? String else { return }

        switch action {
        case "copyImage":
            guard let path = dict["path"] as? String else {
                print("❌ copyImage: missing path")
                return
            }
            copyImageToClipboard(path: path)
        case "pasteText":
            guard let text = dict["text"] as? String else { return }
            pasteTextToActiveApp(text: text)
        case "hidePanel":
            DispatchQueue.main.async { [weak self] in
                self?.appDelegate?.hidePanel()
            }
        case "getStatus":
            // Return hotkey/accessibility status to WebView
            DispatchQueue.main.async { [weak self] in
                self?.sendStatusToWebView()
            }
        case "testHotkey":
            DispatchQueue.main.async { [weak self] in
                self?.appDelegate?.recordHotkeyTrigger(source: "test")
                self?.appDelegate?.showPanel(source: .typingContext)
                self?.sendStatusToWebView()
            }
        case "requestAccessibility":
            DispatchQueue.main.async { [weak self] in
                self?.appDelegate?.requestAccessibilityIfNeeded()
                self?.sendStatusToWebView()
            }
        case "keyboardEvent":
            if let key = dict["key"] as? String,
               let selected = dict["selected"] as? Int,
               let count = dict["count"] as? Int {
                appDelegate?.logStatus("WebView keyboard key=\(key) selected=\(selected) count=\(count)")
            }
        case "settingsChanged":
            // Immediate sync when WebView saves settings
            if let pd = dict["paste_directly"] as? Bool {
                DispatchQueue.main.async { [weak self] in
                    self?.appDelegate?.pasteDirectly = pd
                    print("⚡ paste_directly updated immediately: \(pd)")
                }
            }
            if let combo = dict["hotkey_combo"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.appDelegate?.applyHotkeyCombo(combo)
                    self?.sendStatusToWebView()
                }
            }
        default:
            break
        }
    }

    private func sendStatusToWebView() {
        guard let delegate = appDelegate, let webView = delegate.webView else { return }
        _ = delegate.refreshAccessibilityStatus()
        let statusJSON: [String: Any] = [
            "hotkey_registered": delegate.hotkeyRegistered,
            "hotkey_usable_now": delegate.hotkeyUsableNow,
            "hotkey_requires_accessibility": delegate.hotkeyRequiresAccessibility,
            "hotkey_method": delegate.hotkeyMethod,
            "hotkey_combo": delegate.hotkeyCombo,
            "hotkey_error": delegate.hotkeyError,
            "last_hotkey_at": delegate.lastHotkeyAt,
            "accessibility_granted": delegate.accessibilityGranted,
            "paste_directly": delegate.pasteDirectly
        ]
        if let data = try? JSONSerialization.data(withJSONObject: statusJSON),
           let json = String(data: data, encoding: .utf8) {
            let script = "window._clippyStatus = \(json); if (window._onClippyStatus) window._onClippyStatus(\(json));"
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    private func pasteTextToActiveApp(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Hide panel first, then paste
        DispatchQueue.main.async { [weak self] in
            self?.appDelegate?.hidePanel()

            let delegate = self?.appDelegate
            let wantsDirectPaste = delegate?.pasteDirectly == true
            let hasAccessibility = delegate?.refreshAccessibilityStatus() == true
            delegate?.logPasteDecision(kind: "text", wantsDirectPaste: wantsDirectPaste, hasAccessibility: hasAccessibility)

            // Only simulate Cmd+V if accessibility is currently granted AND paste_directly is enabled.
            if hasAccessibility && wantsDirectPaste {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.pasteToLastTargetApp()
                    self?.sendPasteResult(status: "direct_paste_triggered", message: "已触发直接粘贴")
                }
            } else if delegate?.insertTextIntoCapturedTextElement(text) == true {
                self?.sendPasteResult(status: "direct_insert_triggered", message: "已插入到当前输入框")
            } else if wantsDirectPaste {
                self?.sendPasteResult(status: "permission_blocked", message: "已复制；辅助功能权限未生效，需手动 ⌘V")
            } else {
                self?.sendPasteResult(status: "copied_manual_paste", message: "已复制，需手动 ⌘V")
            }
        }
    }

    private func copyImageToClipboard(path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let url = URL(fileURLWithPath: path)
        guard let image = NSImage(contentsOf: url) else {
            print("❌ Failed to load image: \(path)")
            return
        }

        pasteboard.writeObjects([image])
        print("📋 Image copied to clipboard: \(path)")

        DispatchQueue.main.async { [weak self] in
            self?.appDelegate?.hidePanel()
            let delegate = self?.appDelegate
            let wantsDirectPaste = delegate?.pasteDirectly == true
            let hasAccessibility = delegate?.refreshAccessibilityStatus() == true
            delegate?.logPasteDecision(kind: "image", wantsDirectPaste: wantsDirectPaste, hasAccessibility: hasAccessibility)

            if hasAccessibility && wantsDirectPaste {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.pasteToLastTargetApp()
                    self?.sendPasteResult(status: "direct_paste_triggered", message: "图片已复制，并触发直接粘贴")
                }
            } else if wantsDirectPaste {
                self?.sendPasteResult(status: "permission_blocked", message: "图片已复制；辅助功能权限未生效，需手动 ⌘V")
            } else {
                self?.sendPasteResult(status: "copied_manual_paste", message: "图片已复制，需手动 ⌘V")
            }
        }
    }

    private func sendPasteResult(status: String, message: String) {
        guard let webView = appDelegate?.webView else { return }
        let payload: [String: Any] = [
            "status": status,
            "message": message,
            "at": ISO8601DateFormatter().string(from: Date())
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            let script = "if (window._onPasteResult) window._onPasteResult(\(json));"
            DispatchQueue.main.async {
                webView.evaluateJavaScript(script, completionHandler: nil)
            }
        }
    }

    private func simulatePaste() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true) // V
        cmdDown?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        cmdUp?.flags = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
    }

    private func pasteToLastTargetApp() {
        appDelegate?.restorePasteTargetApp()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.appDelegate?.logStatus("System paste triggered via Cmd+V")
            self?.simulatePaste()
        }
    }
}

// ── App Delegate ──
class ClippyPanel: NSPanel {
    var preservesSourceInputFocus = false
    var acceptsKeyboardNavigationFocus = false

    override var canBecomeKey: Bool { acceptsKeyboardNavigationFocus || !preservesSourceInputFocus }
    override var canBecomeMain: Bool { acceptsKeyboardNavigationFocus || !preservesSourceInputFocus }
}

enum PanelPresentationSource {
    case statusItem
    case typingContext
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var statusMenu: NSMenu!
    var panel: NSPanel?
    var webView: WKWebView?
    var backendProcess: Process?
    var clickOutsideMonitor: Any?
    var clickLocalMonitor: Any?
    var typingKeyboardNavigationEnabled = false
    var typingKeyboardLocalMonitor: Any?
    var hotkeyGlobalMonitor: Any?
    var hotkeyLocalMonitor: Any?
    var hotkeyEventTap: CFMachPort?
    var hotkeyEventTapSource: CFRunLoopSource?
    var bridge: ClippyBridge!
    var accessibilityGranted = false
    var carbonHotkeyRef: EventHotKeyRef?
    var hotkeyRegistered = false
    var hotkeyUsableNow = false
    var hotkeyRequiresAccessibility = false
    var hotkeyMethod = "none" // "carbon", "nsevent", "hotkey-lib", "none"
    var hotkeyCombo = "⌘⇧V"
    var hotkeyError = ""
    var lastHotkeyAt = ""
    var lastPasteTargetApp: NSRunningApplication?
    var lastFocusedTextElement: AXUIElement?
    var lastSelectedTextRange: CFRange?
    var lastFocusedElementFrame: NSRect?
    var lastPanelAnchor: NSPoint?
    var lastPanelAvoidanceRect: NSRect?
    var lastPanelAvoidanceSource = "none"
    var pasteDirectly = true  // synced from backend settings
    var apiToken = ""         // per-session token read from data dir
    private var carbonEventHandlerInstalled = false
    private var carbonEventHandlerRef: EventHandlerRef?
    private var libraryHotKey: HotKey?

    private let backendURL: URL = {
        let appBundleURL = Bundle.main.bundleURL
        return appBundleURL.appendingPathComponent("Contents/Resources/go-backend/clippy-server")
    }()

    private var uiDir: URL {
        if let resourcesPath = Bundle.main.resourcePath {
            return URL(fileURLWithPath: resourcesPath).appendingPathComponent("ui-prototype")
        }
        return URL(fileURLWithPath: "/Users/qq/workspace/clippy-v2/ui-prototype")
    }

    private var appSupportDir: String {
        let dir = NSHomeDirectory() + "/Library/Application Support/Clippy"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }

    private var expectedBackendVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    // ── Launch ──
    func applicationDidFinishLaunching(_ notification: Notification) {
        startBackend()
        loadAPIToken()
        setupStatusItem()
        setupPanel()
        registerHotkeyWithLibrary()  // Use HotKey library (like Maccy)
        checkAccessibilityForPaste() // Paste simulation: needs accessibility
        syncSettingsFromBackend()     // Load paste_directly setting
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopBackend()
        unregisterCarbonHotkey()
        removeCarbonEventHandler()
        removeCGEventTapHotkey()
        cleanupMonitors()
    }

    // ── HotKey Library (like Maccy) ──
    func registerHotkeyWithLibrary() {
        libraryHotKey = nil // Release previous

        let parsed = parseHotkeyComboToKeyCombo(hotkeyCombo)
        guard let keyCombo = parsed else {
            hotkeyRegistered = false
            hotkeyUsableNow = false
            hotkeyMethod = "none"
            hotkeyError = "无法解析快捷键组合: \(hotkeyCombo)"
            logStatus("HotKey lib: failed to parse combo \(hotkeyCombo)")
            // Fallback
            registerCarbonHotkey()
            return
        }

        let hotKey = HotKey(keyCombo: keyCombo)
        hotKey.keyDownHandler = { [weak self] in
            self?.recordHotkeyTrigger(source: "hotkey-lib")
            self?.togglePanel(source: .typingContext)
        }
        libraryHotKey = hotKey

        hotkeyRegistered = true
        hotkeyUsableNow = true
        hotkeyRequiresAccessibility = false
        hotkeyMethod = "hotkey-lib"
        hotkeyError = ""
        logStatus("HotKey library registered (\(hotkeyCombo))")
    }

    private func parseHotkeyComboToKeyCombo(_ combo: String) -> KeyCombo? {
        var modifiers: NSEvent.ModifierFlags = []
        if combo.contains("⌘") { modifiers.insert(.command) }
        if combo.contains("⇧") { modifiers.insert(.shift) }
        if combo.contains("⌥") { modifiers.insert(.option) }
        if combo.contains("⌃") { modifiers.insert(.control) }

        let keyLetter = combo.uppercased().reversed().first { $0 >= "A" && $0 <= "Z" }.map(String.init) ?? "V"
        guard let key = Key(string: keyLetter.lowercased()) else { return nil }
        return KeyCombo(key: key, modifiers: modifiers)
    }

    // ── Carbon Global Hotkey (no accessibility needed) ──
    func registerCarbonHotkey() {
        guard installCarbonEventHandler() else {
            setupNSEventHotkey()
            return
        }

        let hotkeyID = EventHotKeyID(signature: OSType(0x434C5059), id: 1) // "CLPY"
        var hotKeyRef: EventHotKeyRef?
        let parsed = parseHotkeyCombo(hotkeyCombo)

        let status = RegisterEventHotKey(parsed.keyCode, parsed.modifiers, hotkeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)

        if status == noErr {
            carbonHotkeyRef = hotKeyRef
            hotkeyRegistered = true
            hotkeyUsableNow = true
            hotkeyRequiresAccessibility = false
            hotkeyMethod = "carbon"
            hotkeyError = ""
            logStatus("Carbon hotkey registered (\(hotkeyCombo))")
        } else {
            hotkeyRegistered = false
            hotkeyUsableNow = false
            hotkeyRequiresAccessibility = true
            let carbonError = status == eventHotKeyExistsErr ? "快捷键可能已被其他应用占用" : "Carbon 注册失败（\(status)）"
            hotkeyError = "\(carbonError)；已启用 NSEvent 兜底，需辅助功能权限"
            logStatus("Carbon hotkey failed (\(status)); enabling NSEvent fallback")
            setupNSEventHotkey()
        }
    }

    private func installCarbonEventHandler() -> Bool {
        if carbonEventHandlerInstalled {
            return true
        }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            guard let event = event else { return OSStatus(eventNotHandledErr) }
            var hotkeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
            if hotkeyID.id == 1 {
                DispatchQueue.main.async {
                    if let delegate = NSApp.delegate as? AppDelegate {
                        delegate.recordHotkeyTrigger(source: "global")
                        delegate.togglePanel(source: .typingContext)
                    }
                }
            }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        if status != noErr {
            hotkeyRegistered = false
            hotkeyUsableNow = false
            hotkeyRequiresAccessibility = true
            hotkeyMethod = "none"
            hotkeyError = "Carbon handler 安装失败（\(status)）；已启用 NSEvent 兜底，需辅助功能权限"
            logStatus("Carbon handler install failed (\(status)); enabling NSEvent fallback")
            return false
        }
        carbonEventHandlerRef = handlerRef
        carbonEventHandlerInstalled = true
        logStatus("Carbon event handler installed on dispatcher target")
        return true
    }

    func unregisterCarbonHotkey() {
        if let ref = carbonHotkeyRef {
            UnregisterEventHotKey(ref)
            carbonHotkeyRef = nil
        }
        hotkeyRegistered = false
        hotkeyUsableNow = false
        hotkeyRequiresAccessibility = false
        hotkeyMethod = "none"
    }

    private func removeCarbonEventHandler() {
        if let ref = carbonEventHandlerRef {
            RemoveEventHandler(ref)
            carbonEventHandlerRef = nil
        }
        carbonEventHandlerInstalled = false
    }

    func applyHotkeyCombo(_ combo: String) {
        hotkeyCombo = combo.isEmpty ? "⌘⇧V" : combo
        registerHotkeyWithLibrary()
    }

    func recordHotkeyTrigger(source: String) {
        lastHotkeyAt = ISO8601DateFormatter().string(from: Date())
        print("⌨️ Hotkey triggered via \(source) at \(lastHotkeyAt)")
        if let webView = webView {
            let script = "if (window._onHotkeyTriggered) window._onHotkeyTriggered('\(lastHotkeyAt)');"
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    private func parseHotkeyCombo(_ combo: String) -> (keyCode: UInt32, modifiers: UInt32) {
        var modifiers: UInt32 = 0
        if combo.contains("⌘") { modifiers |= UInt32(cmdKey) }
        if combo.contains("⇧") { modifiers |= UInt32(shiftKey) }
        if combo.contains("⌥") { modifiers |= UInt32(optionKey) }
        if combo.contains("⌃") { modifiers |= UInt32(controlKey) }
        let keyLetter = combo.uppercased().reversed().first { $0 >= "A" && $0 <= "Z" }.map(String.init) ?? "V"
        let keyMap: [String: Int] = [
            "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D,
            "E": kVK_ANSI_E, "F": kVK_ANSI_F, "G": kVK_ANSI_G, "H": kVK_ANSI_H,
            "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
            "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P,
            "Q": kVK_ANSI_Q, "R": kVK_ANSI_R, "S": kVK_ANSI_S, "T": kVK_ANSI_T,
            "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
            "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z
        ]
        let key = keyMap[keyLetter] ?? kVK_ANSI_V
        return (UInt32(key), modifiers == 0 ? UInt32(cmdKey | shiftKey) : modifiers)
    }

    // Fallback: NSEvent monitors (requires accessibility)
    func setupNSEventHotkey() {
        if hotkeyGlobalMonitor != nil || hotkeyLocalMonitor != nil {
            if !hotkeyUsableNow {
                hotkeyRegistered = true
                hotkeyUsableNow = accessibilityGranted
                hotkeyRequiresAccessibility = true
                hotkeyMethod = "nsevent"
            }
            return
        }
        hotkeyGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHotkey(event)
        }
        hotkeyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHotkey(event)
            return event
        }
        if !hotkeyRegistered {
            hotkeyRegistered = true
            hotkeyUsableNow = accessibilityGranted
            hotkeyRequiresAccessibility = true
            hotkeyMethod = "nsevent"
        }
        logStatus("NSEvent hotkey monitor registered (\(hotkeyCombo)); accessibility required for global events")
    }

    // Reliable fallback: CGEventTap global monitor (requires accessibility).
    func setupCGEventTapHotkey() {
        guard hotkeyEventTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let delegate = NSApp.delegate as? AppDelegate, let tap = delegate.hotkeyEventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                        delegate.logStatus("CGEventTap hotkey monitor re-enabled")
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown, let delegate = NSApp.delegate as? AppDelegate else {
                    return Unmanaged.passUnretained(event)
                }
                if delegate.handleTypingKeyboardNavigation(event) {
                    return nil
                }
                if delegate.matchesHotkey(event: event) {
                    DispatchQueue.main.async {
                        delegate.recordHotkeyTrigger(source: "cgeventtap")
                        delegate.togglePanel(source: .typingContext)
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            logStatus("CGEventTap hotkey monitor failed; accessibility may still be missing")
            return
        }

        hotkeyEventTap = tap
        hotkeyEventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = hotkeyEventTapSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        hotkeyRegistered = true
        hotkeyUsableNow = true
        hotkeyRequiresAccessibility = true
        hotkeyMethod = "cgeventtap"
        hotkeyError = ""
        logStatus("CGEventTap hotkey monitor registered (\(hotkeyCombo))")
    }

    func removeCGEventTapHotkey() {
        if let source = hotkeyEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            hotkeyEventTapSource = nil
        }
        if let tap = hotkeyEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            hotkeyEventTap = nil
        }
    }

    // ── Accessibility (only for paste simulation) ──
    func checkAccessibilityForPaste() {
        if refreshAccessibilityStatus() {
            logStatus("Accessibility granted; paste simulation and NSEvent fallback enabled")
            return
        }

        // Don't block startup with alert. Just note the status.
        // When user first tries to paste, show onboarding if needed.
        logStatus("Accessibility not granted; direct paste and NSEvent fallback may not work")

        // Silently poll in background
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] timer in
            if self?.refreshAccessibilityStatus() == true {
                timer.invalidate()
                self?.logStatus("Accessibility permission granted")
            }
        }
    }

    @discardableResult
    func refreshAccessibilityStatus() -> Bool {
        let trusted = AXIsProcessTrusted()
        accessibilityGranted = trusted
        if trusted {
            setupCGEventTapHotkey()
        }
        return trusted
    }

    func logStatus(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        print(line, terminator: "")
        let path = appSupportDir + "/frontend.log"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path),
               let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    func requestAccessibilityIfNeeded() {
        guard !refreshAccessibilityStatus() else { return }

        let alert = NSAlert()
        alert.messageText = "需要辅助功能权限"
        alert.informativeText = "Clippy 需要辅助功能权限才能直接粘贴到当前应用。\n\n不授权也可以使用，但需要手动 ⌘V 粘贴。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "前往设置")
        alert.addButton(withTitle: "暂不需要")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    // ── Sync Settings from Backend ──
    func syncSettingsFromBackend() {
        // Wait a moment for backend to start
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.fetchSettings()
        }
        // Re-sync periodically
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.fetchSettings()
        }
    }

    private func fetchSettings() {
        guard let url = URL(string: "http://127.0.0.1:5100/api/settings") else { return }
        var request = URLRequest(url: url)
        request.setValue(apiToken, forHTTPHeaderField: "X-Clippy-Token")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let data = data, error == nil else { return }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                DispatchQueue.main.async {
                    if let pd = json["paste_directly"] as? Bool {
                        self?.pasteDirectly = pd
                    }
                    if let combo = json["hotkey_combo"] as? String, combo != self?.hotkeyCombo {
                        self?.applyHotkeyCombo(combo)
                    }
                }
            }
        }.resume()
    }

    // ── Load API Token ──
    private func loadAPIToken() {
        let tokenPath = appSupportDir + "/api_token"
        // Retry a few times since backend may still be starting
        for attempt in 0..<10 {
            if let token = try? String(contentsOfFile: tokenPath, encoding: .utf8) {
                apiToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
                print("🔑 API token loaded (attempt \(attempt + 1))")
                return
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        print("⚠️ Could not load API token — API calls will be unauthorized")
    }

    // ── Backend (Single Instance) ──
    func startBackend() {
        if let version = backendHealthVersion() {
            if version == expectedBackendVersion {
                print("✅ Backend already running on port 5100, reusing")
                return
            }
            print("⚠️ Backend version \(version) is stale; stopping it before launch")
            stopBackendFromPIDFile()
            Thread.sleep(forTimeInterval: 0.5)
        }

        let process = Process()
        process.executableURL = backendURL

        let imagesDir = appSupportDir + "/images"
        try? FileManager.default.createDirectory(atPath: imagesDir, withIntermediateDirectories: true, attributes: nil)

        process.arguments = [
            "-port", "5100",
            "-data", appSupportDir,
            "-images", imagesDir,
            "-static", uiDir.path
        ]

        let logDir = FileManager.default.temporaryDirectory
        let stdoutLog = logDir.appendingPathComponent("clippy-backend-stdout.log")
        let stderrLog = logDir.appendingPathComponent("clippy-backend-stderr.log")
        FileManager.default.createFile(atPath: stdoutLog.path, contents: nil)
        FileManager.default.createFile(atPath: stderrLog.path, contents: nil)
        process.standardOutput = try? FileHandle(forWritingTo: stdoutLog)
        process.standardError = try? FileHandle(forWritingTo: stderrLog)

        do {
            try process.run()
            backendProcess = process
            print("🚀 Backend started (PID \(process.processIdentifier))")
        } catch {
            print("❌ Backend failed: \(error)")
        }
    }

    private func backendHealthVersion() -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        var version: String?

        guard let url = URL(string: "http://127.0.0.1:5100/api/health") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data = data,
               let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                version = json["version"] as? String
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 1.5)
        return version
    }

    private func stopBackendFromPIDFile() {
        let pidPath = appSupportDir + "/clippy.pid"
        guard let raw = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return }
        if kill(pid, SIGTERM) == 0 {
            print("🛑 Stopped stale backend PID \(pid)")
        }
    }

    func stopBackend() {
        backendProcess?.terminate()
        backendProcess = nil
    }

    // ── Status Bar ──
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusMenu = NSMenu()
        let quitItem = NSMenuItem(title: "退出 Clippy", action: #selector(quitClippy), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clippy")
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc func statusItemClicked() {
        guard let event = NSApp.currentEvent else {
            togglePanel(source: .statusItem)
            return
        }

        if event.type == .rightMouseUp {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }

        if event.clickCount > 1 {
            showPanel(source: .statusItem)
            return
        }

        togglePanel(source: .statusItem)
    }

    @objc func quitClippy() {
        NSApp.terminate(nil)
    }

    // ── Panel ──
    func setupPanel() {
        let panelWidth: CGFloat = 400
        let panelHeight: CGFloat = 360

        panel = ClippyPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        panel?.titlebarAppearsTransparent = true
        panel?.titleVisibility = .hidden
        panel?.isMovableByWindowBackground = true
        panel?.level = .popUpMenu
        panel?.backgroundColor = .clear
        panel?.hasShadow = true
        panel?.isOpaque = false
        panel?.isReleasedWhenClosed = false
        panel?.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel?.animationBehavior = .utilityWindow
        panel?.hidesOnDeactivate = false
        panel?.becomesKeyOnlyIfNeeded = false

        panel?.contentView?.wantsLayer = true
        panel?.contentView?.layer?.cornerRadius = 22
        panel?.contentView?.layer?.masksToBounds = true
        panel?.contentView?.layer?.borderWidth = 0.75
        panel?.contentView?.layer?.borderColor = NSColor.white.withAlphaComponent(0.52).cgColor
        panel?.contentView?.layer?.backgroundColor = NSColor.clear.cgColor

        // Liquid Glass: use the system menu material as the real blur layer.
        let visualEffect = NSVisualEffectView(frame: panel!.contentView!.bounds)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 22
        visualEffect.layer?.masksToBounds = true
        visualEffect.material = .popover
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.appearance = NSAppearance(named: .aqua)
        panel?.contentView?.addSubview(visualEffect)

        // Content
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        bridge = ClippyBridge()
        bridge.appDelegate = self
        config.userContentController.add(bridge, name: "ClippyBridge")

        // Inject before the first document load so initial fetch() calls include auth.
        let tokenScript = WKUserScript(
            source: "window.__CLIPPY_TOKEN__ = '\(apiToken)';",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(tokenScript)

        let webView = WKWebView(frame: panel!.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.allowsBackForwardNavigationGestures = false
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.setValue(false, forKey: "drawsBackground")

        panel?.contentView?.addSubview(webView)
        self.webView = webView

        let htmlFile = uiDir.appendingPathComponent("index.html")
        webView.loadFileURL(htmlFile, allowingReadAccessTo: uiDir)
    }

    // ── Global Hotkey handler (for NSEvent fallback) ──
    private func handleHotkey(_ event: NSEvent) {
        let parsed = parseHotkeyCombo(hotkeyCombo)
        let flags = event.modifierFlags
        let shiftOk = (parsed.modifiers & UInt32(shiftKey)) == 0 || flags.contains(.shift)
        let cmdOk = (parsed.modifiers & UInt32(cmdKey)) == 0 || flags.contains(.command)
        let optionOk = (parsed.modifiers & UInt32(optionKey)) == 0 || flags.contains(.option)
        let controlOk = (parsed.modifiers & UInt32(controlKey)) == 0 || flags.contains(.control)
        let keyOk = UInt32(event.keyCode) == parsed.keyCode

        if shiftOk && cmdOk && optionOk && controlOk && keyOk {
            DispatchQueue.main.async { [weak self] in
                self?.recordHotkeyTrigger(source: "local")
                self?.togglePanel(source: .typingContext)
            }
        }
    }

    // ── Toggle ──
    func togglePanel(source: PanelPresentationSource) {
        guard let panel = panel else { return }
        if panel.isVisible && panelIsOnScreen(panel) {
            hidePanel()
        } else {
            showPanel(source: source)
        }
    }

    private func panelIsOnScreen(_ panel: NSPanel) -> Bool {
        let windowNumber = panel.windowNumber
        guard windowNumber > 0 else { return false }

        let options = CGWindowListOption(arrayLiteral: .optionIncludingWindow)
        guard let windows = CGWindowListCopyWindowInfo(options, CGWindowID(windowNumber)) as? [[String: Any]],
              let window = windows.first else {
            return false
        }

        if let isOnScreen = window[kCGWindowIsOnscreen as String] as? Bool {
            return isOnScreen
        }
        if let isOnScreen = window[kCGWindowIsOnscreen as String] as? NSNumber {
            return isOnScreen.boolValue
        }
        return false
    }

    func showPanel(source: PanelPresentationSource) {
        guard let panel = panel else { return }
        if panel.isVisible && !panelIsOnScreen(panel) {
            panel.orderOut(nil)
        }

        prepareForPanelPresentation(source: source)
        configurePanelFocus(panel, source: source)
        positionPanel(panel, source: source)

        presentPanel(panel, source: source)
        setupTypingKeyboardMonitor(source: source)
        logPanelShown(panel, source: source)

        refreshPanelContent(source: source)
        syncPanelInputFocus(source: source)

        // Listen for clicks outside panel
        setupClickOutsideMonitors()
    }

    private func syncPanelInputFocus(source: PanelPresentationSource) {
        focusPanelForKeyboardNavigation(source: source)
    }

    private func refreshPanelContent(source: PanelPresentationSource) {
        guard let webView = webView else { return }

        let script = "if (typeof window.fetchClips === 'function') { window.fetchClips(); true; } else { false; }"
        webView.evaluateJavaScript(script) { [weak webView] result, _ in
            if result as? Bool != true {
                webView?.reload()
            }
        }
    }

    private func prepareForPanelPresentation(source: PanelPresentationSource) {
        switch source {
        case .typingContext:
            capturePasteTargetApp()
            captureFocusedTextElement()
        case .statusItem:
            break
        }
    }

    private func configurePanelFocus(_ panel: NSPanel, source: PanelPresentationSource) {
        guard let clippyPanel = panel as? ClippyPanel else { return }
        switch source {
        case .typingContext:
            clippyPanel.preservesSourceInputFocus = true
            clippyPanel.acceptsKeyboardNavigationFocus = true
        case .statusItem:
            clippyPanel.preservesSourceInputFocus = false
            clippyPanel.acceptsKeyboardNavigationFocus = true
        }
    }

    private func presentPanel(_ panel: NSPanel, source: PanelPresentationSource) {
        switch source {
        case .typingContext:
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
        case .statusItem:
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
        }
    }

    private func focusPanelForKeyboardNavigation(source: PanelPresentationSource) {
        guard source == .typingContext,
              let panel = panel,
              let webView = webView else { return }

        panel.makeFirstResponder(webView)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self, weak panel, weak webView] in
            guard let self = self,
                  let panel = panel,
                  let webView = webView,
                  self.typingKeyboardNavigationEnabled,
                  panel.isVisible else { return }
            panel.makeFirstResponder(webView)
            webView.evaluateJavaScript("window.clippyFocusKeyboardSurface && window.clippyFocusKeyboardSurface();", completionHandler: nil)
            self.logStatus("Typing keyboard WebView focused key=\(panel.isKeyWindow) firstResponder=\(String(describing: panel.firstResponder))")
        }
    }

    private func logPanelShown(_ panel: NSPanel, source: PanelPresentationSource) {
        let preservesFocus = (panel as? ClippyPanel)?.preservesSourceInputFocus == true
        let anchor = lastPanelAnchor.map { "\($0)" } ?? "none"
        let focusedFrame = lastFocusedElementFrame.map { "\($0)" } ?? "none"
        let avoidRect = lastPanelAvoidanceRect.map { "\($0)" } ?? "none"
        logStatus("Panel shown source=\(source) preserveFocus=\(preservesFocus) key=\(panel.isKeyWindow) main=\(panel.isMainWindow) anchor=\(anchor) focusedFrame=\(focusedFrame) avoidance=\(lastPanelAvoidanceSource) avoidRect=\(avoidRect) frame=\(panel.frame)")
    }

    private func positionPanel(_ panel: NSPanel, source: PanelPresentationSource) {
        let anchor: NSPoint?
        switch source {
        case .typingContext:
            anchor = resolveTypingAnchor() ?? resolveMouseAnchor() ?? resolveStatusItemAnchor()
        case .statusItem:
            anchor = resolveStatusItemAnchor()
        }

        guard let anchor = anchor else { return }
        lastPanelAnchor = anchor
        let avoidRect = panelAvoidanceRect(anchor: anchor, panelSize: panel.frame.size, source: source)
        let origin = preferredPanelOrigin(anchor: anchor, panelSize: panel.frame.size, avoidRect: avoidRect)
        panel.setFrameOrigin(origin)
    }

    private func panelAvoidanceRect(anchor: NSPoint, panelSize: NSSize, source: PanelPresentationSource) -> NSRect? {
        lastPanelAvoidanceRect = nil
        lastPanelAvoidanceSource = "none"

        guard source == .typingContext,
              let screen = screenContainingAppKitPoint(anchor) ?? NSScreen.main else {
            return nil
        }

        let visibleFrame = screen.visibleFrame
        let inferred = inferredCaretAvoidanceRect(anchor: anchor, panelSize: panelSize, visibleFrame: visibleFrame)
        if let focusedFrame = lastFocusedElementFrame,
           isUsefulAvoidanceRect(focusedFrame, visibleFrame: visibleFrame, anchor: anchor) {
            let avoidRect = inputAvoidanceRect(focusedFrame: focusedFrame, inferredRect: inferred, visibleFrame: visibleFrame)
            lastPanelAvoidanceRect = avoidRect
            lastPanelAvoidanceSource = "focusedElementFrame"
            return avoidRect
        }

        lastPanelAvoidanceRect = inferred
        lastPanelAvoidanceSource = "caretBand"
        return inferred
    }

    private func resolveTypingAnchor() -> NSPoint? {
        guard refreshAccessibilityStatus(),
              let focusedElement = focusedAccessibilityElement() else {
            return nil
        }

        if let selectedRange = accessibilitySelectedTextRange(element: focusedElement),
           let bounds = accessibilityBounds(for: selectedRange, element: focusedElement) {
            if let anchor = reliableTypingAnchor(appKitAnchorPoint(fromAccessibilityBounds: bounds)) {
                return anchor
            }
        }

        if let frameAnchor = anchorFromFocusedElementFrame(element: focusedElement) {
            return frameAnchor
        }

        return reliableTypingAnchor(accessibilityPosition(element: focusedElement))
    }

    func capturePasteTargetApp() {
        let currentApp = NSWorkspace.shared.frontmostApplication
        if currentApp?.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastPasteTargetApp = currentApp
        }
    }

    private func captureFocusedTextElement() {
        guard refreshAccessibilityStatus(),
              let focusedElement = focusedAccessibilityElement() else {
            lastFocusedTextElement = nil
            lastSelectedTextRange = nil
            lastFocusedElementFrame = nil
            return
        }
        lastFocusedTextElement = focusedElement
        lastSelectedTextRange = accessibilitySelectedTextRange(element: focusedElement)
        lastFocusedElementFrame = focusedElementFrame(element: focusedElement)
    }

    func restorePasteTargetApp() {
        guard let app = lastPasteTargetApp,
              !app.isTerminated else {
            return
        }
        app.activate(options: [.activateIgnoringOtherApps])
    }

    func insertTextIntoCapturedTextElement(_ text: String) -> Bool {
        guard refreshAccessibilityStatus(),
              let element = lastFocusedTextElement else {
            logStatus("Direct insert skipped accessibility=\(accessibilityGranted) capturedElement=\(lastFocusedTextElement != nil)")
            return false
        }

        restorePasteTargetApp()

        if let range = lastSelectedTextRange,
           replaceSelectedText(text, in: element, range: range) {
            logStatus("Direct insert succeeded via AXSelectedTextRange")
            return true
        }

        if setFocusedElementValue(text, element: element) {
            logStatus("Direct insert succeeded via AXValue")
            return true
        }

        logStatus("Direct insert failed; falling back to paste simulation")
        return false
    }

    func logPasteDecision(kind: String, wantsDirectPaste: Bool, hasAccessibility: Bool) {
        let target = lastPasteTargetApp?.localizedName ?? "none"
        logStatus("Paste decision kind=\(kind) direct=\(wantsDirectPaste) accessibility=\(hasAccessibility) target=\(target)")
    }

    private func focusedAccessibilityElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success else {
            return nil
        }
        return (focused as! AXUIElement)
    }

    private func accessibilitySelectedTextRange(element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }

        let rangeValue = axValue as! AXValue
        var range = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange,
              AXValueGetValue(rangeValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    private func replaceSelectedText(_ text: String, in element: AXUIElement, range: CFRange) -> Bool {
        guard var value = accessibilityStringValue(element: element) else {
            return false
        }

        let nsValue = value as NSString
        guard range.location >= 0,
              range.location <= nsValue.length,
              range.length >= 0,
              range.location + range.length <= nsValue.length else {
            return false
        }

        value = nsValue.replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef) == .success else {
            return false
        }

        var newRange = CFRange(location: range.location + (text as NSString).length, length: 0)
        if let rangeValue = AXValueCreate(.cfRange, &newRange) {
            _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
        }
        return true
    }

    private func setFocusedElementValue(_ text: String, element: AXUIElement) -> Bool {
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef) == .success else {
            return false
        }

        var newRange = CFRange(location: (text as NSString).length, length: 0)
        if let rangeValue = AXValueCreate(.cfRange, &newRange) {
            _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
        }
        return true
    }

    private func accessibilityStringValue(element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func accessibilityBounds(for range: CFRange, element: AXUIElement) -> CGRect? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        ) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }

        let rectValue = axValue as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(rectValue) == .cgRect,
              AXValueGetValue(rectValue, .cgRect, &rect),
              rect != .zero else {
            return nil
        }
        return rect
    }

    private func accessibilityPosition(element: AXUIElement) -> NSPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }

        let pointValue = axValue as! AXValue
        var point = CGPoint.zero
        guard AXValueGetType(pointValue) == .cgPoint,
              AXValueGetValue(pointValue, .cgPoint, &point) else {
            return nil
        }
        return appKitAnchorPoint(fromAccessibilityPoint: point)
    }

    private func focusedElementFrame(element: AXUIElement) -> NSRect? {
        if let frame = accessibilityFrame(element: element) {
            return frame
        }

        var current = element
        for _ in 0..<3 {
            guard let parent = accessibilityParent(element: current) else {
                return nil
            }
            if let frame = accessibilityFrame(element: parent) {
                return frame
            }
            current = parent
        }

        return nil
    }

    private func anchorFromFocusedElementFrame(element: AXUIElement) -> NSPoint? {
        guard let frame = focusedElementFrame(element: element) else {
            return nil
        }
        let anchor = NSPoint(x: frame.midX, y: frame.maxY)
        return reliableTypingAnchor(anchor)
    }

    private func accessibilityParent(element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let parent = value else {
            return nil
        }
        return (parent as! AXUIElement)
    }

    private func accessibilityFrame(element: AXUIElement) -> NSRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let axPosition = positionValue,
              let axSize = sizeValue,
              CFGetTypeID(axPosition) == AXValueGetTypeID(),
              CFGetTypeID(axSize) == AXValueGetTypeID() else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(axPosition as! AXValue) == .cgPoint,
              AXValueGetType(axSize as! AXValue) == .cgSize,
              AXValueGetValue(axPosition as! AXValue, .cgPoint, &point),
              AXValueGetValue(axSize as! AXValue, .cgSize, &size),
              size.width > 0,
              size.height > 0 else {
            return nil
        }

        let accessibilityRect = CGRect(origin: point, size: size)
        return appKitRect(fromAccessibilityRect: accessibilityRect)
    }

    private func resolveMouseAnchor() -> NSPoint? {
        NSEvent.mouseLocation
    }

    private func resolveStatusItemAnchor() -> NSPoint? {
        guard let button = statusItem.button,
              let window = button.window else {
            return nil
        }
        let frame = window.convertToScreen(button.frame)
        return NSPoint(x: frame.midX, y: frame.minY)
    }

    private func appKitAnchorPoint(fromAccessibilityBounds rect: CGRect) -> NSPoint? {
        guard let screen = screenContainingAccessibilityRect(rect) else { return nil }
        return NSPoint(x: rect.minX, y: screen.frame.maxY - rect.maxY)
    }

    private func appKitAnchorPoint(fromAccessibilityPoint point: CGPoint) -> NSPoint? {
        guard let screen = screenContainingAccessibilityPoint(point) else { return nil }
        return NSPoint(x: point.x, y: screen.frame.maxY - point.y)
    }

    private func appKitRect(fromAccessibilityRect rect: CGRect) -> NSRect? {
        guard let screen = screenContainingAccessibilityRect(rect) else { return nil }
        return NSRect(
            x: rect.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func preferredPanelOrigin(anchor: NSPoint, panelSize: NSSize, avoidRect: NSRect?) -> NSPoint {
        let offset: CGFloat = 12
        let screen = screenContainingAppKitPoint(anchor) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            return anchor
        }

        let x = min(
            max(anchor.x - panelSize.width / 2, visibleFrame.minX + 8),
            visibleFrame.maxX - panelSize.width - 8
        )
        let originBelowCaret = NSPoint(x: x, y: anchor.y - panelSize.height - offset)
        let originAboveCaret = NSPoint(x: x, y: anchor.y + offset)
        let originAboveAvoidRect = avoidRect.map { rect in
            NSPoint(x: x, y: rect.maxY + offset)
        }
        let originBelowAvoidRect = avoidRect.map { rect in
            NSPoint(x: x, y: rect.minY - panelSize.height - offset)
        }
        let originRightOfAvoidRect = avoidRect.map { rect in
            NSPoint(x: rect.maxX + offset, y: clamp(anchor.y - panelSize.height / 2, min: visibleFrame.minY + 8, max: visibleFrame.maxY - panelSize.height - 8))
        }
        let originLeftOfAvoidRect = avoidRect.map { rect in
            NSPoint(x: rect.minX - panelSize.width - offset, y: clamp(anchor.y - panelSize.height / 2, min: visibleFrame.minY + 8, max: visibleFrame.maxY - panelSize.height - 8))
        }

        if let originAboveAvoidRect,
           fits(originAboveAvoidRect, panelSize: panelSize, visibleFrame: visibleFrame, avoidRect: avoidRect) {
            return originAboveAvoidRect
        }
        if let originBelowAvoidRect,
           fits(originBelowAvoidRect, panelSize: panelSize, visibleFrame: visibleFrame, avoidRect: avoidRect) {
            return originBelowAvoidRect
        }
        if let originRightOfAvoidRect,
           fits(originRightOfAvoidRect, panelSize: panelSize, visibleFrame: visibleFrame, avoidRect: avoidRect) {
            return originRightOfAvoidRect
        }
        if let originLeftOfAvoidRect,
           fits(originLeftOfAvoidRect, panelSize: panelSize, visibleFrame: visibleFrame, avoidRect: avoidRect) {
            return originLeftOfAvoidRect
        }

        if fits(originBelowCaret, panelSize: panelSize, visibleFrame: visibleFrame, avoidRect: avoidRect) {
            return originBelowCaret
        }
        if fits(originAboveCaret, panelSize: panelSize, visibleFrame: visibleFrame, avoidRect: avoidRect) {
            return originAboveCaret
        }

        let y = clamp(originBelowCaret.y, min: visibleFrame.minY + 8, max: visibleFrame.maxY - panelSize.height - 8)
        return NSPoint(x: x, y: y)
    }

    private func inferredCaretAvoidanceRect(anchor: NSPoint, panelSize: NSSize, visibleFrame: NSRect) -> NSRect {
        let width = min(max(panelSize.width + 160, 560), visibleFrame.width - 16)
        let height: CGFloat = 132
        let x = clamp(anchor.x - width / 2, min: visibleFrame.minX + 8, max: visibleFrame.maxX - width - 8)
        let y = clamp(anchor.y - 28, min: visibleFrame.minY + 8, max: visibleFrame.maxY - height - 8)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func inputAvoidanceRect(focusedFrame: NSRect, inferredRect: NSRect, visibleFrame: NSRect) -> NSRect {
        let focused = focusedFrame.intersection(visibleFrame)
        guard !focused.isNull else { return inferredRect }

        if focused.height < 96 || focused.width < 180 {
            return focused.union(inferredRect).intersection(visibleFrame)
        }
        return focused
    }

    private func isUsefulAvoidanceRect(_ rect: NSRect, visibleFrame: NSRect, anchor: NSPoint) -> Bool {
        guard rect.width >= 24,
              rect.height >= 16,
              rect.intersects(visibleFrame) else {
            return false
        }
        return rect.insetBy(dx: -24, dy: -24).contains(anchor)
    }

    private func fits(_ origin: NSPoint, panelSize: NSSize, visibleFrame: NSRect, avoidRect: NSRect?) -> Bool {
        let panelRect = NSRect(origin: origin, size: panelSize)
        return origin.x >= visibleFrame.minX + 8 &&
        origin.y >= visibleFrame.minY + 8 &&
        origin.x + panelSize.width <= visibleFrame.maxX - 8 &&
        origin.y + panelSize.height <= visibleFrame.maxY - 8 &&
        doesNotIntersect(panelRect, avoidRect: avoidRect)
    }

    private func doesNotIntersect(_ panelRect: NSRect, avoidRect: NSRect?) -> Bool {
        guard let avoidRect = avoidRect?.insetBy(dx: -12, dy: -12) else {
            return true
        }
        return !panelRect.intersects(avoidRect)
    }

    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        guard minValue <= maxValue else { return minValue }
        return min(max(value, minValue), maxValue)
    }

    private func reliableTypingAnchor(_ anchor: NSPoint?) -> NSPoint? {
        guard let anchor = anchor,
              let screen = screenContainingAppKitPoint(anchor) ?? NSScreen.main else {
            return nil
        }
        let frame = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        guard frame.contains(anchor) else {
            logStatus("Rejected unreliable typing anchor=\(anchor) visibleFrame=\(screen.visibleFrame)")
            return nil
        }
        return anchor
    }

    private func screenContainingAppKitPoint(_ point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func screenContainingAccessibilityPoint(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            point.x >= screen.frame.minX &&
            point.x <= screen.frame.maxX &&
            point.y >= 0 &&
            point.y <= screen.frame.height
        }
    }

    private func screenContainingAccessibilityRect(_ rect: CGRect) -> NSScreen? {
        NSScreen.screens.first { screen in
            rect.midX >= screen.frame.minX &&
            rect.midX <= screen.frame.maxX &&
            rect.midY >= 0 &&
            rect.midY <= screen.frame.height
        }
    }

    func setupClickOutsideMonitors() {
        cleanupClickMonitors()

        // Global: clicks in OTHER apps
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.hidePanel()
        }

        // Local: clicks in OUR app but NOT on the panel
        clickLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let panel = self.panel, panel.isVisible else {
                return event
            }
            if event.window == panel {
                return event
            }
            self.hidePanel()
            return event
        }
    }

    func hidePanel() {
        panel?.orderOut(nil)
        cleanupTypingKeyboardMonitor()
        cleanupClickMonitors()
    }

    func cleanupClickMonitors() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
        if let monitor = clickLocalMonitor {
            NSEvent.removeMonitor(monitor)
            clickLocalMonitor = nil
        }
    }

    func cleanupMonitors() {
        cleanupClickMonitors()
        cleanupTypingKeyboardMonitor()
        if let monitor = hotkeyGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            hotkeyGlobalMonitor = nil
        }
        if let monitor = hotkeyLocalMonitor {
            NSEvent.removeMonitor(monitor)
            hotkeyLocalMonitor = nil
        }
    }

    private func matchesHotkey(event: CGEvent) -> Bool {
        let parsed = parseHotkeyCombo(hotkeyCombo)
        let flags = event.flags
        let shiftOk = (parsed.modifiers & UInt32(shiftKey)) == 0 || flags.contains(.maskShift)
        let cmdOk = (parsed.modifiers & UInt32(cmdKey)) == 0 || flags.contains(.maskCommand)
        let optionOk = (parsed.modifiers & UInt32(optionKey)) == 0 || flags.contains(.maskAlternate)
        let controlOk = (parsed.modifiers & UInt32(controlKey)) == 0 || flags.contains(.maskControl)
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        return shiftOk && cmdOk && optionOk && controlOk && keyCode == parsed.keyCode
    }

    private func setupTypingKeyboardMonitor(source: PanelPresentationSource) {
        guard source == .typingContext else {
            cleanupTypingKeyboardMonitor()
            return
        }
        typingKeyboardNavigationEnabled = true
        if typingKeyboardLocalMonitor == nil {
            typingKeyboardLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self else { return event }
                if self.handleTypingKeyboardNavigation(event) {
                    return nil
                }
                return event
            }
        }
        logStatus("Typing keyboard navigation enabled")
    }

    private func cleanupTypingKeyboardMonitor() {
        typingKeyboardNavigationEnabled = false
        if let monitor = typingKeyboardLocalMonitor {
            NSEvent.removeMonitor(monitor)
            typingKeyboardLocalMonitor = nil
        }
        if let clippyPanel = panel as? ClippyPanel {
            clippyPanel.acceptsKeyboardNavigationFocus = false
        }
    }

    @discardableResult
    private func handleTypingKeyboardNavigation(_ event: NSEvent) -> Bool {
        guard typingKeyboardNavigationEnabled,
              panel?.isVisible == true else { return false }

        switch event.keyCode {
        case UInt16(kVK_DownArrow):
            runKeyboardBridgeScript("window.clippyKeyboardMove && window.clippyKeyboardMove(1);", log: "down-local")
            return true
        case UInt16(kVK_UpArrow):
            runKeyboardBridgeScript("window.clippyKeyboardMove && window.clippyKeyboardMove(-1);", log: "up-local")
            return true
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            let plain = event.modifierFlags.contains(.shift) ? "true" : "false"
            runKeyboardBridgeScript("window.clippyKeyboardPasteSelected && window.clippyKeyboardPasteSelected(\(plain));", log: "enter-local")
            return true
        case UInt16(kVK_Escape):
            runKeyboardBridgeScript("window.clippyKeyboardClose && window.clippyKeyboardClose();", log: "escape-local")
            return true
        default:
            return false
        }
    }

    @discardableResult
    private func handleTypingKeyboardNavigation(_ event: CGEvent) -> Bool {
        guard typingKeyboardNavigationEnabled,
              panel?.isVisible == true else { return false }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        switch keyCode {
        case UInt16(kVK_DownArrow):
            runKeyboardBridgeScript("window.clippyKeyboardMove && window.clippyKeyboardMove(1);", log: "down")
            return true
        case UInt16(kVK_UpArrow):
            runKeyboardBridgeScript("window.clippyKeyboardMove && window.clippyKeyboardMove(-1);", log: "up")
            return true
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            let plain = flags.contains(.maskShift) ? "true" : "false"
            runKeyboardBridgeScript("window.clippyKeyboardPasteSelected && window.clippyKeyboardPasteSelected(\(plain));", log: "enter")
            return true
        case UInt16(kVK_Escape):
            runKeyboardBridgeScript("window.clippyKeyboardClose && window.clippyKeyboardClose();", log: "escape")
            return true
        default:
            return false
        }
    }

    private func runKeyboardBridgeScript(_ script: String, log key: String) {
        logStatus("Typing keyboard navigation key=\(key)")
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

}

// ── Main ──
@main
struct ClippyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
