import AppKit
import Foundation
import KeyPointCore

/// Drives Keynote through its AppleScript dictionary.
/// Behavior notes and workarounds are documented in docs/capabilities.md.
public final class KeynoteBackend: SlideBackend, @unchecked Sendable {
    public let kind = BackendKind.keynote
    public let bundleIdentifier = "com.apple.iWork.Keynote"
    /// No sections, build counts, media control or laser pointer: Keynote doesn't expose them.
    /// Black/white is a key press, so its state is what we last set, not read back.
    /// Media values are an estimate: a timer started when the saved file says the movie starts
    /// (see `KeynoteMediaTimer`).
    public let capabilities: Set<Capability> = [
        .navigate, .gotoSlide, .hideSlides, .startShow, .endShow, .blackWhite, .buildPosition, .notes, .openClose,
        .activatePresentation, .mediaDuration, .mediaEstimated,
    ]

    private let runner: any ScriptRunning
    private let worker = SerialWorker(label: "keypoint.keynote")
    private let monitor: AppMonitor?
    /// Movie lengths (AVFoundation) and movie timing (builds, trims), read from the saved .key.
    private let clips = MediaDurationResolver.keynote()
    private let decks = DeckFileCache<KeynoteDeckMedia>.keynoteDeck()

    // Touched only on `worker`'s queue.
    private var overlay = ScreenOverlay.none
    private var tracker = KeynoteBuildTracker()
    private var lastSlide: Int?
    /// Slide whose movie was last looked up, and the estimate for it (nil: no movie).
    private var mediaSlide: Int?
    private var mediaTimer: KeynoteMediaTimer?
    /// When KeyPoint last moved the show, so a new slide's timer starts then, not at the next poll.
    private var lastNavigation = Date.distantPast
    /// Our own next/previous on the current slide: when each click (1, 2, …) was sent, the
    /// visible ordinal they were on, and when a step arrived on a new slide.
    private var clicks: [Int: Date] = [:]
    private var clickOrdinal: Int?
    private var arrival: (ordinal: Int, at: Date)?
    /// Recent visible ordinals and when they were seen, to tell where the show was when a
    /// clicker was pressed. Visible ordinal of the slide `mediaTimer` belongs to.
    private var ordinals: [(at: Date, ordinal: Int)] = []
    private var mediaOrdinal: Int?

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
        let polledAt = Date()
        let raw = try KeynotePoll.parse(try script(KeynoteScripts.poll))
        let presentations = raw.documents.map { d in
            PresentationInfo(name: d.name, path: d.folder, slideCount: d.skipped.count, saved: d.saved,
                             slideshow: raw.playing && d.name == raw.front, hidden: d.skipped)
        }
        guard raw.playing, let doc = raw.documents.first(where: { $0.name == raw.front }) else {
            overlay = .none
            tracker.reset()
            lastSlide = nil
            mediaSlide = nil
            mediaTimer = nil
            clicks = [:]
            ordinals = []
            return BackendSnapshot(presentations: presentations, activePresentation: raw.front.isEmpty ? nil : raw.front)
        }
        // Keynote numbers slides by position among visible ones; map back to the real index.
        let slide = Self.realIndex(ofVisible: raw.visibleOrdinal, skipped: doc.skipped) ?? lastSlide ?? 1
        if slide != lastSlide { overlay = .none }
        lastSlide = slide
        tracker.observe(slide: slide)
        noteOrdinal(raw.visibleOrdinal, at: polledAt)
        // Read the saved file early, so its movie timing is ready when a movie slide comes up.
        let deck = decks.lookup(deckPath: doc.path, item: "deck")
        if slide != mediaSlide {
            mediaSlide = slide
            mediaOrdinal = raw.visibleOrdinal
            if clickOrdinal != raw.visibleOrdinal { clicks = [:] }
            let arrived: Date = if let a = arrival, a.ordinal == raw.visibleOrdinal, polledAt.timeIntervalSince(a.at) < 2 {
                a.at
            } else if polledAt.timeIntervalSince(lastNavigation) < 1 {
                lastNavigation
            } else {
                polledAt
            }
            let previous = mediaTimer
            mediaTimer = (try? KeynoteMovie.parse(try script(KeynoteScripts.movie(document: doc.name, slide: slide))))
                .flatMap { $0 }
                .map { KeynoteMediaTimer(movie: $0, arrivedAt: arrived, arrivedBackward: tracker.position == nil) }
            mediaTimer?.continueFrom(previous, clicks: clicks, now: polledAt)
        }
        if var timer = mediaTimer, !timer.planResolved, let deck {
            timer.resolvePlan(deck, slide: slide, slideCount: doc.skipped.count)
            mediaTimer = timer
        }
        let media = mediaTimer.map { timer in
            timer.media(fileDuration: clips.clip(deckPath: doc.path, item: timer.movie.fileName)?.fileDuration,
                        clicks: clicks, now: Date())
        }
        let show = ShowInfo(presentationName: doc.name, currentSlide: slide, state: .running, overlay: overlay,
                            buildPosition: tracker.position, notes: raw.notes, media: media)
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
        case .next, .previous, .gotoFirst, .gotoLast, .gotoSlide, .startShow, .startFromCurrent:
            lastNavigation = Date()
        default:
            break
        }
        switch action {
        case .next, .previous:
            let forward = action == .next
            let sent = Date()
            let (before, after) = try step(forward ? "show next" : "show previous", options: options)
            tracker.stepped(forward: forward, sameSlide: before == after && before > 0)
            noteStep(forward: forward, before: before, after: after, at: sent)
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
            mediaSlide = nil // a restart replays the movie
        case .startFromCurrent:
            // The selected slide's number is its position among visible slides (-1 if skipped).
            let f = try script(KeynoteScripts.selection).split(separator: AS.unit, omittingEmptySubsequences: false)
            let skipped = f.count > 1 ? f[1].split(separator: ",").map { $0 == "true" } : []
            let real = Self.realIndex(ofVisible: Int(f.first ?? "") ?? -1, skipped: skipped) ?? 1
            _ = try script(KeynoteScripts.start(from: String(real)))
            tracker.reset()
            mediaSlide = nil
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

    // MARK: Clicker

    public func clickerPressed(forward: Bool, at time: Date) async {
        try? await worker.run { try self.clickerSync(forward: forward, at: time) }
    }

    /// A PerfectCue press: the base station has sent the keystroke to Keynote. Compare the slide
    /// before the press with the slide after it to tell a build step from a slide change.
    func clickerSync(forward: Bool, at time: Date) throws {
        // The last ordinal seen before the press (allowing for the keystroke to land after it).
        guard let before = ordinals.last(where: { $0.at <= time.addingTimeInterval(0.05) })?.ordinal, before > 0 else { return }
        // Keynote updates the current slide about 100 ms after the key.
        let wait = 0.2 - Date().timeIntervalSince(time)
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        guard let after = Int(try script(KeynoteScripts.currentOrdinal)), after > 0 else { return }
        tracker.stepped(forward: forward, sameSlide: before == after)
        overlay = .none // any navigation key clears Keynote's black/white screen
        noteStep(forward: forward, before: before, after: after, at: time)
        // A poll may have seen the new slide first: it arrived at the press, not at that poll.
        if before != after, mediaOrdinal == after, var timer = mediaTimer, time < timer.arrivedAt {
            timer.arrivedAt = time
            mediaTimer = timer
        }
    }

    private func noteOrdinal(_ ordinal: Int, at time: Date) {
        ordinals.append((time, ordinal))
        if ordinals.count > 8 { ordinals.removeFirst(ordinals.count - 8) }
    }

    /// Remembers when each click on the current slide was sent, for movies that start on a click.
    private func noteStep(forward: Bool, before: Int, after: Int, at time: Date) {
        guard after > 0 else { return }
        noteOrdinal(after, at: Date())
        if before == after {
            if clickOrdinal != after { clicks = [:] }
            if let position = tracker.position {
                if forward { clicks[position] = time } else { clicks = clicks.filter { $0.key <= position } }
            }
        } else {
            clicks = [:]
            arrival = (after, time)
        }
        clickOrdinal = after
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
        /// The saved file, empty if never saved.
        var path: String
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
                result.documents.append(Document(name: f[1], folder: folder, path: f[2], saved: f[3] == "true",
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

/// The first movie (or, failing that, audio clip) on a slide, as Keynote's scripting describes it.
struct KeynoteMovie: Equatable {
    enum Repetition: String {
        case none
        case loop
        case loopBackAndForth = "loop back and forth"
    }

    var fileName: String
    var repetition: Repetition

    /// `fileName<US>repetition`, or empty for no media.
    static func parse(_ text: String) throws -> KeynoteMovie? {
        let f = text.split(separator: AS.unit, omittingEmptySubsequences: false).map(String.init)
        guard let name = f.first, !name.isEmpty else { return nil }
        return KeynoteMovie(fileName: name, repetition: f.count > 1 ? Repetition(rawValue: f[1]) ?? .none : .none)
    }
}

/// Keynote doesn't report movie playback (state, position) to scripts, so this estimates it.
///
/// The saved file says when the movie starts: its Start Movie build step (on click, after
/// the transition, after or with another build, plus delays), and its trims. The timer starts
/// that long after the slide appeared or after the matching click sent through KeyPoint, and
/// assumes the movie then plays through at normal speed. Without a usable file (never saved,
/// changed since, unreadable), it falls back to starting when the slide appears.
///
/// Not seen: clicks made on the Mac or with a clicker attached to it (a movie waiting for a
/// click then never starts), pausing or skimming, and the exact moment the transition ends.
struct KeynoteMediaTimer: Equatable {
    var movie: KeynoteMovie
    var arrivedAt: Date
    /// Stepped back onto the slide: which builds have run isn't known.
    var arrivedBackward = false
    /// From the saved file, once matched to this slide's movie.
    var plan: KeynoteFileMovie?
    var planResolved = false
    /// Carried over from the previous slide ("Play movie across slides").
    var continuedStart: Date?

    /// Looks the movie up in the parsed file. Only used if the file matches what Keynote shows:
    /// same slide count, and the slide has a movie stored under this file name.
    mutating func resolvePlan(_ deck: KeynoteDeckMedia?, slide: Int, slideCount: Int) {
        planResolved = true
        guard let deck, deck.slides.count == slideCount, slide >= 1, slide <= deck.slides.count else { return }
        let candidates = deck.slides[slide - 1]
        let names = candidates.compactMap(\.storedName)
        guard let name = KeynoteMedia.match(movie.fileName, in: names) else { return }
        plan = candidates.first { $0.storedName == name }
    }

    /// Keeps the previous slide's timing if the same movie plays across into this slide.
    mutating func continueFrom(_ previous: KeynoteMediaTimer?, clicks: [Int: Date], now: Date) {
        guard let previous, previous.movie.fileName == movie.fileName, previous.plan?.playAcrossSlides ?? true,
              let started = previous.startedAt(clicks: clicks), started <= now else { return }
        continuedStart = started
        plan = previous.plan
        planResolved = previous.planResolved
    }

    /// When the movie is estimated to have started (or to start), if known.
    func startedAt(clicks: [Int: Date]) -> Date? {
        if let continuedStart { return continuedStart }
        guard planResolved, let plan else { return arrivedBackward ? nil : arrivedAt }
        let trigger: Date? = plan.start.click == 0 ? (arrivedBackward ? nil : arrivedAt) : clicks[plan.start.click]
        return trigger?.addingTimeInterval(Double(plan.start.offset) / 1000)
    }

    /// `fileDuration`: the whole media file's length, if measured.
    func media(fileDuration: Int?, clicks: [Int: Date], now: Date) -> MediaInfo {
        var info = MediaInfo(state: .notready, position: 0, estimated: true)
        if let plan, plan.playableLength != nil {
            // The file has the trims; the whole length comes from measuring the media file.
            let total = max(fileDuration ?? plan.trimEnd, plan.trimEnd)
            info.duration = total
            info.trimStart = plan.trimStart
            info.trimEnd = total - plan.trimEnd
        } else {
            info.duration = fileDuration
        }
        // Waiting for the saved file to be read, for a click, or for a build delay to pass.
        guard planResolved || continuedStart != nil, let started = startedAt(clicks: clicks), now >= started else { return info }
        let elapsed = Int((now.timeIntervalSince(started) * 1000).rounded())
        guard let length = info.trimmedDuration, length > 0 else {
            info.state = .playing
            info.position = elapsed
            return info
        }
        switch movie.repetition {
        case .none:
            // Keynote holds the last frame once the movie ends.
            info.state = elapsed >= length ? .stopped : .playing
            info.position = min(elapsed, length)
        case .loop, .loopBackAndForth:
            // Each pass counts down from the full length (back-and-forth passes are just as long).
            info.state = .playing
            info.position = elapsed % length
        }
        return info
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

    /// The current slide's visible ordinal, or "NOSHOW".
    static let currentOrdinal = """
        if not playing then return "NOSHOW"
        return (slide number of current slide of front document) as text
        """

    /// The first movie, else the first audio clip, on real slide `slide`: `fileName<US>repetition`, or "".
    static func movie(document name: String, slide: Int) -> String {
        """
        set c to slide \(slide) of document \(AS.literal(name))
        try
            if (count of movies of c) > 0 then
                set m to movie 1 of c
                return (file name of m) & US & ((repetition method of m) as text)
            end if
        end try
        try
            if (count of audio clips of c) > 0 then
                set m to audio clip 1 of c
                return (file name of m) & US & ((repetition method of m) as text)
            end if
        end try
        return ""
        """
    }

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
