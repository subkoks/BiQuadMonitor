import AppKit
import SwiftUI
import SignalCore
import Combine
import Darwin

@MainActor final class Monitor: ObservableObject {
    @Published var sample: SignalSample?
    @Published var history: [SignalSample] = []
    @Published var baseline: SignalSample?
    @Published var message = "Open Settings to connect to your Cudy."
    @Published var busy = false
    @Published var online = false
    @Published var settings = false
    @Published var host = UserDefaults.standard.string(forKey: "routerHost") ?? "192.168.10.1"
    @Published var secure = UserDefaults.standard.bool(forKey: "routerHTTPS")
    @Published var remember = UserDefaults.standard.bool(forKey: "rememberPassword")
    @Published var interval = max(3, UserDefaults.standard.double(forKey: "pollInterval") == 0 ? 5 : UserDefaults.standard.double(forKey: "pollInterval"))
    @Published var trial = "Antenna position A"
    var statusChanged: (() -> Void)?
    private var client: RouterClient?
    private var timer: Timer?
    private var generation = 0
    var demo = false
    var account: String { "\(secure ? "https" : "http")://\(host)" }
    var averages: [Double?] {
        let recent = history.filter { $0.date >= Date().addingTimeInterval(-60) && $0.band == sample?.band && $0.cell == sample?.cell && $0.rssiUnit == sample?.rssiUnit }
        return (0..<4).map { index in let values = recent.compactMap { $0.values[index] }; return values.isEmpty ? nil : values.reduce(0,+) / Double(values.count) }
    }
    var comparable: Bool { online && baseline != nil && baseline?.band == sample?.band && baseline?.cell == sample?.cell && baseline?.rssiUnit == sample?.rssiUnit }
    func stop() {
        generation += 1; timer?.invalidate(); timer = nil; client?.close(); client = nil
        online = false; busy = false; statusChanged?()
    }
    func accept(_ value: SignalSample) {
        sample = value; online = true; history.append(value)
        if history.count > 720 { history.removeFirst(history.count - 720) }
        message = value.connected ? "Updated \(value.date.formatted(date: .omitted, time: .standard))" : "Router reports cellular disconnected"
        statusChanged?()
    }
    func connect(password: String, persistSettings: Bool = true) async {
        guard !password.isEmpty else { message = "Enter your router admin password, or enable Remember password if you previously saved it in Keychain."; return }
        stop(); demo = false; sample = nil; baseline = nil; history = []; busy = true
        let current = generation
        do {
            let newClient = try RouterClient(host: host.trimmingCharacters(in: .whitespaces), secure: secure)
            client = newClient
            let value = try await newClient.login(password: password)
            guard current == generation else { return }
            accept(value)
            if persistSettings {
                UserDefaults.standard.set(host, forKey: "routerHost"); UserDefaults.standard.set(secure, forKey: "routerHTTPS")
                UserDefaults.standard.set(interval, forKey: "pollInterval"); UserDefaults.standard.set(remember, forKey: "rememberPassword")
                if remember { do { try PasswordStore.save(password, account: account) } catch { message = error.localizedDescription } }
                else { PasswordStore.remove(account) }
            }
            startTimer(); settings = false
        } catch {
            guard current == generation else { return }
            message = error.localizedDescription; online = false; client?.close(); client = nil
        }
        if current == generation { busy = false; statusChanged?() }
    }
    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
    }
    func refresh() async {
        guard !busy else { return }
        if demo {
            accept(SignalSample(sinr: 10 + Double.random(in: -1...1), rsrq: -10 + Double.random(in: -0.5...0.5), rsrp: -96 + Double.random(in: -1...1), rssi: 24, band: "3", cell: "DEMO", carrier: "Demo · simulated")); return
        }
        guard let client else { return }
        busy = true; let current = generation
        do { let value = try await client.poll(); if current == generation { accept(value) } }
        catch {
            if current == generation {
                online = false; message = error.localizedDescription; statusChanged?()
                if case MonitorError.login = error { timer?.invalidate(); timer = nil; self.client?.close(); self.client = nil }
            }
        }
        if current == generation { busy = false }
    }
    func startDemo() {
        stop(); demo = true; sample = nil; history = []; baseline = nil
        Task { await refresh() }; startTimer()
    }
    func resetTrial() { history = []; baseline = nil }
    func captureBaseline() {
        guard online, let s = sample else { return }
        let a = averages
        baseline = SignalSample(sinr: a[0], rsrq: a[1], rsrp: a[2], rssi: a[3], band: s.band, cell: s.cell, carrier: s.carrier)
    }
    func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "BiQuad-readings.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func quote(_ s: String) -> String {
            let safe = ["=", "+", "-", "@", "\t", "\r"].contains(where: { s.hasPrefix($0) }) ? "'" + s : s
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let formatter = ISO8601DateFormatter()
        let lines: [String] = history.map { s in
            let readings: [String] = s.values.map { value in value.map { String($0) } ?? "" }
            let row: [String] = [quote(trial), quote(demo ? "demo" : "router"), formatter.string(from: s.date)] + readings + [quote(s.rssiUnit), quote(s.band), quote(s.cell)]
            return row.joined(separator: ",")
        }
        do { try ("trial,source,timestamp,SINR_dB,RSRQ_dB,RSRP_dBm,RSSI,RSSI_unit,band,cell\n" + lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8) }
        catch { message = "Could not export readings to the selected file." }
    }
}

func number(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
func menuNumber(_ value: Double?) -> String { value.map { String(format: $0.rounded() == $0 ? "%.0f" : "%.1f", $0) } ?? "—" }

struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard values.count > 1, let low = values.min(), let high = values.max() else { return }
                let span = max(high - low, 2)
                for (i,v) in values.enumerated() {
                    let point = CGPoint(x: Double(i) / Double(values.count - 1) * geo.size.width, y: geo.size.height - ((v - low + (span - (high-low))/2) / span * geo.size.height))
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }.stroke(.cyan, lineWidth: 1.5)
        }.frame(height: 24)
    }
}

struct Dashboard: View {
    @ObservedObject var monitor: Monitor
    private let names = ["SINR", "RSRQ", "RSRP", "RSSI"]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.cyan)
                Text("BiQuad Monitor").font(.headline)
                Spacer()
                Text(monitor.demo ? "DEMO" : (monitor.online ? "LIVE" : "OFFLINE")).font(.caption.bold()).foregroundStyle(monitor.online ? .green : .orange)
            }
            Text(monitor.sample?.carrier ?? "Cudy LT500").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(0..<4) { i in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(names[i]).font(.caption.bold()); Spacer(); Text(i == 3 ? (monitor.sample?.rssiUnit ?? "raw") : (i == 2 ? "dBm" : "dB")).font(.caption2).foregroundStyle(.secondary) }
                        Text(number(monitor.sample?.values[i])).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(monitor.online ? Color.primary : Color.secondary)
                        Sparkline(values: monitor.history.suffix(60).compactMap { $0.values[i] })
                        Text("60s avg  \(number(monitor.averages[i]))").font(.caption).foregroundStyle(.secondary)
                        if monitor.comparable, let base = monitor.baseline?.values[i], let current = monitor.averages[i] {
                            Text(String(format: "Reference  %+.1f %@", current - base, i == 3 && monitor.sample?.rssiUnit == "raw index" ? "index" : "dB")).font(.caption).foregroundStyle(current >= base ? .green : .orange)
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            HStack { Text("Band \(monitor.sample?.band ?? "—")"); Spacer(); Text("Cell \(monitor.sample?.cell ?? "—")") }.font(.caption).foregroundStyle(.secondary)
            if monitor.online && monitor.baseline != nil && !monitor.comparable { Text("Band, cell or RSSI units changed. Capture a new reference before comparing.").font(.caption).foregroundStyle(.orange) }
            Text(monitor.message).font(.caption).foregroundStyle(monitor.online ? Color.secondary : Color.orange).fixedSize(horizontal: false, vertical: true)
            if !monitor.online, let sample = monitor.sample { Text("Last reading: \(sample.date.formatted(date: .omitted, time: .standard)) · values are stale").font(.caption).foregroundStyle(.orange) }
            Text("Higher values are better, including less-negative RSRP / RSRQ. RSSI is shown in the router’s units.").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            TextField("Antenna position / trial name", text: $monitor.trial).textFieldStyle(.roundedBorder)
            HStack {
                Button("Set reference") { monitor.captureBaseline() }.disabled(!monitor.online)
                Button("New trial") { monitor.resetTrial() }
                Button("Export CSV") { monitor.export() }.disabled(monitor.history.isEmpty)
            }.controlSize(.small)
            HStack {
                Button("Settings…") { monitor.settings = true }
                Button("Refresh") { Task { await monitor.refresh() } }.disabled(monitor.busy || !monitor.online)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }.controlSize(.small)
        }.padding(16).frame(maxWidth: .infinity)
    }
}

struct SettingsView: View {
    @ObservedObject var monitor: Monitor
    @State private var password = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to Cudy").font(.title2.bold())
            TextField("Router IP", text: $monitor.host).textFieldStyle(.roundedBorder)
            SecureField("Router admin password", text: $password).textFieldStyle(.roundedBorder)
            Toggle("Remember password in this Mac’s Keychain", isOn: $monitor.remember)
            Toggle("Use HTTPS (requires a trusted router certificate)", isOn: $monitor.secure)
            Picker("Refresh", selection: $monitor.interval) { ForEach([3.0,5,10,15,30], id: \.self) { Text("\(Int($0)) seconds").tag($0) } }
            Text(monitor.secure ? "HTTPS requires a certificate trusted by macOS. Self-signed certificates are not accepted automatically." : "HTTP login and readings travel over your local network without TLS. This matches your current Cudy browser connection.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Reads cellular status only; no router settings are changed.").font(.caption).foregroundStyle(.secondary)
            Text(monitor.message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Demo") { password = ""; monitor.settings = false; monitor.startDemo() }
                Button("Cancel") { password = ""; monitor.settings = false }
                Spacer()
                Button(monitor.busy ? "Connecting…" : "Connect") {
                    let entered = password.isEmpty && monitor.remember ? (PasswordStore.read(monitor.account) ?? "") : password
                    password = ""; Task { await monitor.connect(password: entered) }
                }.disabled(monitor.busy || (password.isEmpty && !monitor.remember)).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(maxWidth: .infinity)
        .onDisappear { password = "" }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let monitor = Monitor()
    var item: NSStatusItem!
    var dashboardWindow: NSWindow!
    var settingsWindow: NSWindow!
    var settingsObserver: AnyCancellable?
    var screenObserver: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self; item.button?.action = #selector(toggle)
        dashboardWindow = makeWindow(title: "BiQuad Monitor", width: 400, height: 530, content: Dashboard(monitor: monitor))
        settingsWindow = makeWindow(title: "BiQuad Monitor — Router Settings", width: 460, height: 400, content: SettingsView(monitor: monitor))
        settingsObserver = monitor.$settings.removeDuplicates().sink { [weak self] visible in
            guard let self else { return }
            if visible { self.show(self.settingsWindow) }
            else { self.settingsWindow.orderOut(nil) }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitVisibleWindows() }
        }
        monitor.statusChanged = { [weak self] in self?.updateStatus() }
        updateStatus()
        if CommandLine.arguments.contains("--demo") { monitor.startDemo() }
        if CommandLine.arguments.contains("--preview") { toggle() }
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
            let output = CommandLine.arguments[index + 1]
            monitor.startDemo()
            for i in 0..<12 {
                monitor.accept(SignalSample(date: Date().addingTimeInterval(-Double(12-i)*5), sinr: 10 + sin(Double(i)), rsrq: -10 + cos(Double(i))*0.5, rsrp: -96 + sin(Double(i)*0.5), rssi: 24, band: "3", cell: "DEMO", carrier: "Demo · simulated"))
            }
            show(dashboardWindow)
            if CommandLine.arguments.contains("--render-settings") { monitor.settings = true }
            let window = CommandLine.arguments.contains("--render-settings") ? settingsWindow! : dashboardWindow!
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.fitVisibleWindows()
                // Capture this app's synthetic window only, including its draggable title bar.
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), output]
                do { try capture.run(); capture.waitUntilExit() } catch { }
                NSApp.terminate(nil)
            }
        }
        if CommandLine.arguments.contains("--ui-smoke-test") {
            monitor.startDemo(); show(dashboardWindow); monitor.settings = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let initialSizeValid = self.dashboardWindow.frame.width >= 400 && self.dashboardWindow.frame.height >= 500 && self.settingsWindow.frame.width >= 420 && self.settingsWindow.frame.height >= 400
                // Exercise recovery from an off-screen origin and an oversized settings window.
                if let screen = NSScreen.main {
                    self.dashboardWindow.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX + 200, y: screen.visibleFrame.maxY + 200))
                    self.settingsWindow.setFrame(NSRect(x: screen.visibleFrame.minX - 200, y: screen.visibleFrame.minY - 200, width: screen.visibleFrame.width + 300, height: screen.visibleFrame.height + 300), display: true)
                }
                self.fitVisibleWindows()
                let windows = [self.dashboardWindow!, self.settingsWindow!]
                let valid = initialSizeValid && windows.allSatisfy { window in
                    window.styleMask.contains(.titled) && window.styleMask.contains(.closable) && NSScreen.screens.contains { $0.visibleFrame.contains(window.frame) }
                }
                print(valid ? "WINDOW_SMOKE_PASS: dashboard and settings are titled and inside visible screen bounds" : "WINDOW_SMOKE_FAIL")
                if !valid { exit(1) }
                NSApp.terminate(nil)
            }
        }
        if CommandLine.arguments.contains("--connection-smoke-test") {
            Task {
                for secure in [false, true] {
                    do {
                        let client = try RouterClient(host: "192.168.10.1", secure: secure)
                        defer { client.close() }
                        try await client.probePublicLogin()
                        print("\(secure ? "HTTPS" : "HTTP") public login probe: reachable")
                    } catch { print("\(secure ? "HTTPS" : "HTTP") public login probe: \(error.localizedDescription)") }
                }
                NSApp.terminate(nil)
            }
        }
        if CommandLine.arguments.contains("--live-smoke-test") {
            Task { await runLiveSmokeTest() }
        }
    }
    func runLiveSmokeTest() async {
        // Opt-in diagnostic: use a pipe, never a password argument, environment
        // variable or saved credential. Exercise the same connect/timer/UI path.
        guard isatty(STDIN_FILENO) == 0, let password = readLine(), !password.isEmpty else {
            print("LIVE_SMOKE_FAIL: supply the router password through standard input")
            exit(2)
        }
        monitor.host = "192.168.10.1"; monitor.secure = false; monitor.interval = 5
        await monitor.connect(password: password, persistSettings: false)
        show(dashboardWindow)
        var seen = 0
        for _ in 0..<65 {
            guard monitor.online, !monitor.demo else {
                print("LIVE_SMOKE_FAIL: \(monitor.message)"); monitor.stop(); exit(1)
            }
            if monitor.history.count > seen, let sample = monitor.sample {
                guard sample.values.allSatisfy({ $0 != nil }), sample.connected else {
                    print("LIVE_SMOKE_FAIL: incomplete readings or cellular disconnected"); monitor.stop(); exit(1)
                }
                seen = monitor.history.count
                print("LIVE_SAMPLE \(seen): SINR=\(number(sample.sinr)) dB RSRQ=\(number(sample.rsrq)) dB RSRP=\(number(sample.rsrp)) dBm RSSI=\(number(sample.rssi)) \(sample.rssiUnit)")
                fflush(stdout)
            }
            if seen >= 8 {
                if let index = CommandLine.arguments.firstIndex(of: "--render-live"), CommandLine.arguments.count > index + 1 {
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l", String(dashboardWindow.windowNumber), CommandLine.arguments[index + 1]]
                    do {
                        try capture.run(); capture.waitUntilExit()
                        guard capture.terminationStatus == 0 else { throw MonitorError.transport }
                    } catch { print("LIVE_SMOKE_FAIL: could not capture app window"); monitor.stop(); exit(1) }
                }
                print("LIVE_SMOKE_PASS: login, all four metrics, eight timed updates and dashboard state verified")
                fflush(stdout)
                if CommandLine.arguments.contains("--keep-connected") { return }
                monitor.stop(); NSApp.terminate(nil); return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        print("LIVE_SMOKE_FAIL: polling did not produce eight readings"); monitor.stop(); exit(1)
    }
    func makeWindow<Content: View>(title: String, width: CGFloat, height: CGFloat, content: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 300, height: 180)
        let controller = NSHostingController(rootView: ScrollView { content }.frame(maxWidth: .infinity, maxHeight: .infinity))
        controller.sizingOptions = []
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: height))
        window.center()
        return window
    }
    func screen(for window: NSWindow) -> NSScreen? {
        let ranked = NSScreen.screens.map { screen -> (NSScreen, CGFloat) in
            let intersection = screen.visibleFrame.intersection(window.frame)
            return (screen, intersection.isNull ? 0 : intersection.width * intersection.height)
        }
        if let best = ranked.max(by: { $0.1 < $1.1 }), best.1 > 0 { return best.0 }
        return item.button?.window?.screen ?? NSScreen.main
    }
    func fit(_ window: NSWindow) {
        if let screen = screen(for: window) { window.setFrame(WindowPlacement.fit(window.frame, inside: screen.visibleFrame), display: true) }
    }
    func fitVisibleWindows() {
        for window in [dashboardWindow, settingsWindow].compactMap({ $0 }) where window.isVisible { fit(window) }
    }
    func show(_ window: NSWindow) {
        fit(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { self.fit(window) }
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settingsWindow { monitor.settings = false }
    }
    func updateStatus() {
        if monitor.online, let sample = monitor.sample {
            item.button?.title = "\(monitor.demo ? "Demo" : "LTE") S \(menuNumber(sample.sinr)) · Q \(menuNumber(sample.rsrq)) · P \(menuNumber(sample.rsrp)) · R \(menuNumber(sample.rssi))"
        } else { item.button?.title = "LTE · \(monitor.sample == nil ? "Setup" : "Offline")" }
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        item.button?.toolTip = "SINR · RSRQ · RSRP · RSSI — click for antenna readings"
    }
    @objc func toggle() { show(dashboardWindow) }
    func applicationWillTerminate(_ notification: Notification) { monitor.stop(); if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
