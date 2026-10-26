import Foundation
import KeyPointCore

/// Runs AppleScript source and returns the result as text. Behind a protocol so
/// backends can be tested with canned results.
public protocol ScriptRunning: Sendable {
    func run(_ source: String) throws -> String
}

/// In-process NSAppleScript runner. Compiled scripts are cached by source.
/// Not thread-safe by itself: each backend calls it from one serial queue.
public final class AppleScriptRunner: ScriptRunning, @unchecked Sendable {
    private var cache: [String: NSAppleScript] = [:]
    static let trace = ProcessInfo.processInfo.environment["KEYPOINT_TRACE"] == "1"

    public init() {}

    public func run(_ source: String) throws -> String {
        let script: NSAppleScript
        if let cached = cache[source] {
            script = cached
        } else {
            script = try Self.compileOnMainThread(source)
            if cache.count > 100 { cache.removeAll() }
            cache[source] = script
        }
        var error: NSDictionary?
        let start = Date()
        let result = script.executeAndReturnError(&error)
        if Self.trace {
            let label = source.split(separator: "\n").dropFirst(22).first ?? ""
            print("[script \(Int(Date().timeIntervalSince(start) * 1000)) ms] \(label.trimmingCharacters(in: .whitespaces))",
                  error.map { "error \($0[NSAppleScript.errorNumber] ?? "")" } ?? "")
        }
        if let error { throw Self.map(error) }
        return result.stringValue ?? ""
    }

    /// A script created and compiled off the main thread loses Apple event replies
    /// intermittently (calls hang until they time out). Compiled on the main thread,
    /// it can then be executed from a background queue reliably.
    private static func compileOnMainThread(_ source: String) throws -> NSAppleScript {
        let compile = { () -> Result<NSAppleScript, BackendError> in
            guard let script = NSAppleScript(source: source) else {
                return .failure(.script(code: 0, message: "Could not create script"))
            }
            var error: NSDictionary?
            return script.compileAndReturnError(&error) ? .success(script) : .failure(map(error))
        }
        let result = Thread.isMainThread ? compile() : DispatchQueue.main.sync(execute: compile)
        return try result.get()
    }

    static func map(_ error: NSDictionary?) -> BackendError {
        let code = error?[NSAppleScript.errorNumber] as? Int ?? 0
        let message = error?[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
        switch code {
        case -1743: return .notAuthorized
        case -600, -609: return .appNotRunning
        default: return .script(code: code, message: message)
        }
    }
}

enum AS {
    /// Wraps a script body for one app: separators, a join helper, and a running check
    /// first, so a race with the user quitting the app can't relaunch it. `handlers` are
    /// extra top-level handlers; `body` runs inside `tell application id` with a timeout.
    static func wrap(_ body: String, bundleID: String, handlers: String = "", timeout: Int = 10) -> String {
        """
        property US : character id 31
        property RS : character id 30
        \(handlers)
        on joinList(xs, sep)
            set saved to AppleScript's text item delimiters
            set AppleScript's text item delimiters to sep
            set t to xs as text
            set AppleScript's text item delimiters to saved
            return t
        end joinList
        if not (application id "\(bundleID)" is running) then return "NOTRUNNING"
        tell application id "\(bundleID)"
        with timeout of \(timeout) seconds
        \(body)
        end timeout
        end tell
        """
    }

    /// AppleScript string literal.
    static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Field and record separators used in script results (ASCII unit/record separator).
    static let unit: Character = "\u{1F}"
    static let record: Character = "\u{1E}"
}

/// Runs work on a backend's private serial queue from async code.
struct SerialWorker: Sendable {
    let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}
