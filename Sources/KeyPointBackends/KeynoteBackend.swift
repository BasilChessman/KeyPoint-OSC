import AppKit
import Foundation
import KeyPointCore

/// Drives Keynote through its AppleScript dictionary.
/// Behavior notes and workarounds are documented in docs/capabilities.md.
public final class KeynoteBackend: SlideBackend, @unchecked Sendable {
    public let kind = BackendKind.keynote
    public let bundleIdentifier = "com.apple.iWork.Keynote"
    /// No sections, build counts, media or laser pointer: Keynote doesn't expose them.
    /// Black/white is a key press, so its state is what we last set, not read back.
    public let capabilities: Set<Capability> = [
        .navigate, .gotoSlide, .hideSlides, .startShow, .endShow, .blackWhite, .buildPosition, .notes, .openClose,
        .activatePresentation,
    ]

    private let runner: any ScriptRunning
    private let worker = SerialWorker(label: "keypoint.keynote")
    private let monitor: AppMonitor?

    // Touched only on `worker`'s queue.
    private var overlay = ScreenOverlay.none
    private var tracker = KeynoteBuildTracker()
    private var lastSlide: Int?

    public init(runner: any ScriptRunning = AppleScriptRunner(), monitor: AppMonitor? = .shared) {
        self.runner = runner
        self.monitor = monitor
    }

    public func isAppRunning() -> Bool { monitor?.isRunning(bundleIdentifier) ?? true }
    public func lastActivated() -> Date? { monitor?.lastActivated(bundleIdentifier) }

    // MARK: Polling

    public func poll() async throws -> BackendSnapshot {
        try await worker.run { try self.pollSync() }
    }

    func pollSync() throws -> BackendSnapshot {
        let raw = try KeynotePoll.parse(try script(KeynoteScripts.poll))
        let presentations = raw.documents.map { d in
            PresentationInfo(name: d.name, path: d.folder, slideCount: d.skipped.count, saved: d.saved,
                             slideshow: raw.playing && d.name == raw.front, hidden: d.skipped)
        }
        guard raw.playing, let doc = raw.documents.first(where: { $0.name == raw.front }) else {
            overlay = .none
            tracker.reset()
            lastSlide = nil
            return BackendSnapshot(presentations: presentations, activePresentation: raw.front.isEmpty ? nil : raw.front)
        }
        // Keynote numbers slides by position among visible ones; map back to the real index.
        let slide = Self.realIndex(ofVisible: raw.visibleOrdinal, skipped: doc.skipped) ?? lastSlide ?? 1
        if slide != lastSlide { overlay = .none }
        lastSlide = slide
        tracker.observe(slide: slide)
        let show = ShowInfo(presentationName: doc.name, currentSlide: slide, state: .running, overlay: overlay,
                            buildPosition: tracker.position, notes: raw.notes)
        return BackendSnapshot(presentations: presentations, activePresentation: doc.name, show: show)
    }

    static func realIndex(ofVisible ordinal: Int, skipped: [Bool]) -> Int? {
        guard ordinal > 0 else { return nil }
        var seen = 0
        for (i, isSkipped) in skipped.enumerated() where !isSkipped {
            seen += 1
            if seen == ordinal { return i + 1 }
        }
        return nil
    }

    // MARK: Actions

    public func perform(_ action: SlideAction, options: BackendOptions) async throws {
        try await worker.run { try self.performSync(action, options: options) }
    }

    func performSync(_ action: SlideAction, options: BackendOptions) throws {
        switch action {
        case .next, .previous:
            let forward = action == .next
            let (before, after) = try step(forward ? "show next" : "show previous", options: options)
            tracker.stepped(forward: forward, sameSlide: before == after && before > 0)
            overlay = .none // any navigation key clears Keynote's black/white screen
        case .gotoFirst:
            try requireShow(KeynoteScripts.showSlide("1"))
        case .gotoLast:
            try requireShow(KeynoteScripts.showSlide("(count of slides of d)"))
        case .gotoSlide(let n):
            if try script(KeynoteScripts.isPlaying) == "true" {
                try requireShow(KeynoteScripts.showSlide(String(n)))
            } else {
                _ = try script(KeynoteScripts.selectSlide(n))
            }
        case .hideSlide(let n), .unhideSlide(let n):
            let hide = if case .hideSlide = action { true } else { false }
            _ = try script(KeynoteScripts.setSkipped(slide: n, skipped: hide))
        case .startShow(let from):
            _ = try script(KeynoteScripts.start(from: from.map(String.init) ?? "1"))
            tracker.reset()
        case .startFromCurrent:
            // The selected slide's number is its position among visible slides (-1 if skipped).
            let f = try script(KeynoteScripts.selection).split(separator: AS.unit, omittingEmptySubsequences: false)
            let skipped = f.count > 1 ? f[1].split(separator: ",").map { $0 == "true" } : []
            let real = Self.realIndex(ofVisible: Int(f.first ?? "") ?? -1, skipped: skipped) ?? 1
            _ = try script(KeynoteScripts.start(from: String(real)))
            tracker.reset()
        case .endShow:
            _ = try script(KeynoteScripts.stop)
        case .black(let on):
            try setOverlay(.black, on: on, keyCode: 11, options: options) // "b"
        case .white(let on):
            try setOverlay(.white, on: on, keyCode: 13, options: options) // "w"
        case .activatePresentation(let name):
            if try script(KeynoteScripts.raise(name)) == "NOTFOUND" { throw BackendError.notFound(name) }
        case .openFile(let url):
            _ = try script(KeynoteScripts.open(url.path))
        case .closePresentation(let name, let mode):
            let result = try script(KeynoteScripts.close(name: name, mode: mode))
            if result.hasPrefix("UNSAVED") { throw BackendError.unsavedChanges(String(result.dropFirst(8))) }
            if result == "NOTFOUND" { throw BackendError.notFound(name ?? "front document") }
        case .gotoSection, .startSection:
            throw BackendError.unsupported(.sections)
        case .pause, .resume:
            throw BackendError.unsupported(.pauseResume)
        case .laserPointer:
            throw BackendError.unsupported(.laserPointer)
        case .mediaPlay, .mediaPause, .mediaPlayPause, .mediaStop, .mediaSeek, .mediaBookmarkNext, .mediaBookmarkPrevious:
            throw BackendError.unsupported(.media)
        }
    }

    /// Runs next/previous and returns the visible ordinal before and after.
    /// `show next`/`show previous` fail with "No window" unless Keynote is frontmost.
    private func step(_ command: String, options: BackendOptions) throws -> (Int, Int) {
        var result = try script(KeynoteScripts.step(command))
        if result == "NOWINDOW" {
            guard options.activatingAppAllowed else {
                throw BackendError.script(code: -1708, message: "Keynote must be frontmost for next/previous")
            }
            result = try script(KeynoteScripts.step(command, activateFirst: true))
        }
        if result == "NOSHOW" { throw BackendError.noShow }
        let parts = result.split(separator: AS.unit).map { Int($0) ?? -1 }
        return (parts.first ?? -1, parts.count > 1 ? parts[1] : -1)
    }

    private func requireShow(_ source: String) throws {
        if try script(source) == "NOSHOW" { throw BackendError.noShow }
    }

    /// Keynote toggles black/white with a key press and can't report the state, so we
    /// track it ourselves. It drifts if someone presses keys on the Mac.
    private func setOverlay(_ target: ScreenOverlay, on: Bool?, keyCode: CGKeyCode, options: BackendOptions) throws {
        guard try script(KeynoteScripts.isPlaying) == "true" else { throw BackendError.noShow }
        guard options.uiScriptingAllowed, let pid = monitor?.runningApp(bundleIdentifier)?.processIdentifier else {
            throw BackendError.needsAccessibility
        }
        let turnOn = on ?? (overlay != target)
        var presses: [CGKeyCode] = []
        if turnOn {
            if overlay != .none && overlay != target {
                presses.append(overlay == .black ? 11 : 13) // clear the other overlay first
            }
            if overlay != target { presses.append(keyCode) }
        } else if overlay == target {
            presses.append(keyCode)
        }
        for key in presses {
            guard Accessibility.sendKey(key, to: pid) else { throw BackendError.needsAccessibility }
            Thread.sleep(forTimeInterval: 0.05)
        }
        overlay = turnOn ? target : .none
    }

    private func script(_ body: String) throws -> String {
        guard isAppRunning() else { throw BackendError.appNotRunning }
        let result = try runner.run(AS.wrap(body, bundleID: bundleIdentifier))
        if result == "NOTRUNNING" { throw BackendError.appNotRunning }
        return result
    }
}

/// Counts our own steps through builds. Keynote doesn't report build counts, so after
/// stepping back onto a slide the position is unknown until the slide changes again.
struct KeynoteBuildTracker {
    private(set) var position: Int?
    private var slide: Int?
    private var pendingBackward = false

    mutating func reset() {
        position = nil
        slide = nil
        pendingBackward = false
    }

    mutating func stepped(forward: Bool, sameSlide: Bool) {
        if sameSlide {
            if let pos = position { position = forward ? pos + 1 : max(pos - 1, 0) }
        } else {
            pendingBackward = !forward
            slide = nil
        }
    }

    mutating func observe(slide current: Int) {
        guard slide != current else { return }
        slide = current
        position = pendingBackward ? nil : 0
        pendingBackward = false
    }
}

struct KeynotePoll: Equatable {
    struct Document: Equatable {
        var name: String
        var folder: String
        var saved: Bool
        var skipped: [Bool]
    }

    var documents: [Document] = []
    var front = ""
    var playing = false
    var visibleOrdinal = -1
    var notes: String?

    /// Records: `D|name|posixPath|saved|skipped,...`, `F|front`, `S|ordinal|notes` (only while playing).
    static func parse(_ text: String) throws -> KeynotePoll {
        var result = KeynotePoll()
        for record in text.split(separator: AS.record, omittingEmptySubsequences: true) {
            let f = record.split(separator: AS.unit, maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            switch f.first {
            case "D" where f.count >= 5:
                let folder = f[2].isEmpty ? "" : (f[2] as NSString).deletingLastPathComponent
                result.documents.append(Document(name: f[1], folder: folder, saved: f[3] == "true",
                                                 skipped: f[4].isEmpty ? [] : f[4].split(separator: ",").map { $0 == "true" }))
            case "F" where f.count >= 2:
                result.front = f[1]
            case "S" where f.count >= 2:
                result.playing = true
                result.visibleOrdinal = Int(f[1]) ?? -1
                result.notes = f.count > 2 ? f[2] : ""
            default:
                continue
            }
        }
        return result
    }
}

enum KeynoteScripts {
    static let poll = """
        set recs to {}
        repeat with i from 1 to count of documents
            set d to document i
            set f to ""
            try
                set f to POSIX path of (file of d as alias)
            end try
            set end of recs to "D" & US & (name of d) & US & f & US & ((not (modified of d)) as text) & US & my joinList(skipped of every slide of d, ",")
        end repeat
        set frontName to ""
        try
            set frontName to name of front document
        end try
        set end of recs to "F" & US & frontName
        if playing then
            try
                set c to current slide of front document
                set end of recs to "S" & US & ((slide number of c) as text) & US & (presenter notes of c)
            end try
        end if
        return my joinList(recs, RS)
        """

    static let isPlaying = "return playing as text"

    static let selection = """
        set d to front document
        return ((slide number of current slide of d) as text) & US & my joinList(skipped of every slide of d, ",")
        """

    /// Returns "before<US>after" visible ordinals. Keynote updates the current slide
    /// about 100 ms after the command returns, hence the delay.
    static func step(_ command: String, activateFirst: Bool = false) -> String {
        """
        if not playing then return "NOSHOW"
        \(activateFirst ? "activate\ndelay 0.1" : "")
        set beforeIdx to slide number of current slide of front document
        try
            \(command)
        on error number -1708
            return "NOWINDOW"
        end try
        delay 0.15
        set afterIdx to -1
        try
            set afterIdx to slide number of current slide of front document
        end try
        return (beforeIdx as text) & US & (afterIdx as text)
        """
    }

    /// `n` is an AppleScript expression evaluated with `d` = front document.
    static func showSlide(_ n: String) -> String {
        """
        if not playing then return "NOSHOW"
        set d to front document
        set n to \(n)
        if n < 1 then set n to 1
        if n > (count of slides of d) then set n to count of slides of d
        show slide n of d
        return ""
        """
    }

    static func selectSlide(_ n: Int) -> String {
        """
        set d to front document
        set n to \(n)
        if n < 1 then set n to 1
        if n > (count of slides of d) then set n to count of slides of d
        set current slide of d to slide n of d
        """
    }

    static func setSkipped(slide n: Int, skipped: Bool) -> String {
        """
        set d to front document
        if \(n) < 1 or \(n) > (count of slides of d) then return "RANGE"
        set skipped of slide \(n) of d to \(skipped)
        """
    }

    /// `from` is an AppleScript expression for the real slide index, with `d` = front document.
    static func start(from: String) -> String {
        """
        set d to front document
        set n to 1
        try
            set n to \(from)
        end try
        if n < 1 then set n to 1
        if n > (count of slides of d) then set n to count of slides of d
        start d from slide n of d
        """
    }

    static let stop = """
        if playing then stop front document
        """

    static func raise(_ name: String) -> String {
        """
        if not (exists document \(AS.literal(name))) then return "NOTFOUND"
        set index of window \(AS.literal(name)) to 1
        """
    }

    static func open(_ path: String) -> String {
        "open (POSIX file \(AS.literal(path)))"
    }

    static func close(name: String?, mode: CloseMode) -> String {
        let target = name.map { "document \(AS.literal($0))" } ?? "front document"
        let closing = switch mode {
        case .abort, .force: "close d saving no"
        case .save: "save d\nclose d saving no"
        }
        return """
        if not (exists \(target)) then return "NOTFOUND"
        set d to \(target)
        set nm to name of d
        if \(mode == .abort ? "true" : "false") and (modified of d) then return "UNSAVED " & nm
        \(closing)
        """
    }
}
