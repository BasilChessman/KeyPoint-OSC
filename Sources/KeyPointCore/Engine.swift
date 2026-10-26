import Foundation
import Observation
import os

/// Sends encoded feedback. `UDPSender` in the app, a recorder in tests.
public protocol FeedbackSink: AnyObject, Sendable {
    func send(_ data: Data, to host: String, port: UInt16) throws
}

extension UDPSender: FeedbackSink {}
extension UDPListener: FeedbackSink {}

/// Where feedback goes, and in which format.
struct FeedbackTarget: Hashable {
    let host: String
    let port: UInt16
    /// Replies to KeyPoint controllers go out from the listening socket.
    let viaListener: Bool
}

public struct LogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let date = Date()
    public let text: String
    public let isError: Bool
}

/// Ties everything together: receives OSC, runs commands one at a time against the
/// selected backend, polls it, and publishes feedback.
@MainActor @Observable
public final class Engine {
    public private(set) var settings: Settings
    public private(set) var activeBackend: BackendKind?
    public private(set) var snapshot = BackendSnapshot.empty
    public private(set) var listenError: String?
    public private(set) var lastError: BackendError?
    public private(set) var lastController: UDPPeer?
    /// KeyPoint-format controllers (e.g. the KeyPoint OSC Companion module) heard from recently.
    public private(set) var keypointControllers: [UDPPeer] = []
    public private(set) var log: [LogEntry] = []
    public private(set) var isRunning = false

    public let version: String
    private let backends: [any SlideBackend]
    private let sink: any FeedbackSink
    private let listener = UDPListener()
    private let replySink: any FeedbackSink
    private var publishers: [FeedbackFormat: FeedbackPublisher]
    private let onSettingsChange: (Settings) -> Void
    /// The last sender of `/oscpoint` commands, for "reply to the last controller".
    private var legacyController: UDPPeer?
    private var keypointSeen: [UDPPeer: Date] = [:]
    /// A KeyPoint controller is forgotten after this long without a message (the module pings every 3 s).
    public var controllerTimeout: TimeInterval = 15

    private var commandContinuation: AsyncStream<(Command, UDPPeer?)>.Continuation?
    private var tasks: [Task<Void, Never>] = []
    private var snapshots: [BackendKind: BackendSnapshot] = [:]
    private var lastPolled: [BackendKind: Date] = [:]
    private var pollInFlight = false
    private var pollAgain = false

    /// Poll intervals: during a show, with an app open, and with nothing to talk to.
    public var showInterval: Duration = .milliseconds(300)
    public var idleInterval: Duration = .seconds(1)
    public var absentInterval: Duration = .seconds(2)
    /// How often to check a backend that isn't selected, to notice a show starting there.
    public var backgroundCheckInterval: TimeInterval = 2

    /// `replySink` sends replies to KeyPoint controllers; by default the listening socket.
    public init(backends: [any SlideBackend], settings: Settings, sink: any FeedbackSink,
                replySink: (any FeedbackSink)? = nil, version: String = "dev",
                onSettingsChange: @escaping (Settings) -> Void = { _ in }) {
        self.backends = backends
        self.settings = settings
        self.sink = sink
        self.replySink = replySink ?? listener
        self.version = version
        self.onSettingsChange = onSettingsChange
        self.publishers = Dictionary(uniqueKeysWithValues: FeedbackFormat.allCases.map { ($0, FeedbackPublisher(prefix: $0.prefix)) })
    }

    public func capabilities(of kind: BackendKind?) -> Set<Capability> {
        backends.first { $0.kind == kind }?.capabilities ?? []
    }

    // MARK: Lifecycle

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        let (stream, continuation) = AsyncStream<(Command, UDPPeer?)>.makeStream()
        commandContinuation = continuation
        tasks.append(Task { [weak self] in
            for await (command, peer) in stream {
                await self?.execute(command, from: peer)
            }
        })
        tasks.append(Task { [weak self] in
            while let self, self.isRunning {
                await self.pollOnce()
                try? await Task.sleep(for: self.currentInterval)
            }
        })
        startListening()
        for format in FeedbackFormat.allCases {
            sendFeedback([publishers[format]!.startupEvent(version: version)], format: format)
        }
    }

    public func stop() {
        isRunning = false
        listener.stop()
        commandContinuation?.finish()
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    private func startListening() {
        do {
            try listener.start(port: settings.listenPort, localOnly: settings.localOnly) { [weak self] data, peer in
                Task { @MainActor in self?.receive(data, from: peer) }
            }
            listenError = nil
            record("Listening on \(settings.localOnly ? "127.0.0.1" : "all interfaces"), port \(settings.listenPort)")
        } catch {
            listenError = "\(error)"
            record("Can't listen: \(error)", error: true)
        }
    }

    public func update(_ change: (inout Settings) -> Void) {
        var new = settings
        change(&new)
        guard new != settings else { return }
        let old = settings
        settings = new
        onSettingsChange(new)
        if isRunning && (old.listenPort != new.listenPort || old.localOnly != new.localOnly) {
            startListening()
        }
        if old.feedbackHost != new.feedbackHost || old.feedbackPort != new.feedbackPort || old.fileAccessEnabled != new.fileAccessEnabled
            || old.activeFolder != new.activeFolder || old.feedbackFormat != new.feedbackFormat
            || (!old.feedbacksEnabled && new.feedbacksEnabled) {
            invalidateFeedback()
            requestPoll()
        }
    }

    // MARK: Receiving

    /// Entry point for raw datagrams (also used by tests).
    public func receive(_ data: Data, from peer: UDPPeer?) {
        let packet: OSCPacket
        do {
            packet = try OSCDecoder.decode(data)
        } catch {
            record("Ignored malformed packet from \(peer?.host ?? "?"): \(error)", error: true)
            return
        }
        if let peer {
            noteController(peer, keypoint: packet.messages.contains { $0.address.hasPrefix(Router.keypointPrefix + "/") })
        }
        for message in packet.messages {
            guard let command = Router.route(message) else {
                record("Unknown address \(message.address)", error: true)
                continue
            }
            if !settings.actionsEnabled, command != .setActionsEnabled(true) {
                continue
            }
            // Checked on arrival, so a command can't slip through if the setting changes while it's queued.
            if command.needsFileAccess && !settings.fileAccessEnabled {
                record("Blocked \(message.address): file access is off (enable it in the menu on this Mac)", error: true)
                continue
            }
            commandContinuation?.yield((command, peer))
        }
    }

    // MARK: Commands

    private func execute(_ command: Command, from peer: UDPPeer?) async {
        switch command {
        case .setActionsEnabled(let on):
            update { $0.actionsEnabled = on }
        case .setFeedbacksEnabled(let on):
            update { $0.feedbacksEnabled = on }
            if on { invalidateFeedback(); requestPoll() }
        case .refreshFeedbacks:
            invalidateFeedback()
            requestPoll()
        case .filesSetPath(let path):
            setActiveFolder(path)
        case .filesList:
            sendFileList()
        case .filesOpen(let name):
            await openFile(named: name)
        case .filesClose(let name, let mode):
            await perform(.closePresentation(name: name, mode: mode))
        case .ping:
            if let peer {
                send([OSCMessage(Router.keypointPrefix + "/pong", [.string(version)])],
                     to: [FeedbackTarget(host: peer.host, port: peer.port, viaListener: true)])
            }
        case .selectApp(let mode):
            update { $0.backendMode = mode }
            requestPoll()
        case .slide(let action):
            await perform(action)
        }
    }

    private func perform(_ action: SlideAction, on chosen: (any SlideBackend)? = nil) async {
        guard let backend = chosen ?? selectBackend() else {
            record("\(action): no presentation app is running", error: true)
            return
        }
        guard backend.capabilities.contains(action.requiredCapability) else {
            record("\(action): not supported by \(backend.kind.appName)", error: true)
            return
        }
        let options = BackendOptions(uiScriptingAllowed: settings.uiScriptingEnabled,
                                     activatingAppAllowed: settings.allowActivatingApp)
        do {
            try await backend.perform(action, options: options)
            lastError = nil
        } catch let error as BackendError {
            lastError = error
            record("\(action): \(error)", error: true)
        } catch {
            record("\(action): \(error)", error: true)
        }
        await pollOnce()
    }

    // MARK: Files

    /// Folder names from OSC are relative to home. Reject anything that could escape it.
    static func sanitizedFolder(_ raw: String) -> String? {
        let parts = raw.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." || $0.hasPrefix("~") }) else { return nil }
        return parts.joined(separator: "/")
    }

    static let presentationExtensions: [String: BackendKind] = ["pptx": .powerpoint, "ppt": .powerpoint, "key": .keynote]

    private func setActiveFolder(_ raw: String) {
        guard let folder = Self.sanitizedFolder(raw) else {
            record("files/setpath: rejected path \(raw)", error: true)
            return
        }
        update { $0.activeFolder = folder }
        try? FileManager.default.createDirectory(at: settings.activeFolderURL, withIntermediateDirectories: true)
        sendFileList()
    }

    private func presentationFiles() -> [URL] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey, .creationDateKey, .isWritableKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: settings.activeFolderURL, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.filter { Self.presentationExtensions[$0.pathExtension.lowercased()] != nil }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func sendFileList() {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
        func date(_ d: Date?) -> JSONValue { d.map { .string(formatter.string(from: $0)) } ?? .null }
        let items: [JSONValue] = presentationFiles().map { url in
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey,
                                                      .creationDateKey, .isWritableKey])
            return .object([
                ("name", .string(url.lastPathComponent)),
                ("fullName", .string(url.path)),
                ("extension", .string("." + url.pathExtension)),
                ("length", .int(v?.fileSize ?? 0)),
                ("lastAccessTime", date(v?.contentAccessDate)),
                ("lastWriteTime", date(v?.contentModificationDate)),
                ("creationTime", date(v?.creationDate)),
                ("isReadOnly", .bool(!(v?.isWritable ?? true))),
            ])
        }
        let json = JSONValue.array(items).serialized(asciiOnly: true)
        for format in FeedbackFormat.allCases {
            sendFeedback([OSCMessage(format.prefix + "/v2/files", [.string(json)])], format: format)
        }
    }

    private func openFile(named name: String) async {
        guard !name.contains("/"), !name.contains("\\"), !name.hasPrefix(".") else {
            record("files/open: rejected name \(name)", error: true)
            return
        }
        let url = settings.activeFolderURL.appendingPathComponent(name)
        guard let kind = Self.presentationExtensions[url.pathExtension.lowercased()],
              FileManager.default.fileExists(atPath: url.path) else {
            record("files/open: \(name) not found in \(settings.activeFolder)", error: true)
            return
        }
        guard let backend = backends.first(where: { $0.kind == kind }) else {
            record("files/open: no backend for .\(url.pathExtension)", error: true)
            return
        }
        await perform(.openFile(url), on: backend)
    }

    // MARK: Backend selection

    private func backend(_ kind: BackendKind) -> (any SlideBackend)? {
        backends.first { $0.kind == kind }
    }

    /// Manual mode uses the chosen app. Auto mode prefers an app with a show running,
    /// then the current choice if it's still open, then the most recently active app.
    func selectBackend() -> (any SlideBackend)? {
        switch settings.backendMode {
        case .powerpoint: return backend(.powerpoint)
        case .keynote: return backend(.keynote)
        case .auto: break
        }
        let running = backends.filter { $0.isAppRunning() }
        let withShow = running.filter { snapshots[$0.kind]?.show != nil }
        if let current = withShow.first(where: { $0.kind == activeBackend }) ?? withShow.first {
            return current
        }
        if let current = running.first(where: { $0.kind == activeBackend }) {
            return current
        }
        return running.max { ($0.lastActivated() ?? .distantPast) < ($1.lastActivated() ?? .distantPast) }
    }

    // MARK: Polling

    private var currentInterval: Duration {
        if snapshot.show != nil { return showInterval }
        return activeBackend == nil ? absentInterval : idleInterval
    }

    public func requestPoll() {
        Task { await pollOnce() }
    }

    func pollOnce() async {
        if pollInFlight {
            pollAgain = true
            return
        }
        pollInFlight = true
        defer { pollInFlight = false }
        repeat {
            pollAgain = false
            await pollBackgroundBackends()
            let chosen = selectBackend()
            if chosen?.kind != activeBackend {
                activeBackend = chosen?.kind
                record("Using \(chosen?.kind.appName ?? "no app")")
            }
            snapshot = await poll(chosen)
            if settings.feedbacksEnabled {
                var context = FeedbackContext(capabilities: chosen?.capabilities ?? [])
                context.filesEnabled = settings.fileAccessEnabled
                context.activeFolder = settings.activeFolder
                context.activeFolderFullPath = settings.activeFolderURL.path
                context.app = chosen?.kind
                for format in FeedbackFormat.allCases {
                    let publisher = publishers[format]!
                    let targets = feedbackTargets(for: format)
                    guard !targets.isEmpty else {
                        publisher.invalidate() // whoever appears next gets the full state
                        continue
                    }
                    send(publisher.update(snapshot, context: context), to: targets)
                }
            }
        } while pollAgain
    }

    /// In auto mode, check the other running apps occasionally so a show starting there is noticed.
    private func pollBackgroundBackends() async {
        guard settings.backendMode == .auto else { return }
        for backend in backends where backend.kind != activeBackend {
            guard backend.isAppRunning() else {
                snapshots[backend.kind] = nil
                continue
            }
            if let last = lastPolled[backend.kind], Date().timeIntervalSince(last) < backgroundCheckInterval { continue }
            _ = await poll(backend)
        }
    }

    private func poll(_ backend: (any SlideBackend)?) async -> BackendSnapshot {
        guard let backend, backend.isAppRunning() else { return .empty }
        lastPolled[backend.kind] = Date()
        do {
            let snap = try await backend.poll()
            snapshots[backend.kind] = snap
            if lastError == .notAuthorized { lastError = nil }
            return snap
        } catch let error as BackendError {
            if lastError != error { record("\(backend.kind.appName): \(error)", error: true) }
            lastError = error
            // A script error or timeout (e.g. the app showing a dialog) is usually transient:
            // keep reporting the last known state rather than "nothing open".
            if case .script = error, let last = snapshots[backend.kind] { return last }
        } catch {
            record("\(backend.kind.appName): \(error)", error: true)
        }
        snapshots[backend.kind] = nil
        return .empty
    }

    // MARK: Sending

    private func invalidateFeedback() {
        publishers.values.forEach { $0.invalidate() }
    }

    private func noteController(_ peer: UDPPeer, keypoint: Bool) {
        lastController = peer
        if keypoint {
            if keypointSeen[peer] == nil {
                publishers[.keypoint]!.invalidate() // a new controller gets the full state
                record("KeyPoint controller connected: \(peer.host):\(peer.port)")
            }
            keypointSeen[peer] = Date()
            keypointControllers = Array(keypointSeen.keys)
        } else {
            if settings.replyToSender, legacyController?.host != peer.host {
                publishers[settings.feedbackFormat]!.invalidate()
            }
            legacyController = peer
        }
    }

    /// Fixed target and "reply to last controller" use the format chosen in settings;
    /// KeyPoint controllers always get KeyPoint feedback, at the address they sent from.
    func feedbackTargets(for format: FeedbackFormat) -> [FeedbackTarget] {
        var targets: [FeedbackTarget] = []
        if format == settings.feedbackFormat {
            let host = settings.feedbackHost.trimmingCharacters(in: .whitespaces)
            if !host.isEmpty { targets.append(FeedbackTarget(host: host, port: settings.feedbackPort, viaListener: false)) }
            if settings.replyToSender, let peer = legacyController, peer.host != host,
               !(Self.isLoopback(peer.host) && Self.isLoopback(host)) {
                targets.append(FeedbackTarget(host: peer.host, port: settings.feedbackPort, viaListener: false))
            }
        }
        if format == .keypoint {
            let now = Date()
            for (peer, seen) in keypointSeen where now.timeIntervalSince(seen) > controllerTimeout {
                keypointSeen[peer] = nil
                record("KeyPoint controller gone: \(peer.host):\(peer.port)")
            }
            if keypointControllers.count != keypointSeen.count { keypointControllers = Array(keypointSeen.keys) }
            for peer in keypointSeen.keys.sorted(by: { "\($0.host):\($0.port)" < "\($1.host):\($1.port)" })
            where !targets.contains(where: { $0.host == peer.host && $0.port == peer.port }) {
                targets.append(FeedbackTarget(host: peer.host, port: peer.port, viaListener: true))
            }
        }
        return targets
    }

    static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "::1" || host == "localhost"
    }

    private func sendFeedback(_ messages: [OSCMessage], format: FeedbackFormat) {
        send(messages, to: feedbackTargets(for: format))
    }

    private func send(_ messages: [OSCMessage], to targets: [FeedbackTarget]) {
        guard settings.feedbacksEnabled, !messages.isEmpty else { return }
        for message in messages {
            let data = OSCEncoder.encode(message)
            for target in targets {
                do {
                    try (target.viaListener ? replySink : sink).send(data, to: target.host, port: target.port)
                } catch {
                    record("Feedback to \(target.host):\(target.port) failed: \(error)", error: true)
                }
            }
        }
    }

    private static let logger = Logger(subsystem: "org.keypointosc.KeyPointOSC", category: "engine")

    private func record(_ text: String, error: Bool = false) {
        if error {
            Self.logger.error("\(text, privacy: .public)")
        } else {
            Self.logger.notice("\(text, privacy: .public)")
        }
        log.append(LogEntry(text: text, isError: error))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}
