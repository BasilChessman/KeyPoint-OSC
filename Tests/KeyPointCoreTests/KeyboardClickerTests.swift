import Foundation
import Testing
@testable import KeyPointCore

@MainActor
final class FakeKeyboard: KeyboardClickerMonitoring {
    var hasPermission = true
    var started: (forward: [KeyChord], back: [KeyChord])?
    var onPress: (@MainActor (Bool, Date, String?) -> Void)?
    var learner: (@MainActor (KeyChord?) -> Void)?
    var permissionRequests = 0
    func requestPermission() { permissionRequests += 1 }
    func start(forward: [KeyChord], back: [KeyChord], onPress: @escaping @MainActor (Bool, Date, String?) -> Void) -> Bool {
        started = (forward, back)
        self.onPress = onPress
        return true
    }
    func stop() { started = nil; onPress = nil }
    func learn(_ handler: @escaping @MainActor (KeyChord?) -> Void) -> Bool { learner = handler; return true }
    func cancelLearning() { learner = nil }
}

@Suite struct KeyChordTests {
    @Test func matching() {
        let pageDown = KeyChord(keyCode: 121, label: "Page Down")
        #expect(pageDown.matches(keyCode: 121, modifiers: []))
        #expect(pageDown.matches(keyCode: 121, modifiers: .shift)) // Keynote: Shift skips builds
        #expect(!pageDown.matches(keyCode: 121, modifiers: .command))
        #expect(!pageDown.matches(keyCode: 116, modifiers: []))
        let shiftB = KeyChord(keyCode: 11, modifiers: .shift, label: "⇧B")
        #expect(shiftB.matches(keyCode: 11, modifiers: .shift) && !shiftB.matches(keyCode: 11, modifiers: []))
    }

    @Test func labelsAndIdentity() {
        #expect(KeyChord.label(keyCode: 121, modifiers: [], characters: nil) == "Page Down")
        #expect(KeyChord.label(keyCode: 11, modifiers: [.shift, .command], characters: "b") == "⇧⌘B")
        #expect(KeyChord.label(keyCode: 200, modifiers: [], characters: "") == "Key 200")
        #expect(KeyChord(keyCode: 5, label: "G") == KeyChord(keyCode: 5, label: "other label"))
        #expect(KeyChord.defaultForward.map(\.label) == ["Page Down", "→", "↓", "Space", "Return"])
        #expect(KeyChord.defaultBack.map(\.label) == ["Page Up", "←", "↑", "Delete"])
    }

    @Test func settingsRoundTrip() throws {
        var s = Settings()
        s.keyboardClickerEnabled = true
        s.clickerForwardKeys = [KeyChord(keyCode: 96, label: "F5")]
        let back = try JSONDecoder().decode(Settings.self, from: try JSONEncoder().encode(s))
        #expect(back.keyboardClickerEnabled && back.clickerForwardKeys.map(\.label) == ["F5"] && back.clickerBackKeys == KeyChord.defaultBack)
        let old = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(!old.keyboardClickerEnabled && old.clickerForwardKeys == KeyChord.defaultForward)
    }

    @Test func routes() {
        #expect(Router.route(OSCMessage("/keypoint/keyboard/enable", [])) == .setKeyboardClicker(true))
        #expect(Router.route(OSCMessage("/keypoint/keyboard/disable", [])) == .setKeyboardClicker(false))
        #expect(Router.route(OSCMessage("/oscpoint/keyboard/enable", [])) == nil)
    }
}

@MainActor @Suite struct KeyboardClickerEngineTests {
    let backend = MockBackend(.keynote)
    let sink = RecordingSink()
    let keyboard = FakeKeyboard()

    func makeEngine(enabled: Bool) -> Engine {
        var settings = Settings()
        settings.listenPort = UInt16.random(in: 40000...60000)
        settings.keyboardClickerEnabled = enabled
        return Engine(backends: [backend], settings: settings, sink: sink, replySink: sink, keyboard: keyboard)
    }

    @Test func startsOnlyWithPermission() async {
        keyboard.hasPermission = false
        let engine = makeEngine(enabled: true)
        engine.start()
        defer { engine.stop() }
        #expect(keyboard.started == nil && !engine.keyboardListening && engine.keyboardStatus.contains("Input Monitoring"))
        keyboard.hasPermission = true // granted in System Settings: the next poll starts listening
        await engine.pollOnce()
        #expect(keyboard.started != nil && engine.keyboardListening)
    }

    @Test func countsKeysThatWentToTheControlledApp() async throws {
        let engine = makeEngine(enabled: true)
        engine.start()
        defer { engine.stop() }
        #expect(keyboard.started?.forward == KeyChord.defaultForward && engine.keyboardListening)
        await engine.keyPressed(forward: true, at: Date(), app: "test.mock")
        await engine.keyPressed(forward: true, at: Date(), app: "com.apple.TextEdit") // typing elsewhere
        await engine.keyPressed(forward: false, at: Date(), app: "test.mock")
        #expect(backend.clicker == [true, false] && backend.clickSources == [.keyboard, .keyboard])
        engine.update { $0.keyboardClickerEnabled = false }
        #expect(keyboard.started == nil)
        await engine.keyPressed(forward: true, at: Date(), app: "test.mock")
        #expect(backend.clicker.count == 2)
    }

    @Test func learnsKeys() async throws {
        let engine = makeEngine(enabled: true)
        engine.start()
        defer { engine.stop() }
        let f5 = KeyChord(keyCode: 96, label: "F5")
        engine.learnClickerKey(forward: true)
        #expect(engine.learningClickerKey == true)
        // A key pressed while learning isn't a step.
        await engine.keyPressed(forward: true, at: Date(), app: "test.mock")
        #expect(backend.clicker.isEmpty)
        keyboard.learner?(f5)
        #expect(engine.learningClickerKey == nil && engine.settings.clickerForwardKeys.last == f5)
        #expect(keyboard.started?.forward.last == f5) // listening with the new key
        // Learning Page Down as Back moves it from Forward.
        engine.learnClickerKey(forward: false)
        keyboard.learner?(KeyChord(keyCode: 121, label: "Page Down"))
        #expect(!engine.settings.clickerForwardKeys.contains { $0.keyCode == 121 })
        #expect(engine.settings.clickerBackKeys.last?.keyCode == 121)
        // Esc: nothing learned.
        engine.learnClickerKey(forward: true)
        keyboard.learner?(nil)
        #expect(engine.learningClickerKey == nil && engine.settings.clickerForwardKeys.last == f5)
        engine.removeClickerKey(f5)
        #expect(!engine.settings.clickerForwardKeys.contains(f5))
        engine.resetClickerKeys()
        #expect(engine.settings.clickerForwardKeys == KeyChord.defaultForward && engine.settings.clickerBackKeys == KeyChord.defaultBack)
    }

    @Test func learningWithoutPermissionAsksForIt() {
        keyboard.hasPermission = false
        let engine = makeEngine(enabled: true)
        engine.learnClickerKey(forward: true)
        #expect(engine.learningClickerKey == nil && keyboard.permissionRequests == 1)
    }

    @Test func switchedOverOSCWithFeedback() async throws {
        let engine = makeEngine(enabled: false)
        engine.start()
        defer { engine.stop() }
        let peer = UDPPeer(host: "10.0.0.5", port: 50000)
        engine.receive(OSCEncoder.encode(OSCMessage("/keypoint/keyboard/enable", [])), from: peer)
        for _ in 0..<200 where !engine.settings.keyboardClickerEnabled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.keyboardListening)
        try await Task.sleep(for: .milliseconds(100))
        let enabled = sink.sent.filter { $0.message.address == "/keypoint/keyboard/enabled" }.map(\.message.arguments)
        #expect(enabled.last == [.bool(true)])
        #expect(sink.sent.contains { $0.message.address == "/keypoint/keyboard/permission" && $0.message.arguments == [.bool(true)] })
    }
}
