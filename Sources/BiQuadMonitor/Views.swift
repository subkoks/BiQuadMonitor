import AppKit
import SwiftUI
import Charts
import SignalCore
import SessionStore

private enum Palette {
    static let accent = Color(red: 1, green: 0.43, blue: 0.22)
    static let muted = Color.secondary
    static let background = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let border = Color.primary.opacity(0.09)
    static func metric(_ metric: Metric) -> Color {
        switch metric { case .sinr: return accent; case .rsrq: return .cyan; case .rsrp: return .purple; case .rssi: return .green }
    }
}

struct AppSurface<Content: View>: View {
    @ObservedObject var monitor: Monitor
    @ViewBuilder let content: () -> Content
    var body: some View {
        content().tint(Palette.accent).background(Palette.background)
            .preferredColorScheme(monitor.appearance == "System" ? nil : (monitor.appearance == "Light" ? .light : .dark))
    }
}

private struct Panel<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content() }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border))
    }
}

private struct StatusBadge: View {
    var state: ReadingState
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(state == .live ? Color.green : Palette.accent).frame(width: 6, height: 6)
            Text(state.label.uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced))
        }.padding(.horizontal, 9).padding(.vertical, 6)
            .background(Palette.accent.opacity(0.09), in: Capsule())
            .accessibilityLabel("Connection: \(state.label)")
    }
}

private struct MetricCard: View {
    var metric: Metric
    var sample: SignalSample?
    var records: [SignalRecord]
    var current = true
    var large = false
    private var average: Double? {
        let cutoff = (sample?.date ?? Date()).addingTimeInterval(-60)
        let recent = records.filter { $0.sample.date >= cutoff && $0.sample.connected && $0.sample.band == sample?.band && $0.sample.cell == sample?.cell && $0.sample.rssiUnits == sample?.rssiUnits }
        let values = recent.compactMap { metric.value(in: $0.sample) }.filter(\.isFinite)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    var body: some View {
        Panel {
            HStack { Text(metric.rawValue).font(.system(size: 11, weight: .semibold)); Spacer(); Text(metric.unit(for: sample)).font(.caption).foregroundStyle(.secondary) }
            Text(number(current ? sample.flatMap { metric.value(in: $0) } : nil))
                .font(.system(size: large ? 54 : 32, weight: .medium, design: .monospaced)).monospacedDigit()
                .foregroundStyle(current ? Palette.metric(metric) : Color.secondary).lineLimit(1).minimumScaleFactor(0.65)
            HStack(spacing: 4) { Text("60s mean"); Text(number(average)).monospacedDigit() }
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
            .help("\(metric.title). \(current ? "Current reading" : "Current reading unavailable; historical mean shown").")
    }
}

struct Dashboard: View {
    @ObservedObject var monitor: Monitor
    var body: some View {
        AppSurface(monitor: monitor) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("BiQuad Monitor", systemImage: "antenna.radiowaves.left.and.right").font(.headline)
                        Spacer(); StatusBadge(state: monitor.state)
                    }
                    HStack {
                        Text(monitor.sample?.carrier ?? "Cudy LT500").lineLimit(1)
                        Spacer(); Text("BAND \(monitor.sample?.band ?? "—")").monospaced()
                    }.font(.caption).foregroundStyle(.secondary)
                    MetricCard(metric: .sinr, sample: monitor.sample, records: monitor.records, current: monitor.online, large: true)
                    HStack(spacing: 8) {
                        ForEach([Metric.rsrq, .rsrp, .rssi]) { metric in
                            MetricCard(metric: metric, sample: monitor.sample, records: monitor.records, current: monitor.online)
                        }
                    }
                    if let trial = monitor.activeTrial {
                        TrialProgress(trial: trial, elapsed: monitor.trialElapsed)
                    } else {
                        HStack {
                            TextField("Trial name", text: $monitor.trialName).textFieldStyle(.roundedBorder)
                            Button("Start trial") { Task { await monitor.beginTrial() } }.disabled(!monitor.online || monitor.transitioning || monitor.trialTransitioning)
                        }
                    }
                    Text(monitor.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        IconButton("Workspace", systemImage: "rectangle.split.2x1") { monitor.openWorkspace?() }
                        Spacer()
                        Button { monitor.settings = true } label: { Image(systemName: "gearshape") }.help("Settings")
                        Button { Task { if monitor.state == .paused { await monitor.resume() } else { await monitor.pause() } } } label: { Image(systemName: monitor.state == .paused ? "play.fill" : "pause.fill") }
                            .disabled(!monitor.canResume).help(monitor.state == .paused ? "Resume collection" : "Pause collection")
                    }
                    if !monitor.storageMessage.isEmpty { Text(monitor.storageMessage).font(.caption).foregroundStyle(Palette.accent) }
                }.padding(18)
            }
        }
    }
}

private enum WorkspacePage: String, CaseIterable, Identifiable {
    case live = "Live signals", lab = "Antenna Lab", sessions = "Sessions", diagnostics = "Diagnostics"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .live: return "waveform.path.ecg"; case .lab: return "antenna.radiowaves.left.and.right"; case .sessions: return "clock.arrow.circlepath"; case .diagnostics: return "stethoscope" }
    }
    var subtitle: String {
        switch self {
        case .live: return "Cellular measurements · read directly from your router"
        case .lab: return "Settle. Record. Compare matching radio conditions."
        case .sessions: return "Your measurement history, saved on this Mac"
        case .diagnostics: return "Connection state and supported router information"
        }
    }
}

struct WorkspaceView: View {
    @ObservedObject var monitor: Monitor
    @State private var page: WorkspacePage = .live
    @State private var inspector = true
    @State private var range: Double = 300
    @State private var cursor: Date?
    @State private var note = ""
    @State private var exportSessionID: UUID?
    var body: some View {
        AppSurface(monitor: monitor) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    sidebar.frame(width: 168)
                    Divider()
                    VStack(spacing: 0) {
                        header
                        Divider()
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                switch page {
                                case .live: liveContent(wide: geometry.size.width > 1000)
                                case .lab: AntennaLabView(monitor: monitor)
                                case .sessions: sessionsContent
                                case .diagnostics: DiagnosticsView(monitor: monitor)
                                }
                                if !monitor.storageMessage.isEmpty {
                                    Label(monitor.storageMessage, systemImage: "internaldrive").font(.caption).foregroundStyle(Palette.accent)
                                }
                            }.padding(22)
                        }
                        Divider()
                        footer
                    }
                }
            }
            .sheet(isPresented: $monitor.showExport) { ExportSheet(monitor: monitor, sessionID: exportSessionID) }
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 25)).foregroundStyle(Palette.accent)
                Text("BiQuad").font(.system(size: 23, weight: .bold))
                Text("SIGNAL WORKSPACE").font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(1.5).foregroundStyle(.secondary)
            }.padding(.vertical, 22).padding(.horizontal, 14)
            ForEach(WorkspacePage.allCases) { item in
                Button { page = item } label: {
                    Label(item.rawValue, systemImage: item.symbol).font(.system(size: 12, weight: page == item ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(11)
                        .background(page == item ? Palette.accent.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(page == item ? Palette.accent : Color.primary)
                }.buttonStyle(.plain).accessibilityAddTraits(page == item ? [.isSelected] : [])
            }
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Text("CUDY LT500 V2").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                IconButton("Compact tuner", systemImage: "rectangle.compress.vertical") { monitor.openCompact?() }
                IconButton("Settings", systemImage: "gearshape") { monitor.settings = true }
                Text("0.2.0 · " + ((Bundle.main.object(forInfoDictionaryKey: "BiQuadDistribution") as? String)?.hasPrefix("unsigned release") == true ? "Unsigned" : "Preview")).font(.caption2).foregroundStyle(.tertiary)
            }.buttonStyle(.plain).font(.caption).padding(14)
        }.padding(.horizontal, 8).background(Color.black.opacity(0.08))
    }
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(page.rawValue).font(.system(size: 22, weight: .semibold))
                Text(page.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            StatusBadge(state: monitor.state)
            Button { Task { if monitor.state == .paused { await monitor.resume() } else { await monitor.pause() } } } label: { Image(systemName: monitor.state == .paused ? "play.fill" : "pause.fill") }
                .disabled(!monitor.canResume).help("Pause or resume collection")
            IconButton("Export…", systemImage: "square.and.arrow.up") {
                exportSessionID = page == .sessions ? monitor.archived?.session.id : monitor.currentSession?.id
                monitor.showExport = true
            }.disabled(page == .sessions ? monitor.archived == nil : monitor.currentSession == nil)
        }.padding(.horizontal, 22).padding(.vertical, 17)
    }
    private var footer: some View {
        HStack {
            Text(monitor.demo ? "SIMULATED DATA" : "LOCAL · READ ONLY").font(.system(size: 9, weight: .medium, design: .monospaced))
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if let date = monitor.sample?.date {
                    Text("Updated \(max(0, Int(Date().timeIntervalSince(date))))s ago").font(.caption2).monospacedDigit()
                }
            }
            Text("\(monitor.totalSamples) samples").font(.caption2).monospacedDigit()
        }.foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 9)
    }
    @ViewBuilder private func liveContent(wide: Bool) -> some View {
        HStack(spacing: 12) {
            ForEach(Metric.allCases) { metric in
                MetricCard(metric: metric, sample: monitor.sample, records: monitor.records, current: monitor.online)
            }
        }
        HStack {
            Label("Signal history", systemImage: "chart.xyaxis.line").font(.headline)
            Spacer()
            Picker("Time range", selection: $range) {
                Text("1m").tag(60.0); Text("5m").tag(300.0); Text("30m").tag(1800.0); Text("1h").tag(3600.0); Text("Session").tag(0.0)
            }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 300)
            Toggle(isOn: $inspector) { Image(systemName: "sidebar.right") }.toggleStyle(.button).help("Show radio details")
        }
        HStack(alignment: .top, spacing: 18) {
            HistoryGrid(records: monitor.records, interval: range, cursor: $cursor)
            if inspector && wide { radioInspector.frame(width: 184) }
        }
        if inspector && !wide { radioInspector }
        HStack {
            TextField("Add an observation, e.g. rotated antenna 10° east", text: $note).textFieldStyle(.roundedBorder)
            Button("Add note") { let text = note; note = ""; Task { await monitor.addNote(text) } }.disabled(note.trimmingCharacters(in: .whitespaces).isEmpty || monitor.currentSession == nil)
        }
        EventList(events: Array(monitor.events.suffix(8)))
    }
    private var radioInspector: some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                Text("RADIO CONTEXT").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                DetailRow(label: "Band", value: monitor.sample?.band ?? "—")
                DetailRow(label: "Cell", value: monitor.sample?.cell ?? "—")
                DetailRow(label: "Operator", value: monitor.sample?.carrier ?? "—")
                ForEach(["PCID", "MODE", "UL BANDWIDTH", "DL BANDWIDTH"], id: \.self) { key in
                    if let value = monitor.sample?.details[key] { DetailRow(label: key, value: value) }
                }
                Divider()
                Text(monitor.message).font(.caption).foregroundStyle(.secondary)
                Text("RSSI uses the router's raw index unless dBm is explicitly supplied. Wi-Fi signal is a separate link.").font(.caption2).foregroundStyle(.secondary)
                Button("Connection settings") { monitor.settings = true }
            }
        }
    }
    private var sessionsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Recent sessions").font(.headline); Spacer(); Button("Refresh") { Task { await monitor.reloadSessions() } } }
            if monitor.sessions.isEmpty { EmptyPanel(title: "No saved sessions", text: "Connect to your router or open Demo to start a local session.", symbol: "clock") }
            ForEach(monitor.sessions) { session in
                HStack(spacing: 12) {
                    Image(systemName: session.demo ? "play.rectangle" : "waveform.path.ecg").foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.name).font(.system(size: 12, weight: .medium))
                        Text("\(session.started.formatted(date: .abbreviated, time: .shortened)) · \(session.demo ? "Demo" : "Router")\(session.ended == nil ? " · Open" : "")").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await monitor.pinSession(session.id, pinned: !session.pinned) } } label: { Image(systemName: session.pinned ? "pin.fill" : "pin") }.help(session.pinned ? "Unpin session" : "Keep session beyond retention period")
                    Button("Inspect") { Task { await monitor.openSession(session.id) } }
                }.padding(12).background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
            }
            if let snapshot = monitor.archived {
                Divider()
                HStack {
                    Text(snapshot.session.name).font(.headline)
                    Spacer(); Text("\(snapshot.records.count) of \(monitor.archivedCount) samples displayed").font(.caption).foregroundStyle(.secondary)
                }
                Text("Export includes every sample. The view shows the most recent 10,000.").font(.caption).foregroundStyle(.secondary)
                HistoryGrid(records: snapshot.records, interval: 0, cursor: $cursor)
                if !snapshot.trials.isEmpty {
                    Text("Saved trials · select here, then open Antenna Lab").font(.headline)
                    ForEach(snapshot.trials) { trial in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(trial.name) · \(trial.phase.rawValue) · \(Int(trial.recordedSeconds))s recorded").font(.callout)
                            HStack {
                                Button("Set reference") { Task { await monitor.setReference(trial.id) } }
                                Button("Compare") { Task { await monitor.setComparison(trial.id) } }
                            }.disabled(trial.ended == nil)
                            Text([trial.orientation, trial.notes].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                EventList(events: Array(snapshot.events.suffix(20)))
            }
        }
    }
}

private struct DetailRow: View {
    var label: String
    var value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct EmptyPanel: View {
    var title: String
    var text: String
    var symbol: String
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: symbol).font(.title2).foregroundStyle(Palette.accent)
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }.padding(.vertical, 24)
        }
    }
}

private struct HistoryGrid: View {
    var records: [SignalRecord]
    var interval: Double
    @Binding var cursor: Date?
    private var displayed: [SignalRecord] {
        guard interval > 0, let end = records.last?.sample.date else { return records }
        return records.filter { $0.sample.date >= end.addingTimeInterval(-interval) }
    }
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            ForEach(Metric.allCases) { metric in SignalChart(metric: metric, records: displayed, cursor: $cursor) }
        }.frame(maxWidth: .infinity)
    }
}

private struct SignalChart: View {
    var metric: Metric
    var records: [SignalRecord]
    @Binding var cursor: Date?
    private var unitRecords: [SignalRecord] {
        guard metric == .rssi, let unit = records.last?.sample.rssiUnits else { return records }
        return records.filter { $0.sample.rssiUnits == unit }
    }
    private var points: [ChartPoint] { ChartData.displayPoints(records, metric: metric) }
    private var domain: ClosedRange<Date> {
        let end = records.last?.sample.date ?? Date(), start = records.first?.sample.date ?? end.addingTimeInterval(-300)
        return start...max(end, start.addingTimeInterval(5))
    }
    private var scale: ClosedRange<Double> {
        let defaults: ClosedRange<Double>
        switch metric { case .sinr: defaults = -10...30; case .rsrq: defaults = -20...0; case .rsrp: defaults = -120 ... -60; case .rssi: defaults = records.last?.sample.rssiUnits == .dBm ? -120 ... -30 : 0...31 }
        return min(defaults.lowerBound, (points.map(\.value).min() ?? defaults.lowerBound) - 1)...max(defaults.upperBound, (points.map(\.value).max() ?? defaults.upperBound) + 1)
    }
    private var hovered: SignalRecord? {
        guard let cursor else { return nil }
        return unitRecords.min { abs($0.sample.date.timeIntervalSince(cursor)) < abs($1.sample.date.timeIntervalSince(cursor)) }
    }
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle().fill(Palette.metric(metric)).frame(width: 6, height: 6)
                    Text(metric.rawValue).font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("\(hovered.map { number(metric.value(in: $0.sample)) } ?? "") \(metric.unit(for: hovered?.sample ?? records.last?.sample))").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Chart {
                    ForEach(points) { point in
                        LineMark(x: .value("Time", point.date), y: .value(metric.rawValue, point.value), series: .value("Segment", point.series))
                            .foregroundStyle(Palette.metric(metric)).lineStyle(StrokeStyle(lineWidth: 1.8))
                    }
                    if points.count == 1, let point = points.first {
                        PointMark(x: .value("Time", point.date), y: .value(metric.rawValue, point.value)).foregroundStyle(Palette.metric(metric))
                    }
                    if let cursor, domain.contains(cursor) {
                        RuleMark(x: .value("Time", cursor)).foregroundStyle(Color.secondary.opacity(0.45)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartXScale(domain: domain).chartYScale(domain: scale)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(Color.clear).contentShape(Rectangle()).onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                let plot = geo[proxy.plotAreaFrame]
                                cursor = plot.contains(location) ? proxy.value(atX: location.x - plot.minX, as: Date.self) : nil
                            case .ended: cursor = nil
                            }
                        }
                    }
                }.frame(height: 145)
                .overlay { if points.isEmpty { Text("Waiting for measurements").font(.caption).foregroundStyle(.secondary) } }
                .accessibilityLabel("\(metric.rawValue) history")
                .accessibilityValue("\(points.count) valid readings. Latest \(number(records.last.flatMap { metric.value(in: $0.sample) })) \(metric.unit(for: records.last?.sample)). Gaps are not connected.")
                Text(hovered?.sample.date.formatted(date: .omitted, time: .standard) ?? (metric == .rssi && Set(records.map { $0.sample.rssiUnits.rawValue }).count > 1 ? "Showing latest RSSI unit only" : "Hover to inspect · long histories simplified"))
                    .font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
    }
}

private struct TrialProgress: View {
    var trial: AntennaTrial
    var elapsed: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text(trial.name).font(.headline); Spacer(); Text(trial.phase.rawValue.capitalized).foregroundStyle(Palette.accent) }
            ProgressView(value: min(elapsed, trial.settleSeconds + trial.targetSeconds), total: trial.settleSeconds + trial.targetSeconds)
            Text("\(max(0, Int((trial.phase == .settling ? trial.settleSeconds : trial.settleSeconds + trial.targetSeconds) - elapsed)))s remaining · \(trial.phase == .settling ? "settling samples excluded" : "recording measurements")")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

private struct AntennaLabView: View {
    @ObservedObject var monitor: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Panel {
                VStack(alignment: .leading, spacing: 14) {
                    Label("New antenna trial", systemImage: "scope").font(.headline)
                    HStack {
                        TextField("Trial name", text: $monitor.trialName)
                        TextField("Orientation / position", text: $monitor.trialOrientation)
                    }.textFieldStyle(.roundedBorder)
                    TextField("Notes about antenna spacing, angle or location", text: $monitor.trialNotes).textFieldStyle(.roundedBorder)
                    HStack {
                        Picker("Settle", selection: $monitor.settlingSeconds) { Text("0s").tag(0.0); Text("30s").tag(30.0); Text("60s").tag(60.0); Text("120s").tag(120.0) }.frame(maxWidth: 200)
                        Picker("Record", selection: $monitor.recordingSeconds) { Text("60s").tag(60.0); Text("120s").tag(120.0); Text("300s").tag(300.0) }.frame(maxWidth: 200)
                        Spacer()
                        IconButton("Start trial", systemImage: "record.circle") { Task { await monitor.beginTrial() } }
                            .buttonStyle(.borderedProminent).disabled(!monitor.online || monitor.activeTrial != nil || monitor.transitioning || monitor.trialTransitioning)
                    }
                    if let trial = monitor.activeTrial {
                        Divider(); TrialProgress(trial: trial, elapsed: monitor.trialElapsed)
                        Button("Stop trial · keep partial data") { Task { await monitor.finishTrial(cancelled: true) } }
                    } else {
                        Text("Keep the antenna still while recording. Experiment sessions are pinned automatically.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Text("Trial comparison").font(.headline); Spacer()
                Text(monitor.comparable ? "MATCHING BAND / CELL / UNITS" : "SELECT MATCHING TRIALS")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(monitor.comparable ? Color.green : Color.secondary)
            }
            if monitor.trials.isEmpty {
                EmptyPanel(title: "Capture your first reference", text: "Record a trial in the current antenna position, then move the antenna and record another. Compare medians and variability rather than a single peak.", symbol: "antenna.radiowaves.left.and.right")
            } else {
                ForEach(monitor.trials) { trial in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(trial.name).font(.callout.bold())
                            Text("\(trial.phase.rawValue.capitalized) · \(Int(trial.recordedSeconds))s · \(trial.orientation)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(monitor.referenceID == trial.id ? "Reference ✓" : "Set reference") { Task { await monitor.setReference(trial.id) } }.disabled(trial.ended == nil)
                        Button(monitor.comparisonID == trial.id ? "Selected ✓" : "Compare") { Task { await monitor.setComparison(trial.id) } }.disabled(trial.ended == nil)
                    }.padding(12).background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 14) {
                GridRow { Text("METRIC"); Text("REFERENCE MEDIAN"); Text("TRIAL MEDIAN"); Text("CHANGE"); Text("TRIAL P10–P90 / IQR") }.font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Divider().gridCellColumns(5)
                ForEach(Metric.allCases) { metric in
                    let a = TrialAnalysis.statistics(monitor.referenceRecords, metric: metric)
                    let b = TrialAnalysis.statistics(monitor.effectiveComparison, metric: metric)
                    GridRow {
                        Text(metric.rawValue).foregroundStyle(Palette.metric(metric)).fontWeight(.semibold)
                        Text(number(a?.median)); Text(number(b?.median))
                        Text(monitor.comparable ? number(a.flatMap { av in b.map { $0.median - av.median } }) : "—")
                        Text(b.map { "\(number($0.p10))…\(number($0.p90)) / \(number($0.iqr))" } ?? "—")
                    }.font(.system(size: 12, design: .monospaced))
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
            Text("\(monitor.referenceRecords.count) reference / \(monitor.effectiveComparison.count) trial samples. Missing readings are excluded per metric. Positive change means a higher reading, including less-negative RSRP and RSRQ; RSSI alone is not a quality score. Changed or unknown band/cell/units suppress the change column.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct EventList: View {
    var events: [MeasurementEvent]
    var body: some View {
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Text("EVENTS & OBSERVATIONS").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                ForEach(events.reversed()) { event in
                    HStack(alignment: .top, spacing: 12) {
                        Text(event.date.formatted(date: .omitted, time: .standard)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        Text(event.message).font(.caption).textSelection(.enabled)
                    }
                }
            }
        }
    }
}

private struct DiagnosticsView: View {
    @ObservedObject var monitor: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Panel {
                VStack(alignment: .leading, spacing: 15) {
                    HStack { Text("Connection").font(.headline); Spacer(); StatusBadge(state: monitor.state) }
                    Text(monitor.message).font(.callout).textSelection(.enabled)
                    DetailRow(label: "Transport", value: monitor.secure ? "HTTPS · certificate validation enabled" : "HTTP · local router connection")
                    DetailRow(label: "Adapter", value: "Cudy LT500 V2 · firmware 2.4.16")
                    DetailRow(label: "Status source", value: "/cgi-bin/luci/admin/network/gcom/status?detail=1&iface=4g")
                    HStack {
                        Button("Read now") { Task { await monitor.refresh() } }.disabled(monitor.busy || !monitor.canResume || monitor.state == .paused)
                        Button("Settings") { monitor.settings = true }
                    }
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Understand this measurement").font(.headline)
                    Text("These are the router's cellular readings, between your antennas and the mobile network. The Mac's Wi-Fi RSSI measures a different link and cannot replace them.")
                    Text("RSSI is retained as a raw index when that is what the Cudy reports. Missing values remain missing. The app sends no AT commands and changes no router settings.")
                    Text("If connection fails, check the address and HTTP/HTTPS selection, then BiQuad Monitor's Local Network permission in macOS Settings. Keep macOS security controls enabled.")
                }.font(.callout).foregroundStyle(.secondary)
            }
            EventList(events: Array(monitor.events.suffix(30)))
        }
    }
}

struct SettingsView: View {
    @ObservedObject var monitor: Monitor
    @State private var password = ""
    @State private var section = 0
    var body: some View {
        AppSurface(monitor: monitor) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Make it yours").font(.system(size: 23, weight: .semibold))
                    Picker("Settings section", selection: $section) { Text("Router").tag(0); Text("Appearance").tag(1); Text("Data & sound").tag(2) }.pickerStyle(.segmented)
                    if section == 0 { routerSettings }
                    if section == 1 { displaySettings }
                    if section == 2 { dataSettings }
                    if !monitor.storageMessage.isEmpty { Text(monitor.storageMessage).font(.caption).foregroundStyle(Palette.accent) }
                }.padding(24)
            }
        }
    }
    private var routerSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to Cudy").font(.headline)
            LabeledContent("Router address") { TextField("192.168.10.1", text: $monitor.host).textFieldStyle(.roundedBorder) }
            SecureField("Router admin password", text: $password).textFieldStyle(.roundedBorder)
            Toggle("Remember password in this Mac's Keychain", isOn: $monitor.remember)
            if monitor.remember {
                Button("Connect using saved password") {
                    if let saved = PasswordStore.read(monitor.account) { Task { await monitor.connect(password: saved) } }
                    else { monitor.message = "No saved password for this router. Enter your admin password." }
                }.disabled(monitor.busy)
            }
            Toggle("Use HTTPS (trusted router certificate required)", isOn: $monitor.secure)
            Picker("Refresh interval", selection: $monitor.interval) { ForEach([3.0, 5, 10, 15, 30], id: \.self) { Text("\(Int($0)) seconds").tag($0) } }.frame(maxWidth: 260)
                .disabled(monitor.activeTrial != nil)
            Text(monitor.secure ? "HTTPS validates the router certificate." : "HTTP login and readings travel over your local network without TLS. This matches a router admin page opened with http://.")
                .font(.caption).foregroundStyle(.secondary)
            Text(monitor.message).font(.caption).foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Demo") { password = ""; Task { await monitor.startDemo(seed: true) } }.disabled(monitor.busy)
                Spacer()
                Button("Close") { monitor.settings = false }
                Button(monitor.busy ? "Connecting…" : "Connect") {
                    let entered = password; password = ""; Task { await monitor.connect(password: entered) }
                }.buttonStyle(.borderedProminent).disabled(password.isEmpty || monitor.busy)
            }
        }
    }
    private var displaySettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Appearance", selection: $monitor.appearance) { ForEach(["Dark", "Light", "System"], id: \.self) { Text($0).tag($0) } }
            Picker("Menu bar", selection: $monitor.menuPreset) { ForEach(MenuPreset.allCases) { Text($0.rawValue).tag($0) } }
            if monitor.menuPreset == .custom {
                ForEach(Metric.allCases) { metric in
                    Toggle(metric.rawValue, isOn: Binding(get: { monitor.menuMetrics.contains(metric) }, set: { if $0 { monitor.menuMetrics.insert(metric) } else { monitor.menuMetrics.remove(metric) } }))
                }
            }
            Text("LTE BAND 3 | SINR 8 | RSRQ −9 | RSRP −96 | RSSI 23").font(.system(size: 11, design: .monospaced)).padding(12).background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
            Text("Full labels are the default. Choose Compact if your menu bar has limited space. Missing values show —; paused, stale and offline states replace the current readings.").font(.caption).foregroundStyle(.secondary)
            Toggle("Keep compact tuner above other windows", isOn: $monitor.pinnedTuner)
        }
    }
    private var dataSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Sessions are stored on this Mac. Antenna experiment sessions are pinned and protected from routine cleanup.").font(.callout)
            Picker("Routine history", selection: $monitor.retentionDays) { ForEach([7, 30, 90], id: \.self) { Text("\($0) days").tag($0) } }
            // Cleanup is an explicit user action. It never affects pinned or active sessions.
            Button("Remove closed, unpinned history older than \(monitor.retentionDays) days") { Task { await monitor.applyRetention() } }
            Divider()
            Toggle("Play a tone while SINR meets the target", isOn: $monitor.audioFeedback)
            HStack { Text("SINR target"); Slider(value: $monitor.audioThreshold, in: -5...30, step: 1); Text("\(Int(monitor.audioThreshold)) dB").monospacedDigit() }
            Text("Sound is off by default and limited to one tone per 10 seconds. It follows fresh readings only.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ExportSheet: View {
    @ObservedObject var monitor: Monitor
    var sessionID: UUID?
    @State private var format = ExportFormat.csv
    @State private var cells = false
    @State private var notes = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export measurement session").font(.title2.bold())
            Text("Includes all recorded samples, trial phases and events. Missing measurements remain empty.").font(.callout).foregroundStyle(.secondary)
            Picker("Format", selection: $format) { Text("CSV").tag(ExportFormat.csv); Text("JSON").tag(ExportFormat.json) }.pickerStyle(.segmented)
            Toggle("Include cell identifiers", isOn: $cells)
            Toggle("Include session names, trial notes and observations", isOn: $notes)
            Text("Router credentials, SIM identifiers and login responses are never exported.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Cancel") { monitor.showExport = false }; Spacer(); Button("Choose destination…") { monitor.showExport = false; Task { await monitor.export(format: format, privacy: ExportPrivacy(includeCell: cells, includeNamesAndNotes: notes), sessionID: sessionID) } }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 420)
    }
}

private struct IconButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.action = action
    }
    var body: some View { Button(action: action) { Label(title, systemImage: systemImage) } }
}
