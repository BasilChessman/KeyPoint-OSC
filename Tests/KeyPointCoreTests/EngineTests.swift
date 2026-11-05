import Foundation
import Testing
@testable import KeyPointCore

final class MockBackend: SlideBackend, @unchecked Sendable {
    let kind: BackendKind
    let bundleIdentifier = "test.mock"
    var capabilities: Set<Capability>
    var running = true
    var activated: Date?
    var snapshot = BackendSnapshot.empty
    private(set) var performed: [SlideAction] = []

    init(_ kind: BackendKind = .powerpoint, capabilities: Set<Capability> = Set(Capability.allCases)) {
        self.kind = kind
        self.capabilities = capabilities
    }

    func isAppRunning() -> Bool { running }
    func lastActivated() -> Date? { activated }
    func poll() async throws -> BackendSnapshot { snapshot }
    func perform(_ action: SlideAction, options: BackendOptions) async throws { performed.append(action) }
    private(set) var clicker: [Bool] = []
    func clickerPressed(forward: Bool, at time: Date) async { clicker.append(forward) }
}

final class RecordingSink: FeedbackSink, @unchecked Sendable {
    private(set) var sent: [(host: String, port: UInt16, message: OSCMessage)] = []
    func send(_ data: Data, to host: String, port: UInt16) throws {
        if case .message(let m) = try OSCDecoder.decode(data) { sent.append((host, port, m)) }
    }
    func addresses(to host: String) -> [String] { sent.filter { $0.host == host }.map(\.message.address) }
}

@MainActor @Suite struct EngineTests {
    let backend = MockBackend()
    let sink = RecordingSink()
    let peer = UDPPeer(host: "10.0.0.5", port: 50000)

    func makeEngine(_ change: (inout Settings) -> Void = { _ in }) -> Engine {
        var settings = Settings()
        settings.listenPort = UInt16.random(in: 40000...60000)
        change(&settings)
        return Engine(backends: [backend], settings: settings, sink: sink, replySink: sink)
    }

    func send(_ engine: Engine, _ address: String, _ args: OSCArgument...) async throws {
        engine.receive(OSCEncoder.encode(OSCMessage(address, args)), from: peer)
        try await Task.sleep(for: .milliseconds(50))
    }

    /// Waits for asynchronous command handling instead of guessing a delay.
    func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func routesActionsToBackendInOrder() async throws {
        let engine = makeEngine()
        engine.start()
        defer { engine.stop() }
        let bundle = OSCPacket.bundle(timeTag: 1, elements: [
            .message(OSCMessage("/oscpoint/next")), .message(OSCMessage("/oscpoint/goto/slide", [.int(3)])),
        ])
        engine.receive(OSCEncoder.encode(bundle), from: peer)
        try await send(engine, "/oscpoint/previous")
        try await eventually { backend.performed.count == 3 }
        #expect(backend.performed == [.next, .gotoSlide(3), .previous])
    }

    @Test func fileActionsNeedLocalOptIn() async throws {
        let engine = makeEngine()
        engine.start()
        defer { engine.stop() }
        try await send(engine, "/oscpoint/files/close/force")
        engine.update { $0.fileAccessEnabled = true }
        try await send(engine, "/oscpoint/files/close/force")
        try await eventually { !backend.performed.isEmpty }
        #expect(backend.performed == [.closePresentation(name: nil, mode: .force)])
    }

    @Test func actionsDisableIgnoresAllButEnable() async throws {
        let engine = makeEngine()
        engine.start()
        defer { engine.stop() }
        try await send(engine, "/oscpoint/actions/disable")
        try await eventually { !engine.settings.actionsEnabled }
        try await send(engine, "/oscpoint/next")
        try await send(engine, "/oscpoint/actions/enable")
        try await eventually { engine.settings.actionsEnabled }
        try await send(engine, "/oscpoint/previous")
        try await eventually { !backend.performed.isEmpty }
        #expect(backend.performed == [.previous])
    }

    @Test func unsupportedActionsAreNotSent() async throws {
        backend.capabilities = [.navigate]
        let engine = makeEngine()
        engine.start()
        defer { engine.stop() }
        try await send(engine, "/oscpoint/slideshow/laserpointer")
        try await send(engine, "/oscpoint/next")
        try await eventually { !backend.performed.isEmpty }
        #expect(backend.performed == [.next])
    }

    @Test func feedbackGoesToConfiguredHostAndController() async throws {
        backend.snapshot = BackendSnapshot(presentations: [PresentationInfo(name: "A.pptx", slideCount: 3)], activePresentation: "A.pptx")
        let engine = makeEngine { $0.feedbackHost = "10.0.0.9" }
        engine.start()
        defer { engine.stop() }
        try await send(engine, "/keypoint/feedbacks/refresh")
        try await eventually { sink.addresses(to: "10.0.0.5").contains("/keypoint/presentation/name") }
        #expect(sink.addresses(to: "10.0.0.9").contains("/keypoint/presentation/name"))
        #expect(sink.addresses(to: "10.0.0.5").contains("/keypoint/presentation/name"))
        #expect(sink.addresses(to: "10.0.0.5").contains("/keypoint/app"))
        // The fixed target gets the configured port; a KeyPoint controller is answered at its own port.
        #expect(sink.sent.filter { $0.host == "10.0.0.9" }.allSatisfy { $0.port == 35550 })
        #expect(sink.sent.filter { $0.host == "10.0.0.5" }.allSatisfy { $0.port == 50000 })
    }

    @Test func eachClientGetsItsOwnFormat() async throws {
        backend.snapshot = BackendSnapshot(presentations: [PresentationInfo(name: "A.pptx", slideCount: 3)], activePresentation: "A.pptx")
        // Fixed target (e.g. the Zinc: OSCPoint module) wants OSCPoint format; the KeyPoint module talks /keypoint.
        let engine = makeEngine {
            $0.feedbackHost = "10.0.0.9"
            $0.feedbackFormat = .oscpoint
        }
        engine.start()
        defer { engine.stop() }
        try await send(engine, "/keypoint/ping")
        try await eventually {
            sink.addresses(to: "10.0.0.5").contains("/keypoint/presentation/name")
                && sink.addresses(to: "10.0.0.9").contains("/oscpoint/presentation/name")
        }
        #expect(sink.addresses(to: "10.0.0.5").allSatisfy { $0.hasPrefix("/keypoint/") })
        #expect(sink.addresses(to: "10.0.0.9").allSatisfy { $0.hasPrefix("/oscpoint/") })
        #expect(engine.keypointControllers == [peer])
    }

    @Test func silentKeypointControllersAreForgotten() async throws {
        let engine = makeEngine()
        engine.controllerTimeout = 0.3
        try await send(engine, "/keypoint/ping")
        #expect(engine.feedbackTargets(for: .keypoint).contains { $0.host == "10.0.0.5" && $0.port == 50000 })
        try await Task.sleep(for: .milliseconds(400))
        #expect(!engine.feedbackTargets(for: .keypoint).contains { $0.host == "10.0.0.5" })
    }

    @Test func oscpointFormatForCompatibleClients() async throws {
        backend.snapshot = BackendSnapshot(presentations: [PresentationInfo(name: "A.pptx", slideCount: 3)], activePresentation: "A.pptx")
        let engine = makeEngine { $0.feedbackFormat = .oscpoint }
        engine.start()
        defer { engine.stop() }
        try await send(engine, "/oscpoint/feedbacks/refresh")
        try await eventually { sink.addresses(to: "10.0.0.5").contains("/oscpoint/presentation/name") }
        let addresses = sink.addresses(to: "10.0.0.5")
        #expect(addresses.allSatisfy { $0.hasPrefix("/oscpoint/") })
        #expect(!addresses.contains("/oscpoint/app")) // KeyPoint-only values aren't sent in OSCPoint format
    }

    @Test func pingAndAppSelect() async throws {
        let engine = Engine(backends: [backend], settings: Settings(), sink: sink, replySink: sink, version: "KeyPoint OSC 9.9")
        engine.start()
        defer { engine.stop() }
        try await send(engine, "/keypoint/ping")
        try await eventually { sink.addresses(to: "10.0.0.5").contains("/keypoint/pong") }
        #expect(sink.sent.first { $0.message.address == "/keypoint/pong" }?.message.arguments == [.string("KeyPoint OSC 9.9")])
        try await send(engine, "/keypoint/app/select", .string("Keynote"))
        try await eventually { engine.settings.backendMode == .keynote }
        #expect(engine.settings.backendMode == .keynote)
    }

    @Test func noFeedbackWhenDisabled() async throws {
        let engine = makeEngine { $0.feedbacksEnabled = false }
        engine.start()
        defer { engine.stop() }
        try await send(engine, "/oscpoint/feedbacks/refresh")
        #expect(sink.sent.isEmpty)
    }

    @Test func autoSelectionPrefersRunningShow() async throws {
        let keynote = MockBackend(.keynote)
        keynote.activated = Date()
        backend.activated = .distantPast
        let engine = Engine(backends: [backend, keynote], settings: Settings(), sink: sink, replySink: sink)
        await engine.pollOnce()
        #expect(engine.activeBackend == .keynote) // most recently active

        backend.snapshot = BackendSnapshot(presentations: [PresentationInfo(name: "A", slideCount: 1)], activePresentation: "A",
                                           show: ShowInfo(presentationName: "A", currentSlide: 1))
        engine.backgroundCheckInterval = 0
        await engine.pollOnce()
        await engine.pollOnce()
        #expect(engine.activeBackend == .powerpoint) // has a show

        backend.running = false
        await engine.pollOnce()
        #expect(engine.activeBackend == .keynote)
    }

    @Test func folderSanitizing() {
        #expect(Engine.sanitizedFolder("Desktop\\shows\\today") == "Desktop/shows/today")
        #expect(Engine.sanitizedFolder("/Desktop/shows/") == "Desktop/shows")
        #expect(Engine.sanitizedFolder("../etc") == nil)
        #expect(Engine.sanitizedFolder("Desktop/../../x") == nil)
        #expect(Engine.sanitizedFolder("~root") == nil)
        #expect(Engine.sanitizedFolder("") == nil)
    }

    @Test func malformedPacketsAreIgnored() {
        let engine = makeEngine()
        engine.receive(Data([1, 2, 3]), from: peer)
        #expect(engine.log.last?.isError == true)
    }
}

@Suite struct UDPTests {
    @Test func loopbackRoundTrip() async throws {
        let listener = UDPListener()
        let port = UInt16.random(in: 40000...60000)
        let received = AsyncStream<(Data, UDPPeer)>.makeStream()
        try listener.start(port: port, localOnly: true) { data, peer in received.continuation.yield((data, peer)) }
        defer { listener.stop() }
        let big = OSCEncoder.encode(OSCMessage("/big", [.blob(Data(repeating: 7, count: 40_000))]))
        try UDPSender().send(big, to: "127.0.0.1", port: port)
        var iterator = received.stream.makeAsyncIterator()
        let (data, peer) = try #require(await iterator.next())
        #expect(data == big)
        #expect(peer.host == "127.0.0.1")
    }
}

@MainActor @Suite struct PerfectCueEngineTests {
    let backend = MockBackend(.keynote)
    let sink = RecordingSink()

    func makeEngine(enabled: Bool) -> Engine {
        var settings = Settings()
        settings.listenPort = UInt16.random(in: 40000...60000)
        settings.perfectCueEnabled = enabled
        settings.perfectCueHost = "127.0.0.1"
        settings.perfectCuePort = 9 // nothing listens: the client just retries
        return Engine(backends: [backend], settings: settings, sink: sink, replySink: sink)
    }

    @Test func pressesReachTheBackendOnlyWhenEnabled() async {
        let off = makeEngine(enabled: false)
        await off.perfectCuePressed(.forward, at: Date())
        #expect(backend.clicker.isEmpty)
        let on = makeEngine(enabled: true)
        await on.perfectCuePressed(.forward, at: Date())
        await on.perfectCuePressed(.back, at: Date())
        await on.perfectCuePressed(.blankOn, at: Date()) // not a step in the show
        #expect(backend.clicker == [true, false])
    }

    @Test func switchedOverOSC() async throws {
        let engine = makeEngine(enabled: false)
        engine.start()
        defer { engine.stop() }
        let peer = UDPPeer(host: "10.0.0.5", port: 50000)
        engine.receive(OSCEncoder.encode(OSCMessage("/keypoint/perfectcue/enable", [.string("bridge.local"), .int(5101)])), from: peer)
        for _ in 0..<200 where !engine.settings.perfectCueEnabled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.settings.perfectCueEnabled && engine.settings.perfectCueHost == "bridge.local" && engine.settings.perfectCuePort == 5101)
        #expect(engine.perfectCueStatus.contains("bridge.local:5101"))
        engine.receive(OSCEncoder.encode(OSCMessage("/keypoint/perfectcue/disable", [])), from: peer)
        for _ in 0..<200 where engine.settings.perfectCueEnabled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!engine.settings.perfectCueEnabled && engine.perfectCueStatus.isEmpty)
        // Feedback reports the switch to KeyPoint controllers.
        try await Task.sleep(for: .milliseconds(100))
        let enabled = sink.sent.filter { $0.message.address == "/keypoint/perfectcue/enabled" }.map(\.message.arguments)
        #expect(enabled.contains([.bool(true)]) && enabled.last == [.bool(false)])
    }
}

@Suite struct PerfectCueProtocolTests {
    @Test func checksums() {
        // From DSAN's touch panel document and the bridge firmware.
        #expect(PerfectCueProtocol.message("FRWLEDON") == ">FRWLEDON 81\r")
        #expect(PerfectCueProtocol.checksum("RVSLEDOF") == "85")
        #expect(PerfectCueProtocol.checksum("FORWARD") == "35")
    }

    @Test func events() {
        #expect(PerfectCueProtocol.event(fromLine: ">FRWLEDON 81") == .forward)
        #expect(PerfectCueProtocol.event(fromLine: ">RVSLEDON 8D\r") == .back)
        #expect(PerfectCueProtocol.event(fromLine: ">BLKLEDON 6b") == .blankOn)
        #expect(PerfectCueProtocol.event(fromLine: ">BLKLEDOF 63") == .blankOff)
        #expect(PerfectCueProtocol.event(fromLine: ">FRWLEDOF 79") == nil) // the light going off isn't a press
        #expect(PerfectCueProtocol.event(fromLine: ">FRWLEDON 80") == nil) // bad checksum
        #expect(PerfectCueProtocol.event(fromLine: "FRWLEDON 81") == nil)
    }

    @Test func splitsStreamIntoLines() {
        var buffer = Data()
        #expect(PerfectCueProtocol.lines(appending: Data(">FRWLEDON 81\r>FRWL".utf8), to: &buffer) == [">FRWLEDON 81"])
        #expect(PerfectCueProtocol.lines(appending: Data("EDOF 79\r\n".utf8), to: &buffer) == [">FRWLEDOF 79"])
        #expect(buffer.isEmpty)
    }

    @Test func routes() {
        func route(_ address: String, _ args: OSCArgument...) -> Command? { Router.route(OSCMessage(address, args)) }
        #expect(route("/keypoint/perfectcue/enable") == .setPerfectCue(enabled: true))
        #expect(route("/keypoint/perfectcue/enable", .string("192.168.0.169")) == .setPerfectCue(enabled: true, host: "192.168.0.169"))
        #expect(route("/keypoint/perfectcue/enable", .string("perfectcue.local"), .string("5100"))
            == .setPerfectCue(enabled: true, host: "perfectcue.local", port: 5100))
        #expect(route("/keypoint/perfectcue/enable", .string(""), .int(5200)) == .setPerfectCue(enabled: true, port: 5200))
        #expect(route("/keypoint/perfectcue/enable", .string("bad host/x")) == nil)
        #expect(route("/keypoint/perfectcue/enable", .int(70000)) == nil)
        #expect(route("/keypoint/perfectcue/disable") == .setPerfectCue(enabled: false))
        #expect(route("/oscpoint/perfectcue/enable") == nil) // KeyPoint-only
    }

    @Test func oldSettingsDecode() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"listenPort": 36000}"#.utf8))
        #expect(s.listenPort == 36000 && !s.perfectCueEnabled && s.perfectCueHost == "perfectcue.local" && s.perfectCuePort == 5100)
    }
}
