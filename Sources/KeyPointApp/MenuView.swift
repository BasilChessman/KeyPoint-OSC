import AppKit
import KeyPointBackends
import KeyPointCore
import SwiftUI

struct MenuView: View {
    let engine: Engine
    @State private var showLog = false
    @State private var accessibilityTrusted = Accessibility.isTrusted
    @State private var inputMonitoring = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusHeader(engine: engine)
            Divider()
            controlSection
            Divider()
            NetworkSection(engine: engine)
            Divider()
            PerfectCueSection(engine: engine)
            Divider()
            ClickerKeysSection(engine: engine, permitted: inputMonitoring)
            Divider()
            permissionsSection
            Divider()
            filesSection
            Divider()
            logSection
            HStack {
                Text(engine.version).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
        // The menu window stays alive between openings, so keep checking while it's shown.
        .task {
            while !Task.isCancelled {
                accessibilityTrusted = Accessibility.isTrusted
                inputMonitoring = engine.keyboardPermitted
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Accept OSC actions", isOn: binding(\.actionsEnabled))
            Toggle("Send OSC feedback", isOn: binding(\.feedbacksEnabled))
            Picker("App", selection: binding(\.backendMode)) {
                Text("Automatic").tag(BackendMode.auto)
                Text("PowerPoint").tag(BackendMode.powerpoint)
                Text("Keynote").tag(BackendMode.keynote)
            }
            .pickerStyle(.segmented)
            Toggle("Allow bringing the app to the front", isOn: binding(\.allowActivatingApp))
                .help("Keynote only accepts next/previous while it is frontmost.")
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Permissions").font(.headline)
            PermissionRow(
                title: "Automation",
                ok: engine.lastError != .notAuthorized,
                detail: engine.lastError == .notAuthorized
                    ? "Denied. Allow KeyPoint OSC under Privacy & Security > Automation."
                    : "Asked the first time each app is controlled.",
                action: engine.lastError == .notAuthorized ? ("Open Settings", { openPrivacy("Privacy_Automation") }) : nil)
            Toggle("Use Accessibility features", isOn: binding(\.uiScriptingEnabled))
                .help("Go to slide N with the whole deck reachable, and switching presentations.")
            if engine.settings.uiScriptingEnabled {
                PermissionRow(
                    title: "Accessibility",
                    ok: accessibilityTrusted,
                    detail: accessibilityTrusted ? "Granted." : "Needed for go-to-slide and switching presentations in PowerPoint.",
                    action: accessibilityTrusted ? nil : ("Allow…", {
                        Accessibility.requestTrust()
                        openPrivacy("Privacy_Accessibility")
                    }))
            }
        }
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Allow file open/close over OSC", isOn: binding(\.fileAccessEnabled))
            if engine.settings.fileAccessEnabled {
                Text("Folder: ~/\(engine.settings.activeFolder)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text("Anyone who can reach this Mac on the network can open and close presentations in that folder.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var logSection: some View {
        DisclosureGroup("Activity", isExpanded: $showLog) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(engine.log.suffix(40).reversed()) { entry in
                        Text("\(entry.date.formatted(date: .omitted, time: .standard))  \(entry.text)")
                            .font(.caption.monospaced())
                            .foregroundStyle(entry.isError ? .red : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(height: 140)
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<KeyPointCore.Settings, T>) -> Binding<T> {
        Binding(get: { engine.settings[keyPath: keyPath] }, set: { value in engine.update { $0[keyPath: keyPath] = value } })
    }

    private func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct StatusHeader: View {
    let engine: Engine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("KeyPoint OSC").font(.headline)
                Spacer()
                Text(engine.activeBackend?.appName ?? "No app open")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = engine.listenError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption)
            }
            if let show = engine.snapshot.show {
                let count = engine.snapshot.active?.slideCount ?? 0
                Label("\(show.presentationName): slide \(show.currentSlide) of \(count)\(stateSuffix(show))",
                      systemImage: "play.rectangle.fill")
                    .font(.callout)
            } else if let name = engine.snapshot.activePresentation {
                Label("\(name): editing", systemImage: "rectangle.on.rectangle").font(.callout)
            }
            if let controller = engine.lastController {
                Text("Last controller: \(controller.host)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func stateSuffix(_ show: ShowInfo) -> String {
        var parts: [String] = []
        if let pos = show.buildPosition, let count = show.buildCount, count > 0 { parts.append("build \(pos)/\(count)") }
        if show.overlay != .none { parts.append(show.overlay.rawValue) }
        if show.state == .paused { parts.append("paused") }
        return parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")"
    }
}

private struct NetworkSection: View {
    let engine: Engine
    @State private var listenPort = ""
    @State private var feedbackHost = ""
    @State private var feedbackPort = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Network").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Listen port")
                    TextField("35551", text: $listenPort).frame(width: 70).onSubmit(apply)
                    Toggle("This Mac only", isOn: Binding(
                        get: { engine.settings.localOnly }, set: { v in engine.update { $0.localOnly = v } }))
                }
                GridRow {
                    Text("Feedback to")
                    TextField("Companion IP", text: $feedbackHost).onSubmit(apply)
                    TextField("35550", text: $feedbackPort).frame(width: 70).onSubmit(apply)
                }
            }
            Toggle("Also send feedback to the last controller", isOn: Binding(
                get: { engine.settings.replyToSender }, set: { v in engine.update { $0.replyToSender = v } }))
            Picker("Feedback format", selection: Binding(
                get: { engine.settings.feedbackFormat }, set: { v in engine.update { $0.feedbackFormat = v } })) {
                Text("KeyPoint").tag(FeedbackFormat.keypoint)
                Text("OSCPoint compatible").tag(FeedbackFormat.oscpoint)
            }
            .help("KeyPoint for the KeyPoint OSC Companion module; OSCPoint compatible for the Zinc: OSCPoint module.")
            if let ip = Self.localIPv4() {
                Text("This Mac: \(ip)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .textFieldStyle(.roundedBorder)
        .onAppear(perform: load)
        .onDisappear(perform: apply)
    }

    private func load() {
        listenPort = String(engine.settings.listenPort)
        feedbackHost = engine.settings.feedbackHost
        feedbackPort = String(engine.settings.feedbackPort)
    }

    private func apply() {
        engine.update { s in
            if let p = UInt16(listenPort), KeyPointCore.Settings.portRange.contains(p) { s.listenPort = p }
            if let p = UInt16(feedbackPort), KeyPointCore.Settings.portRange.contains(p) { s.feedbackPort = p }
            s.feedbackHost = feedbackHost.trimmingCharacters(in: .whitespaces)
        }
        load()
    }

    /// First non-loopback IPv4 address, to show what to enter in Companion.
    static func localIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0, (ifa.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }
}

/// Watching this Mac's keyboard for clicker keys, so presses time Keynote movies.
private struct ClickerKeysSection: View {
    let engine: Engine
    let permitted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Listen for clicker keys", isOn: Binding(
                get: { engine.settings.keyboardClickerEnabled }, set: { v in engine.update { $0.keyboardClickerEnabled = v } }))
                .help("Counts Forward/Back presses from a clicker plugged into this Mac, so Keynote movies that start on a click or with a build are timed from the clicker. Needs Input Monitoring.")
            if engine.settings.keyboardClickerEnabled {
                PermissionRow(
                    title: "Input Monitoring",
                    ok: permitted,
                    detail: permitted ? "Granted. Only clicker keys going to Keynote are counted; nothing is recorded."
                        : "Needed to see clicker presses. Turn on KeyPoint OSC, then quit and reopen it.",
                    action: permitted ? nil : ("Allow…", { engine.requestKeyboardPermission() }))
                keyRow("Forward", keys: engine.settings.clickerForwardKeys, forward: true)
                keyRow("Back", keys: engine.settings.clickerBackKeys, forward: false)
                if let forward = engine.learningClickerKey {
                    HStack {
                        Text("Press the clicker's \(forward ? "Forward" : "Back") button… (Esc cancels)")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Cancel") { engine.cancelLearning() }.controlSize(.small)
                    }
                } else if !engine.keyboardStatus.isEmpty {
                    Text(engine.keyboardStatus).font(.caption).foregroundStyle(.secondary)
                }
                Button("Reset keys to defaults") { engine.resetClickerKeys() }
                    .controlSize(.small)
                    .disabled(engine.settings.clickerForwardKeys == KeyChord.defaultForward
                        && engine.settings.clickerBackKeys == KeyChord.defaultBack)
            }
        }
    }

    private func keyRow(_ title: String, keys: [KeyChord], forward: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).frame(width: 58, alignment: .leading)
            Text(keys.isEmpty ? "none" : keys.map(\.label).joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .contextMenu {
                    ForEach(keys, id: \.self) { key in
                        Button("Remove \(key.label)") { engine.removeClickerKey(key) }
                    }
                }
            Spacer()
            Button("Learn") { engine.learnClickerKey(forward: forward) }
                .controlSize(.small)
                .disabled(!permitted || engine.learningClickerKey != nil)
        }
    }
}

/// Listening to a PerfectCue bridge, so clicker presses time Keynote movies.
private struct PerfectCueSection: View {
    let engine: Engine
    @State private var host = ""
    @State private var port = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Listen to PerfectCue bridge", isOn: Binding(
                get: { engine.settings.perfectCueEnabled }, set: { v in apply(); engine.update { $0.perfectCueEnabled = v } }))
                .help("Counts PerfectCue Forward/Back presses, so Keynote movies that start on a click or with a build are timed from the clicker.")
            if engine.settings.perfectCueEnabled {
                HStack {
                    TextField("perfectcue.local", text: $host).onSubmit(apply)
                    TextField("5100", text: $port).frame(width: 60).onSubmit(apply)
                }
                .textFieldStyle(.roundedBorder)
                HStack(spacing: 4) {
                    Image(systemName: engine.perfectCueConnected ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(engine.perfectCueConnected ? .green : .orange)
                    Text(engine.perfectCueStatus).lineLimit(2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: load)
        .onDisappear(perform: apply)
    }

    private func load() {
        host = engine.settings.perfectCueHost
        port = String(engine.settings.perfectCuePort)
    }

    private func apply() {
        engine.update { s in
            if let h = KeyPointCore.Settings.validHost(host) { s.perfectCueHost = h }
            if let p = UInt16(port.trimmingCharacters(in: .whitespaces)), p > 0 { s.perfectCuePort = p }
        }
        load()
    }
}

private struct PermissionRow: View {
    let title: String
    let ok: Bool
    let detail: String
    let action: (String, () -> Void)?

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let (label, run) = action {
                Button(label, action: run).controlSize(.small)
            }
        }
    }
}
