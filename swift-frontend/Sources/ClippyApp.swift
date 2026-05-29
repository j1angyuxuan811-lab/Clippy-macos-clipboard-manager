import SwiftUI
import WebKit
import Cocoa
import Foundation
import Carbon.HIToolbox

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
        case "settingsChanged":
            // Immediate sync when WebView saves settings
            if let pd = dict["paste_directly"] as? Bool {
                DispatchQueue.main.async { [weak self] in
                    self?.appDelegate?.pasteDirectly = pd
                    print("⚡ paste_directly updated immediately: \(pd)")
                }
            }
        default:
            break
        }
    }

    private func sendStatusToWebView() {
        guard let delegate = appDelegate, let webView = delegate.webView else { return }
        let statusJSON: [String: Any] = [
            "hotkey_registered": delegate.hotkeyRegistered,
            "hotkey_method": delegate.hotkeyMethod,
            "hotkey_combo": "⌘⇧V",
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

            // Only simulate Cmd+V if accessibility is granted AND paste_directly is enabled
            let delegate = self?.appDelegate
            if delegate?.accessibilityGranted == true && delegate?.pasteDirectly == true {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.simulatePaste()
                }
            }
            // Otherwise content is on clipboard, user can Cmd+V manually
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
            if delegate?.accessibilityGranted == true && delegate?.pasteDirectly == true {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.simulatePaste()
                }
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
}

// ── App Delegate ──
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var panel: NSPanel?
    var webView: WKWebView?
    var backendProcess: Process?
    var clickOutsideMonitor: Any?
    var clickLocalMonitor: Any?
    var hotkeyGlobalMonitor: Any?
    var hotkeyLocalMonitor: Any?
    var bridge: ClippyBridge!
    var accessibilityGranted = false
    var carbonHotkeyRef: EventHotKeyRef?
    var hotkeyRegistered = false
    var hotkeyMethod = "none" // "carbon", "nsevent", "none"
    var pasteDirectly = true  // synced from backend settings
    var apiToken = ""         // per-session token read from data dir

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

    // ── Launch ──
    func applicationDidFinishLaunching(_ notification: Notification) {
        startBackend()
        loadAPIToken()
        setupStatusItem()
        setupPanel()
        registerCarbonHotkey()       // Panel toggle: works WITHOUT accessibility
        checkAccessibilityForPaste() // Paste simulation: needs accessibility
        // Image monitoring is handled by Go backend only (no Swift duplication)
        syncSettingsFromBackend()     // Load paste_directly setting
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopBackend()
        unregisterCarbonHotkey()
        cleanupMonitors()
    }

    // ── Carbon Global Hotkey (no accessibility needed) ──
    func registerCarbonHotkey() {
        // ⌘+Shift+V → toggle panel
        let hotkeyID = EventHotKeyID(signature: OSType(0x434C5059), id: 1) // "CLPY"
        var hotKeyRef: EventHotKeyRef?

        // keyCode 0x09 = V, cmdKey | shiftKey
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_V), modifiers, hotkeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)

        if status == noErr {
            carbonHotkeyRef = hotKeyRef
            hotkeyRegistered = true
            hotkeyMethod = "carbon"
            print("✅ Carbon hotkey registered (⌘⇧V) — no accessibility needed")
        } else {
            print("⚠️ Carbon hotkey failed (\(status)), falling back to NSEvent monitor")
            setupNSEventHotkey()
        }

        // Install Carbon event handler
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            guard let event = event else { return OSStatus(eventNotHandledErr) }
            var hotkeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
            if hotkeyID.id == 1 {
                DispatchQueue.main.async {
                    if let delegate = NSApp.delegate as? AppDelegate {
                        delegate.togglePanel()
                    }
                }
            }
            return noErr
        }, 1, &eventType, nil, nil)
    }

    func unregisterCarbonHotkey() {
        if let ref = carbonHotkeyRef {
            UnregisterEventHotKey(ref)
            carbonHotkeyRef = nil
        }
    }

    // Fallback: NSEvent monitors (requires accessibility)
    func setupNSEventHotkey() {
        hotkeyGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHotkey(event)
        }
        hotkeyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHotkey(event)
            return event
        }
        hotkeyRegistered = true
        hotkeyMethod = "nsevent"
        print("✅ NSEvent hotkey registered (⌘⇧V) — requires accessibility")
    }

    // ── Accessibility (only for paste simulation) ──
    func checkAccessibilityForPaste() {
        if AXIsProcessTrusted() {
            accessibilityGranted = true
            print("✅ Accessibility granted — paste simulation enabled")
            return
        }

        // Don't block startup with alert. Just note the status.
        // When user first tries to paste, show onboarding if needed.
        print("ℹ️ Accessibility not yet granted — paste will copy to clipboard only")

        // Silently poll in background
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                self?.accessibilityGranted = true
                print("✅ Accessibility permission granted")
            }
        }
    }

    func requestAccessibilityIfNeeded() {
        guard !accessibilityGranted else { return }

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
        // Check if backend is already running (single-instance)
        if isBackendAlive() {
            print("✅ Backend already running on port 5100, reusing")
            return
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

    private func isBackendAlive() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var alive = false

        guard let url = URL(string: "http://127.0.0.1:5100/api/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                alive = true
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 1.5)
        return alive
    }

    func stopBackend() {
        backendProcess?.terminate()
        backendProcess = nil
    }

    // ── Status Bar ──
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clippy")
            button.action = #selector(statusItemClicked)
            button.target = self
        }
    }

    @objc func statusItemClicked() {
        togglePanel()
    }

    // ── Panel ──
    func setupPanel() {
        let panelWidth: CGFloat = 400
        let panelHeight: CGFloat = 520

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )

        panel?.titlebarAppearsTransparent = true
        panel?.titleVisibility = .hidden
        panel?.isMovableByWindowBackground = true
        panel?.level = .floating
        panel?.backgroundColor = .clear
        panel?.hasShadow = true
        panel?.isOpaque = false
        panel?.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel?.animationBehavior = .utilityWindow
        panel?.hidesOnDeactivate = false

        // Liquid Glass: light frosted glass like macOS system menus
        let visualEffect = NSVisualEffectView(frame: panel!.contentView!.bounds)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.material = .popover
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
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
        webView.setValue(false, forKey: "drawsBackground")

        panel?.contentView?.addSubview(webView)
        self.webView = webView

        let htmlFile = uiDir.appendingPathComponent("index.html")
        webView.loadFileURL(htmlFile, allowingReadAccessTo: uiDir)
    }

    // ── Global Hotkey handler (for NSEvent fallback) ──
    private func handleHotkey(_ event: NSEvent) {
        let shiftPressed = event.modifierFlags.contains(.shift)
        let cmdPressed = event.modifierFlags.contains(.command)
        let vPressed = event.keyCode == 0x09 // V key

        if cmdPressed && shiftPressed && vPressed {
            DispatchQueue.main.async { [weak self] in
                self?.togglePanel()
            }
        }
    }

    // ── Toggle ──
    func togglePanel() {
        guard let panel = panel else { return }
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        guard let panel = panel else { return }

        // Position below status bar icon
        if let button = statusItem.button {
            let buttonFrame = button.window?.convertToScreen(button.frame) ?? .zero
            let panelWidth = panel.frame.width
            let panelHeight = panel.frame.height
            let x = buttonFrame.midX - panelWidth / 2
            let y = buttonFrame.minY - panelHeight - 8
            panel.setFrameOrigin(NSPoint(x: max(x, 8), y: max(y, 8)))
        }

        panel.orderFrontRegardless()

        // Reload
        webView?.reload()

        // Listen for clicks outside panel
        setupClickOutsideMonitors()
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
        if let monitor = hotkeyGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            hotkeyGlobalMonitor = nil
        }
        if let monitor = hotkeyLocalMonitor {
            NSEvent.removeMonitor(monitor)
            hotkeyLocalMonitor = nil
        }
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
