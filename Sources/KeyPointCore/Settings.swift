import Foundation

public enum BackendMode: String, Codable, Sendable, CaseIterable {
    case auto
    case powerpoint
    case keynote
}

/// Which address prefix feedback is sent under.
public enum FeedbackFormat: String, Codable, Sendable, CaseIterable {
    /// `/keypoint/...`, plus KeyPoint-only values (active app, black/white, capabilities).
    case keypoint
    /// `/oscpoint/...`, for OSCPoint-compatible clients such as the Zinc: OSCPoint module.
    case oscpoint

    public var prefix: String { self == .keypoint ? Router.keypointPrefix : Router.oscpointPrefix }
}

public struct Settings: Codable, Equatable, Sendable {
    public var actionsEnabled = true
    public var feedbacksEnabled = true
    /// Port for incoming actions (OSCPoint default 35551).
    public var listenPort: UInt16 = 35551
    /// Listen on loopback only. Off by default because Companion usually runs on another machine.
    public var localOnly = false
    /// Where feedback goes (OSCPoint default 127.0.0.1:35550).
    public var feedbackHost = "127.0.0.1"
    public var feedbackPort: UInt16 = 35550
    /// Also send feedback to the host of whoever last sent us an action, at `feedbackPort`.
    public var replyToSender = true
    public var backendMode = BackendMode.auto
    /// Local-only opt-in for files/* actions. Never settable over OSC.
    public var fileAccessEnabled = false
    /// Active folder for files/* actions, relative to the home directory.
    public var activeFolder = "Desktop/KeyPoint OSC"
    /// Allow features that need Accessibility (keystrokes, menu clicks).
    public var uiScriptingEnabled = true
    /// Allow bringing the presentation app to the front when an action needs it.
    public var allowActivatingApp = true
    public var feedbackFormat = FeedbackFormat.keypoint

    public init() {}

    public static let portRange: ClosedRange<UInt16> = 1024...65535

    public var activeFolderURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(activeFolder, isDirectory: true)
    }

    // Decode field by field so settings saved by an older version keep working.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        actionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .actionsEnabled) ?? d.actionsEnabled
        feedbacksEnabled = try c.decodeIfPresent(Bool.self, forKey: .feedbacksEnabled) ?? d.feedbacksEnabled
        listenPort = try c.decodeIfPresent(UInt16.self, forKey: .listenPort) ?? d.listenPort
        localOnly = try c.decodeIfPresent(Bool.self, forKey: .localOnly) ?? d.localOnly
        feedbackHost = try c.decodeIfPresent(String.self, forKey: .feedbackHost) ?? d.feedbackHost
        feedbackPort = try c.decodeIfPresent(UInt16.self, forKey: .feedbackPort) ?? d.feedbackPort
        replyToSender = try c.decodeIfPresent(Bool.self, forKey: .replyToSender) ?? d.replyToSender
        backendMode = try c.decodeIfPresent(BackendMode.self, forKey: .backendMode) ?? d.backendMode
        fileAccessEnabled = try c.decodeIfPresent(Bool.self, forKey: .fileAccessEnabled) ?? d.fileAccessEnabled
        activeFolder = try c.decodeIfPresent(String.self, forKey: .activeFolder) ?? d.activeFolder
        uiScriptingEnabled = try c.decodeIfPresent(Bool.self, forKey: .uiScriptingEnabled) ?? d.uiScriptingEnabled
        allowActivatingApp = try c.decodeIfPresent(Bool.self, forKey: .allowActivatingApp) ?? d.allowActivatingApp
        feedbackFormat = try c.decodeIfPresent(FeedbackFormat.self, forKey: .feedbackFormat) ?? d.feedbackFormat
    }
}

public enum SettingsStore {
    static let key = "settings.v1"

    public static func load(from defaults: UserDefaults = .standard) -> Settings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return settings
    }

    public static func save(_ settings: Settings, to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}
