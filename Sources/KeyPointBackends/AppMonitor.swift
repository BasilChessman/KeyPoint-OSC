import AppKit
import ApplicationServices

/// Tracks which presentation apps are running and when each was last frontmost.
/// Checking `NSRunningApplication` never launches an app, unlike AppleScript `tell`.
public final class AppMonitor: @unchecked Sendable {
    public static let shared = AppMonitor()

    private let lock = NSLock()
    private var activations: [String: Date] = [:]
    private var observer: NSObjectProtocol?

    private init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier else { return }
            self?.lock.withLock { self?.activations[id] = Date() }
        }
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            activations[front] = Date()
        }
    }

    public func runningApp(_ bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
    }

    public func isRunning(_ bundleID: String) -> Bool {
        runningApp(bundleID) != nil
    }

    public func isFrontmost(_ bundleID: String) -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    public func lastActivated(_ bundleID: String) -> Date? {
        lock.withLock { activations[bundleID] }
    }
}

/// Accessibility (UI scripting) helpers.
public enum Accessibility {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt asking the user to allow Accessibility for this app.
    public static func requestTrust() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Presses a menu item by title path, e.g. ["Slide Show", "Play from Current Slide"].
    /// Works while the app is in the background. Returns false if the item isn't there or is disabled.
    public static func pressMenuItem(pid: pid_t, path: [String]) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard var element = attribute(app, kAXMenuBarAttribute) else { return false }
        for title in path {
            // Menu bar items and menu items each wrap their menu as a single child.
            let candidates = children(element).flatMap { child in
                role(child) == kAXMenuRole as String ? children(child) : [child]
            }
            guard let match = candidates.first(where: { self.title($0) == title }) else { return false }
            element = match
        }
        var enabled: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled)
        guard (enabled as? Bool) != false else { return false }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// Sends a key press straight to a process (it needn't be frontmost). Needs Accessibility.
    public static func sendKey(_ keyCode: CGKeyCode, to pid: pid_t) -> Bool {
        guard isTrusted,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return false }
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        return value as? [AXUIElement] ?? []
    }

    private static func title(_ element: AXUIElement) -> String? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        return value as? String
    }

    private static func role(_ element: AXUIElement) -> String? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return value as? String
    }
}
