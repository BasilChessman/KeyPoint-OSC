import AppKit
import CoreGraphics
import KeyPointCore

/// Watches key presses with a listen-only CGEvent tap, for clickers that act as a keyboard.
/// It never blocks, changes or records keys: it only matches them against the clicker keys and
/// reports which app they went to. Needs Input Monitoring permission (System Settings >
/// Privacy & Security > Input Monitoring).
@MainActor
public final class KeyboardClickerMonitor: KeyboardClickerMonitoring {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var forward: [KeyChord] = []
    private var back: [KeyChord] = []
    private var onPress: (@MainActor (Bool, Date, String?) -> Void)?
    private var learnHandler: (@MainActor (KeyChord?) -> Void)?
    private var learnTimeout: Task<Void, Never>?

    public init() {}

    public var hasPermission: Bool { CGPreflightListenEventAccess() }

    public func requestPermission() {
        if !CGRequestListenEventAccess() {
            // Already asked once: macOS won't prompt again, so open the settings pane.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    public func start(forward: [KeyChord], back: [KeyChord], onPress: @escaping @MainActor (Bool, Date, String?) -> Void) -> Bool {
        self.forward = forward
        self.back = back
        self.onPress = onPress
        return ensureTap()
    }

    public func stop() {
        onPress = nil
        removeTapIfIdle()
    }

    public func learn(_ handler: @escaping @MainActor (KeyChord?) -> Void) -> Bool {
        learnHandler = handler
        guard ensureTap() else {
            learnHandler = nil
            return false
        }
        learnTimeout?.cancel()
        learnTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.finishLearning(nil)
        }
        return true
    }

    public func cancelLearning() {
        learnTimeout?.cancel()
        learnHandler = nil
        removeTapIfIdle()
    }

    // MARK: Tap

    private func ensureTap() -> Bool {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return true
        }
        guard hasPermission else { return false }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                let me = Unmanaged<KeyboardClickerMonitor>.fromOpaque(refcon).takeUnretainedValue()
                // Event taps on the main run loop are called on the main thread.
                MainActor.assumeIsolated { me.handle(type, event) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    private func removeTapIfIdle() {
        guard onPress == nil, learnHandler == nil, let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        case .keyDown:
            break
        default:
            return
        }
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return } // a held key
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let held = Self.modifiers(event.flags)
        if learnHandler != nil {
            if code == 53, held.isEmpty { // Esc
                finishLearning(nil)
            } else {
                let characters = NSEvent(cgEvent: event)?.charactersIgnoringModifiers
                finishLearning(KeyChord(keyCode: code, modifiers: held,
                                        label: KeyChord.label(keyCode: code, modifiers: held, characters: characters)))
            }
            return
        }
        guard let onPress else { return }
        let isForward = forward.contains { $0.matches(keyCode: code, modifiers: held) }
        let isBack = !isForward && back.contains { $0.matches(keyCode: code, modifiers: held) }
        guard isForward || isBack else { return }
        let pid = pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventTargetUnixProcessID))
        let app = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        onPress(isForward, Date(), app)
    }

    private func finishLearning(_ chord: KeyChord?) {
        learnTimeout?.cancel()
        let handler = learnHandler
        learnHandler = nil
        removeTapIfIdle()
        handler?(chord)
    }

    static func modifiers(_ flags: CGEventFlags) -> KeyChord.Modifiers {
        var m: KeyChord.Modifiers = []
        if flags.contains(.maskShift) { m.insert(.shift) }
        if flags.contains(.maskControl) { m.insert(.control) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskCommand) { m.insert(.command) }
        return m
    }
}
