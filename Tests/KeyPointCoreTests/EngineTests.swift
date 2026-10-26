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
