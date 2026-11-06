import Foundation

/// Where a clicker press KeyPoint didn't send itself was noticed.
public enum ClickSource: Sendable, Equatable {
    /// A PerfectCue bridge on the network.
    case bridge
    /// A key press on this Mac (a USB or Bluetooth clicker acting as a keyboard).
    case keyboard
}

/// A key a clicker sends: a macOS virtual key code plus modifiers.
public struct KeyChord: Codable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    public var keyCode: UInt16
    public var modifiers: Modifiers
    /// What to show in the menu, e.g. "Page Down" or "⇧B".
    public var label: String

    public init(keyCode: UInt16, modifiers: Modifiers = [], label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    /// Same key. A plain key also matches with Shift held: Keynote uses Shift with the
    /// navigation keys to skip builds, which KeyPoint still notices as a step.
    public func matches(keyCode code: UInt16, modifiers held: Modifiers) -> Bool {
        guard code == keyCode else { return false }
        return held == modifiers || (modifiers.isEmpty && held == .shift)
    }

    // Identity is the key, not the label.
    public static func == (a: KeyChord, b: KeyChord) -> Bool { a.keyCode == b.keyCode && a.modifiers == b.modifiers }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers)
    }

    /// Names for keys clickers commonly send.
    public static let names: [UInt16: String] = [
        121: "Page Down", 116: "Page Up", 124: "→", 123: "←", 125: "↓", 126: "↑",
        49: "Space", 36: "Return", 76: "Enter", 51: "Delete", 117: "Forward Delete", 53: "Esc", 48: "Tab",
        115: "Home", 119: "End", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 122: "F1", 120: "F2", 118: "F4",
    ]

    /// The keys Keynote itself advances and goes back with, which most clickers send.
    public static let defaultForward: [KeyChord] = [121, 124, 125, 49, 36].map { KeyChord(keyCode: $0, label: names[$0]!) }
    public static let defaultBack: [KeyChord] = [116, 123, 126, 51].map { KeyChord(keyCode: $0, label: names[$0]!) }

    public static func label(keyCode: UInt16, modifiers: Modifiers, characters: String?) -> String {
        var prefix = ""
        if modifiers.contains(.control) { prefix += "⌃" }
        if modifiers.contains(.option) { prefix += "⌥" }
        if modifiers.contains(.shift) { prefix += "⇧" }
        if modifiers.contains(.command) { prefix += "⌘" }
        let base = names[keyCode]
            ?? characters.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.uppercased() }
            ?? "Key \(keyCode)"
        return prefix + base
    }
}

/// Watches the Mac's keyboard for clicker keys. Listen-only: it never blocks or changes a key.
/// Needs Input Monitoring permission. Implemented in KeyPointBackends with a CGEvent tap.
@MainActor
public protocol KeyboardClickerMonitoring: AnyObject {
    var hasPermission: Bool { get }
    /// Shows the system prompt (first time) or nothing; the user grants it in System Settings.
    func requestPermission()
    /// Starts reporting presses of `forward` and `back` keys, with the bundle id of the app the
    /// key went to. Returns false if the tap couldn't be created (usually: no permission).
    func start(forward: [KeyChord], back: [KeyChord], onPress: @escaping @MainActor (Bool, Date, String?) -> Void) -> Bool
    func stop()
    /// Captures the next key press (not reported as a press). Esc cancels with nil.
    func learn(_ handler: @escaping @MainActor (KeyChord?) -> Void) -> Bool
    func cancelLearning()
}
