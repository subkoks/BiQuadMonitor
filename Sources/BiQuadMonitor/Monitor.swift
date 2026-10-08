import AppKit
import Combine
import Foundation
import SignalCore
import SessionStore
import UniformTypeIdentifiers

@MainActor final class Monitor: ObservableObject {
    @Published var sample: SignalSample?
    @Published var records: [SignalRecord] = []
    @Published var events: [MeasurementEvent] = []
    @Published var trials: [AntennaTrial] = []
    @Published var sessions: [MeasurementSession] = []
    @Published var currentSession: MeasurementSession?
    @Published var activeTrial: AntennaTrial?
    @Published var referenceID: UUID?
    @Published var comparisonID: UUID?
    @Published var referenceRecords: [SignalRecord] = []
    @Published var comparisonRecords: [SignalRecord] = []
    @Published var archived: SessionSnapshot?
    @Published var archivedCount = 0
    @Published var trialElapsed: Double = 0
    @Published var totalSamples = 0
    @Published var message = "Connect to your Cudy router to start monitoring."
    @Published var storageMessage = ""
    @Published var state: ReadingState = .setup { didSet { statusChanged?() } }
    @Published var busy = false
    @Published private(set) var transitioning = false
    @Published private(set) var trialTransitioning = false
    @Published var settings = false
    @Published var showExport = false
    @Published var exporting = false
    @Published var demo = false
    @Published var host: String
    @Published var secure: Bool
    @Published var remember: Bool
    @Published var interval: Double
    @Published var menuPreset: MenuPreset { didSet { savePresentation(); statusChanged?() } }
    @Published var menuMetrics: Set<Metric> { didSet { savePresentation(); statusChanged?() } }
    @Published var appearance: String { didSet { savePresentation() } }
    @Published var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: "retentionDays") } }
    @Published var pinnedTuner: Bool = false
    @Published var audioFeedback = false
    @Published var audioThreshold: Double = 10
    @Published var trialName = "Position A"
    @Published var trialNotes = ""
    @Published var trialOrientation = ""
    @Published var settlingSeconds: Double = 60
    @Published var recordingSeconds: Double = 120
    var statusChanged: (() -> Void)?
    var openWorkspace: (() -> Void)?
    var openCompact: (() -> Void)?
    private let defaults: UserDefaults
    private let storeTask: Task<SessionStore, Error>
    private var client: (any RouterConnection)?
    private let clientFactory: (String, Bool) throws -> any RouterConnection
    private var pollTask: Task<Void, Never>?
    private var heartbeat: Timer?
    private var generation = 0
    private var failures = 0
    private var segment = 0
    private var connectedAccount = ""
    private var canRenew = false
    private var renewalAttempted = false
    private var trialStartUptime: TimeInterval?
    private var audioLastPlayed = Date.distantPast
    private var appending = false
    private var resumeAfterSleep = false
    var online: Bool { state.hasCurrentReadings }
    var history: [SignalSample] { records.map(\.sample) }
    var account: String { "\(secure ? "https" : "http")://\(host.trimmingCharacters(in: .whitespacesAndNewlines))" }
    var canResume: Bool { !transitioning && currentSession != nil && (client != nil || demo) }
    var menuTitle: String { DisplayFormat.menu(sample: sample, state: state, preset: menuPreset, metrics: Array(menuMetrics)) }
    var currentTrialRecords: [SignalRecord] {
        guard let trial = activeTrial ?? trials.last else { return [] }
        return TrialAnalysis.readings(records, trial: trial)
    }
    var comparable: Bool { TrialAnalysis.comparable(referenceRecords, effectiveComparison) }
    var effectiveComparison: [SignalRecord] { comparisonID == nil ? currentTrialRecords : comparisonRecords }

    init(ephemeral: Bool = false, defaults suppliedDefaults: UserDefaults? = nil, clientFactory: @escaping (String, Bool) throws -> any RouterConnection = { try RouterClient(host: $0, secure: $1) }) {
        self.clientFactory = clientFactory
        let defaults = suppliedDefaults ?? (ephemeral ? UserDefaults(suiteName: "local.blackterminal.BiQuadMonitor.diagnostic.\(UUID().uuidString)")! : .standard)
        self.defaults = defaults
        host = defaults.string(forKey: "routerHost") ?? "192.168.10.1"
        secure = defaults.bool(forKey: "routerHTTPS"); remember = defaults.bool(forKey: "rememberPassword")
        let savedInterval = defaults.double(forKey: "pollInterval")
        interval = [3.0, 5, 10, 15, 30].contains(savedInterval) ? savedInterval : 5
        menuPreset = MenuPreset(rawValue: defaults.string(forKey: "menuPreset") ?? "") ?? .full
        menuMetrics = Set((defaults.stringArray(forKey: "menuMetrics") ?? Metric.allCases.map(\.rawValue)).compactMap(Metric.init(rawValue:)))
        appearance = defaults.string(forKey: "appearance") ?? "Dark"
        retentionDays = [7, 30, 90].contains(defaults.integer(forKey: "retentionDays")) ? defaults.integer(forKey: "retentionDays") : 30
        storeTask = Task.detached(priority: .utility) {
            let store = try SessionStore(url: ephemeral ? nil : SessionStore.defaultURL(), exclusiveWriter: !ephemeral)
            if !ephemeral { try await store.recoverInterruptedSessions() }
            return store
        }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Task { await reloadSessions() }
    }

    private func savePresentation() {
        defaults.set(menuPreset.rawValue, forKey: "menuPreset")
        defaults.set(menuMetrics.map(\.rawValue), forKey: "menuMetrics")
        defaults.set(appearance, forKey: "appearance")
    }
    func stop() {
        generation += 1; pollTask?.cancel(); pollTask = nil; client?.close(); client = nil
        busy = false; transitioning = false; state = sample == nil ? .setup : .offline
    }
    func shutdown() async {
        stop(); heartbeat?.invalidate(); heartbeat = nil
        await finishSession()
    }
    private func createSession(demo: Bool, token: Int) async throws {
        let store = try await storeTask.value
        guard token == generation else { throw CancellationError() }
        var session = MeasurementSession(name: "\(demo ? "Demo" : "Measurements") · \(Date().formatted(date: .abbreviated, time: .shortened))", demo: demo)
        try await store.save(session)
        guard token == generation else { session.ended = Date(); try await store.save(session); throw CancellationError() }
        currentSession = session; records = []; events = []; trials = []; totalSamples = 0
        activeTrial = nil; referenceID = nil; comparisonID = nil; referenceRecords = []; comparisonRecords = []
        segment = 0; archived = nil
        await reloadSessions()
    }
    private func finishSession() async {
        await finishTrial(cancelled: true)
        guard var session = currentSession else { return }
        session.ended = Date()
        do { let store = try await storeTask.value; try await store.save(session) }
        catch { storageMessage = error.localizedDescription }
        currentSession = nil
    }
    func connect(password: String, persistSettings: Bool = true) async {
        guard !busy else { return }
        guard !password.isEmpty else { message = "Enter your router admin password, or choose your saved Keychain password."; return }
        let targetHost = host.trimmingCharacters(in: .whitespacesAndNewlines), targetSecure = secure
        do { _ = try RouterProtocol.baseURL(targetHost, secure: targetSecure) }
        catch { message = error.localizedDescription; return }
        stop(); busy = true; transitioning = true
        let current = generation
        defer { if current == generation { busy = false; transitioning = false; statusChanged?() } }
        demo = false; sample = nil; state = .connecting
        await finishSession()
        guard current == generation else { return }
        message = "Signing in and reading cellular status…"; storageMessage = ""
        do {
            let newClient = try clientFactory(targetHost, targetSecure)
            client = newClient
            let value = try await newClient.login(password: password)
            guard current == generation else { return }
            try await createSession(demo: false, token: current)
            guard current == generation else { return }
            connectedAccount = "\(targetSecure ? "https" : "http")://\(targetHost)"
            canRenew = remember && persistSettings; renewalAttempted = false
            if persistSettings {
                defaults.set(targetHost, forKey: "routerHost"); defaults.set(targetSecure, forKey: "routerHTTPS")
                defaults.set(interval, forKey: "pollInterval"); defaults.set(remember, forKey: "rememberPassword")
                if remember { do { try PasswordStore.save(password, account: connectedAccount) } catch { storageMessage = error.localizedDescription; canRenew = false } }
                else { PasswordStore.remove(connectedAccount) }
            }
            await accept(value)
            guard current == generation else { return }
            startTimer(); settings = false
        } catch {
            guard current == generation else { return }
            state = .offline; message = error.localizedDescription; client?.close(); client = nil
        }
    }
    func startTimer() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = self.failures == 0 ? self.interval : min(60, self.interval * pow(2, Double(min(4, self.failures))))
                do { try await Task.sleep(nanoseconds: UInt64(max(1, delay) * 1_000_000_000)) } catch { return }
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }
    func refresh() async {
        guard !busy, state != .paused else { return }
        if demo {
            let step = Double(totalSamples)
            await accept(SignalSample(sinr: 8 + sin(step / 3) * 2, rsrq: -9 + cos(step / 4) * 0.5, rsrp: -96 + sin(step / 6), rssi: 23, band: "3", cell: "DEMO-A", carrier: "Demo · simulated"))
            return
        }
        guard let client else { return }
        busy = true; let current = generation
        do {
            let value = try await client.poll()
            if current == generation { await accept(value) }
        } catch {
            guard current == generation else { return }
            if case MonitorError.login = error {
                if canRenew && !renewalAttempted, let saved = PasswordStore.read(connectedAccount) {
                    renewalAttempted = true
                    do {
                        let value = try await client.login(password: saved)
                        if current == generation { await accept(value); await event(.recovery, "Router session renewed.") }
                    } catch {
                        if current == generation { authenticationRequired() }
                    }
                } else { authenticationRequired() }
            } else {
                failures += 1; segment += 1; state = sample == nil ? .offline : .stale
                message = error.localizedDescription
                if failures == 1 { await event(.gap, "Router reading unavailable. A chart gap was recorded.") }
            }
        }
        if current == generation { busy = false }
    }
    private func authenticationRequired() {
        pollTask?.cancel(); pollTask = nil; client?.close(); client = nil
        state = .signInRequired; message = "Your router session expired or sign-in was rejected. Connect again in Settings."
    }
    func accept(_ value: SignalSample) async {
        guard !appending else { return }
        let current = generation
        appending = true; defer { appending = false }
        if let previous = sample, previous.band != value.band || previous.cell != value.cell || previous.rssiUnits != value.rssiUnits {
            segment += 1; await event(.contextChanged, "Band, cell or units changed. Compare matching measurement segments only.")
        }
        if failures > 0 { await event(.recovery, "Router readings resumed.") }
        guard current == generation else { return }
        failures = 0; sample = value
        state = demo ? .demo : (value.connected ? .live : .noService)
        message = value.connected ? "Read-only cellular monitoring · refreshed every \(Int(interval)) seconds" : "The router is reachable but reports no cellular connection."
        guard let session = currentSession else { statusChanged?(); return }
        await advanceTrial()
        guard current == generation else { return }
        let record = SignalRecord(sessionID: session.id, trialID: activeTrial?.id, sample: value, phase: activeTrial?.phase, segment: segment, expectedInterval: interval)
        do {
            let store = try await storeTask.value; try await store.append(record)
            guard current == generation, currentSession?.id == session.id else { return }
            records.append(record); totalSamples += 1
            if records.count > 10_000 { records.removeFirst(records.count - 10_000) }
        } catch { storageMessage = error.localizedDescription }
        if audioFeedback, value.connected, let sinr = value.sinr, sinr >= audioThreshold, Date().timeIntervalSince(audioLastPlayed) >= 10 {
            NSSound(named: "Tink")?.play(); audioLastPlayed = Date()
        }
        statusChanged?()
    }
    func startDemo(seed: Bool = false) async {
        guard !busy else { return }
        stop(); busy = true; transitioning = true
        let current = generation
        defer { if current == generation { busy = false; transitioning = false } }
        await finishSession()
        guard current == generation else { return }
        demo = true; sample = nil; storageMessage = ""
        do {
            try await createSession(demo: true, token: current)
            if seed {
                for i in 0..<60 {
                    guard current == generation else { return }
                    await accept(SignalSample(date: Date().addingTimeInterval(Double(i - 60) * 5), sinr: 8 + sin(Double(i) / 4) * 2, rsrq: -9 + cos(Double(i) / 5) * 0.5, rsrp: -96 + sin(Double(i) / 7), rssi: 23, band: "3", cell: "DEMO-A", carrier: "Demo · simulated"))
                }
            }
            guard current == generation else { return }
            busy = false; await refresh()
            guard current == generation else { return }
            startTimer(); settings = false
        } catch { if current == generation { state = .offline; storageMessage = error.localizedDescription } }
    }
    func pause() async {
        guard state != .paused, canResume else { return }
        generation += 1; let current = generation
        pollTask?.cancel(); pollTask = nil; busy = true; transitioning = true
        state = .paused; message = "Collection paused. Last readings are not live."
        defer { if current == generation { busy = false; transitioning = false } }
        await finishTrial(cancelled: true)
        guard current == generation else { return }
        segment += 1
        await event(.pause, "Collection paused; any active trial was ended as incomplete.")
    }
    func resume() async {
        guard state == .paused else { return }
        guard canResume else { settings = true; return }
        let current = generation
        state = .connecting; segment += 1; await refresh()
        if current == generation { startTimer() }
    }
    func handleSleep() async {
        resumeAfterSleep = canResume && state != .paused
        if resumeAfterSleep { await pause() }
    }
    func handleWake() async {
        let shouldResume = resumeAfterSleep; resumeAfterSleep = false
        if shouldResume, state == .paused, canResume { await resume() }
    }
    private func tick() async {
        if state.hasCurrentReadings, let sample, Date().timeIntervalSince(sample.date) > interval * 3 { state = .stale }
        await advanceTrial()
    }
    private func advanceTrial() async {
        guard var trial = activeTrial, let start = trialStartUptime else { return }
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - start)
        trialElapsed = elapsed
        if trial.phase == .settling, elapsed >= trial.settleSeconds {
            trial.phase = .recording; trial.recordingStarted = Date(); activeTrial = trial
            do { let store = try await storeTask.value; try await store.save(trial) }
            catch { storageMessage = error.localizedDescription }
        }
        if elapsed >= trial.settleSeconds + trial.targetSeconds { await finishTrial() }
    }
    func beginTrial() async {
        guard !transitioning, !trialTransitioning, state.hasCurrentReadings, sample?.connected == true, activeTrial == nil, let session = currentSession else { return }
        trialTransitioning = true
        let current = generation
        defer { trialTransitioning = false }
        var trial = AntennaTrial(sessionID: session.id, name: String(trialName.prefix(120)), notes: String(trialNotes.prefix(2000)), orientation: String(trialOrientation.prefix(120)), settleSeconds: settlingSeconds, targetSeconds: recordingSeconds)
        do {
            let store = try await storeTask.value; try await store.save(trial)
            guard current == generation, currentSession?.id == session.id, state.hasCurrentReadings else {
                trial.phase = .cancelled; trial.ended = Date(); try await store.save(trial); return
            }
            activeTrial = trial; trials.append(trial); trialStartUptime = ProcessInfo.processInfo.systemUptime; trialElapsed = 0
            await pinSession(session.id, pinned: true)
            await event(.trialStarted, "Antenna trial started. Settling readings are excluded from comparisons.")
        } catch { storageMessage = error.localizedDescription }
    }
    func finishTrial(cancelled: Bool = false) async {
        guard var trial = activeTrial else { return }
        let current = generation
        trialTransitioning = true
        defer { trialTransitioning = false }
        activeTrial = nil
        let elapsed = trialStartUptime.map { max(0, ProcessInfo.processInfo.systemUptime - $0 - trial.settleSeconds) } ?? 0
        trial.recordedSeconds = min(elapsed, trial.targetSeconds); trial.phase = cancelled ? .cancelled : .finished; trial.ended = Date()
        trialStartUptime = nil
        if let i = trials.firstIndex(where: { $0.id == trial.id }) { trials[i] = trial }
        do {
            let store = try await storeTask.value; try await store.save(trial)
            guard current == generation, currentSession?.id == trial.sessionID else { return }
            await event(.trialFinished, cancelled ? "Trial stopped before completion. Partial samples were preserved." : "Antenna trial completed.")
            if referenceID == nil, !cancelled { await setReference(trial.id) }
            else { await setComparison(trial.id) }
        } catch { storageMessage = error.localizedDescription }
    }
    func setReference(_ id: UUID) async {
        do {
            let store = try await storeTask.value; let values = try await store.trialRecords(id)
            referenceID = id; referenceRecords = values.filter { $0.phase == .recording && $0.sample.connected }
        } catch { storageMessage = error.localizedDescription }
    }
    func setComparison(_ id: UUID) async {
        do {
            let store = try await storeTask.value; let values = try await store.trialRecords(id)
            comparisonID = id; comparisonRecords = values.filter { $0.phase == .recording && $0.sample.connected }
        } catch { storageMessage = error.localizedDescription }
    }
    func addNote(_ note: String) async {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await event(.note, trimmed)
    }
    func event(_ kind: MeasurementEvent.Kind, _ text: String) async {
        guard let session = currentSession else { return }
        let value = MeasurementEvent(sessionID: session.id, kind: kind, message: text)
        do {
            let store = try await storeTask.value; try await store.append(value); events.append(value)
            if events.count > 1000 { events.removeFirst(events.count - 1000) }
        } catch { storageMessage = error.localizedDescription }
    }
    func reloadSessions() async {
        do { let store = try await storeTask.value; sessions = try await store.sessions() }
        catch { storageMessage = error.localizedDescription }
    }
    func openSession(_ id: UUID) async {
        do {
            let store = try await storeTask.value; archived = try await store.snapshot(id); archivedCount = try await store.count(id)
        } catch { storageMessage = error.localizedDescription }
    }
    func pinSession(_ id: UUID, pinned: Bool) async {
        do {
            let store = try await storeTask.value
            guard var session = try await store.sessions().first(where: { $0.id == id }) else { return }
            session.pinned = pinned; try await store.save(session)
            if currentSession?.id == id { currentSession = session }
            if archived?.session.id == id { archived?.session = session }
            await reloadSessions()
        } catch { storageMessage = error.localizedDescription }
    }
    func applyRetention() async {
        do {
            let store = try await storeTask.value
            try await store.prune(before: Date().addingTimeInterval(-Double(retentionDays) * 86400)); await reloadSessions()
        } catch { storageMessage = error.localizedDescription }
    }
    func export(format: ExportFormat, privacy: ExportPrivacy, sessionID: UUID? = nil) async {
        guard let id = sessionID ?? currentSession?.id, !exporting else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        panel.nameFieldStringValue = "BiQuad-session.\(format.rawValue.lowercased())"
        let result = await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0) } }
        guard result == .OK, let url = panel.url else { return }
        exporting = true; defer { exporting = false }
        do {
            let store = try await storeTask.value; try await store.export(id, to: url, format: format, privacy: privacy)
            storageMessage = "Export saved. All session samples were included."
        } catch { storageMessage = error.localizedDescription }
    }
}

func number(_ value: Double?) -> String { DisplayFormat.number(value) }
