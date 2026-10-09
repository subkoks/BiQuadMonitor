import AppKit
import Combine
import SwiftUI
import SignalCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let diagnostic = CommandLine.arguments.contains { $0.hasPrefix("--render-") || $0.hasSuffix("smoke-test") || $0 == "--ui-testing" }
    lazy var monitor = Monitor(ephemeral: diagnostic)
    var item: NSStatusItem!
    var dashboardWindow: NSWindow!
    var workspaceWindow: NSWindow!
    var settingsWindow: NSWindow!
    var subscriptions: Set<AnyCancellable> = []
    var observers: [NSObjectProtocol] = []
    var terminating = false
    var shuttingDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMenu()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self; item.button?.action = #selector(toggle)
        dashboardWindow = makeWindow(title: "BiQuad Monitor — Compact Tuner", key: "tuner", size: NSSize(width: 450, height: 550), content: Dashboard(monitor: monitor))
        workspaceWindow = makeWindow(title: "BiQuad Monitor — Signal Workspace", key: "workspace", size: NSSize(width: 1210, height: 830), content: WorkspaceView(monitor: monitor))
        settingsWindow = makeWindow(title: "BiQuad Monitor — Settings", key: "settings", size: NSSize(width: 510, height: 510), content: SettingsView(monitor: monitor))
        monitor.$settings.removeDuplicates().sink { [weak self] visible in
            guard let self else { return }
            if visible { self.show(self.settingsWindow) } else { self.settingsWindow.orderOut(nil) }
        }.store(in: &subscriptions)
        monitor.$pinnedTuner.sink { [weak self] pinned in self?.dashboardWindow.level = pinned ? .floating : .normal }.store(in: &subscriptions)
        monitor.statusChanged = { [weak self] in self?.updateStatus() }
        monitor.openWorkspace = { [weak self] in self?.openWorkspace() }
        monitor.openCompact = { [weak self] in self?.toggle() }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitVisibleWindows() }
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notice in
                Task { @MainActor in
                    if notice.name == NSWorkspace.willSleepNotification { await self?.monitor.handleSleep() }
                    else { await self?.monitor.handleWake() }
                }
            })
        }
        updateStatus()
        Task {
            if CommandLine.arguments.contains("--demo") { await monitor.startDemo(seed: true) }
            if CommandLine.arguments.contains("--preview") { toggle() }
            if CommandLine.arguments.contains("--workspace") { openWorkspace() }
            if CommandLine.arguments.contains("--ui-smoke-test") { await runUISmokeTest(); return }
            if let output = argument("--render-preview") {
                await monitor.startDemo(seed: true)
                let window = CommandLine.arguments.contains("--render-workspace") ? workspaceWindow! : (CommandLine.arguments.contains("--render-settings") ? settingsWindow! : dashboardWindow!)
                show(window)
                try? await Task.sleep(nanoseconds: 800_000_000)
                do { try render(window, to: output); print("RENDER_PASS") } catch { print("RENDER_FAIL"); exit(1) }
                NSApp.terminate(nil); return
            }
            if CommandLine.arguments.contains("--live-smoke-test") { await runLiveSmokeTest(); return }
            if !diagnostic && !monitor.canResume && !CommandLine.arguments.contains("--demo") { monitor.settings = true }
        }
    }
    func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit BiQuad Monitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        editItem.submenu = edit; menu.addItem(editItem)
        let viewItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: ""); let view = NSMenu(title: "Window")
        view.addItem(withTitle: "Compact Tuner", action: #selector(toggle), keyEquivalent: "1").target = self
        view.addItem(withTitle: "Signal Workspace", action: #selector(openWorkspace), keyEquivalent: "2").target = self
        view.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        viewItem.submenu = view; menu.addItem(viewItem); NSApp.mainMenu = menu
    }
    func argument(_ flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.count > index + 1 else { return nil }
        return CommandLine.arguments[index + 1]
    }
    func runUISmokeTest() async {
        await monitor.startDemo(seed: true)
        for window in windows { show(window) }
        try? await Task.sleep(nanoseconds: 600_000_000)
        if let screen = NSScreen.main {
            for window in windows { window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX + 200, y: screen.visibleFrame.maxY + 200)) }
        }
        fitVisibleWindows()
        let geometryValid = windows.allSatisfy { window in
            window.styleMask.contains(.titled) && window.styleMask.contains(.closable) && NSScreen.screens.contains { $0.visibleFrame.contains(window.frame) }
        }
        // Exercise the same coordinator used by the buttons, with an isolated memory store.
        monitor.settlingSeconds = 0; monitor.recordingSeconds = 60
        await monitor.beginTrial()
        let started = monitor.activeTrial != nil
        await monitor.refresh()
        await monitor.finishTrial(cancelled: true)
        let preserved = monitor.trials.last?.phase == .cancelled && monitor.records.last?.trialID != nil
        await monitor.pause()
        let paused = monitor.state == .paused && monitor.menuTitle == "LTE · Paused"
        await monitor.handleSleep(); await monitor.handleWake()
        let manualPausePreserved = monitor.state == .paused
        await monitor.resume()
        let resumed = monitor.state == .demo && monitor.menuTitle.contains("SINR")
        await monitor.reloadSessions()
        let stored = !monitor.sessions.isEmpty
        guard geometryValid && started && preserved && paused && manualPausePreserved && resumed && stored else {
            print("UI_SMOKE_FAIL geometry=\(geometryValid) trial=\(started && preserved) pause=\(paused && manualPausePreserved) resume=\(resumed) store=\(stored)"); exit(1)
        }
        print("UI_SMOKE_PASS: three titled windows fit screen; trial capture, preservation, pause, wake, resume and session catalogue verified")
        NSApp.terminate(nil)
    }
    func runLiveSmokeTest() async {
        guard isatty(STDIN_FILENO) == 0, let password = readLine(), !password.isEmpty else {
            print("LIVE_SMOKE_FAIL: supply the router password through standard input"); exit(2)
        }
        monitor.host = "192.168.10.1"; monitor.secure = false; monitor.interval = 5
        await monitor.connect(password: password, persistSettings: false)
        show(dashboardWindow)
        var seen = 0
        for _ in 0..<65 {
            guard monitor.online, !monitor.demo else { print("LIVE_SMOKE_FAIL: \(monitor.message)"); exit(1) }
            if monitor.totalSamples > seen, let sample = monitor.sample {
                guard sample.values.allSatisfy({ $0 != nil }), sample.connected else { print("LIVE_SMOKE_FAIL: incomplete readings"); exit(1) }
                seen = monitor.totalSamples
                print("LIVE_SAMPLE \(seen): SINR=\(number(sample.sinr)) RSRQ=\(number(sample.rsrq)) RSRP=\(number(sample.rsrp)) RSSI=\(number(sample.rssi)) \(sample.rssiUnit)"); fflush(stdout)
            }
            if seen >= 8 {
                if let output = argument("--render-live") { try? render(dashboardWindow, to: output) }
                print("LIVE_SMOKE_PASS: login, four metrics and eight timed updates verified"); fflush(stdout)
                if CommandLine.arguments.contains("--keep-connected") { return }
                NSApp.terminate(nil); return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        print("LIVE_SMOKE_FAIL: insufficient timed updates"); exit(1)
    }
    /// Render only our own view. No screen capture or access to other applications.
    func render(_ window: NSWindow, to path: String) throws {
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw MonitorError.transport }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw MonitorError.transport }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    func makeWindow<Content: View>(title: String, key: String, size: NSSize, content: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false; window.delegate = self
        window.contentMinSize = NSSize(width: key == "workspace" ? 820 : 360, height: 320)
        let controller = NSHostingController(rootView: content.frame(maxWidth: .infinity, maxHeight: .infinity))
        controller.sizingOptions = []; window.contentViewController = controller
        window.setContentSize(size); window.center()
        if !diagnostic { window.setFrameAutosaveName("BiQuad.\(key)") }
        return window
    }
    var windows: [NSWindow] { [dashboardWindow, workspaceWindow, settingsWindow].compactMap { $0 } }
    func fit(_ window: NSWindow) {
        let ranked = NSScreen.screens.map { screen -> (NSScreen, CGFloat) in
            let intersection = screen.visibleFrame.intersection(window.frame)
            return (screen, intersection.isNull ? 0 : intersection.width * intersection.height)
        }
        let selected = ranked.max(by: { $0.1 < $1.1 })
        let screen = selected.flatMap { $0.1 > 0 ? $0.0 : nil } ?? item.button?.window?.screen ?? NSScreen.main
        if let screen { window.setFrame(WindowPlacement.fit(window.frame, inside: screen.visibleFrame), display: true) }
    }
    func fitVisibleWindows() { for window in windows where window.isVisible { fit(window) } }
    func show(_ window: NSWindow) {
        fit(window); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { self.fit(window) }
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settingsWindow { monitor.settings = false }
    }
    func updateStatus() {
        item.button?.title = monitor.menuTitle
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        item.button?.toolTip = "\(monitor.state.label) · SINR/RSRQ dB · RSRP dBm · RSSI \(monitor.sample?.rssiUnit ?? "raw index")\nClick for compact tuner. ⌘2 opens workspace."
    }
    @objc func toggle() { show(dashboardWindow) }
    @objc func openWorkspace() { show(workspaceWindow) }
    @objc func openSettings() { monitor.settings = true }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { toggle(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateNow }
        if !shuttingDown {
            shuttingDown = true
            Task {
                await monitor.shutdown()
                terminating = true
                DispatchQueue.main.async { sender.terminate(nil) }
            }
        }
        // Return to the main run loop so the Swift concurrency executor can drain.
        return .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
