import Foundation

/// Why a backend call failed, in terms the UI can explain.
public enum BackendError: Error, Equatable, CustomStringConvertible {
    /// The user denied (or hasn't yet granted) Automation permission for the app.
    case notAuthorized
    /// The app isn't running. Backends never launch it as a side effect.
    case appNotRunning
    /// The action needs a running slide show.
    case noShow
    case unsupported(Capability)
    /// Needs Accessibility permission, or UI scripting is turned off in settings.
    case needsAccessibility
    case notFound(String)
    case unsavedChanges(String)
    case script(code: Int, message: String)

    public var description: String {
        switch self {
        case .notAuthorized: "Automation permission denied"
        case .appNotRunning: "App not running"
        case .noShow: "No slide show running"
        case .unsupported(let c): "Not supported: \(c.rawValue)"
        case .needsAccessibility: "Needs Accessibility permission"
        case .notFound(let what): "Not found: \(what)"
        case .unsavedChanges(let name): "\(name) has unsaved changes"
        case .script(let code, let message): "Script error \(code): \(message)"
        }
    }
}

/// Settings a backend needs to decide how to carry out an action.
public struct BackendOptions: Sendable, Equatable {
    public var uiScriptingAllowed: Bool
    public var activatingAppAllowed: Bool

    public init(uiScriptingAllowed: Bool = true, activatingAppAllowed: Bool = true) {
        self.uiScriptingAllowed = uiScriptingAllowed
        self.activatingAppAllowed = activatingAppAllowed
    }
}

/// One presentation app. Implementations run their scripts serially and must never
/// launch the app: callers check `isAppRunning` first, but implementations re-check.
public protocol SlideBackend: AnyObject, Sendable {
    var kind: BackendKind { get }
    var bundleIdentifier: String { get }
    var capabilities: Set<Capability> { get }

    func isAppRunning() -> Bool
    /// When the app was last frontmost, for auto-selection.
    func lastActivated() -> Date?
    func poll() async throws -> BackendSnapshot
    func perform(_ action: SlideAction, options: BackendOptions) async throws
}
