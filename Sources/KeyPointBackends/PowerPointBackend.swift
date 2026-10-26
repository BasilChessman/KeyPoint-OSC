import AppKit
import Foundation
import KeyPointCore

/// Drives PowerPoint for Mac through its AppleScript dictionary.
/// Behavior notes and workarounds are documented in docs/capabilities.md.
public final class PowerPointBackend: SlideBackend, @unchecked Sendable {
    public let kind = BackendKind.powerpoint
    public let bundleIdentifier = "com.microsoft.Powerpoint"
    public let capabilities: Set<Capability> = [
        .navigate, .gotoSlide, .sections, .hideSlides, .startShow, .endShow, .blackWhite, .pauseResume,
        .media, .buildCount, .buildPosition, .notes, .openClose, .activatePresentation,
    ]

    private let runner: any ScriptRunning
    private let worker = SerialWorker(label: "keypoint.powerpoint")
    private let monitor: AppMonitor?

    // Touched only on `worker`'s queue.
    private var structureCache: [String: (slideCount: Int, fetched: Date, hidden: [Bool], sections: [SectionInfo])] = [:]
    private var tracking = BuildTracker()
    private var lastFull: BackendSnapshot?
    private var lastFullAt = Date.distantPast
    private var mediaShape = 0
    private var needsFull = true

    /// How long hidden-slide and section info is reused before re-reading.
    var structureTTL: TimeInterval = 10
    /// During a show, a cheap poll (slide, state, media) runs every tick and the full
    /// poll (presentations, notes, builds) only when the slide changes or this often.
    var fullPollInterval: TimeInterval = 2

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
        if !needsFull, let last = lastFull, let show = last.show, Date().timeIntervalSince(lastFullAt) < fullPollInterval,
           let fast = try FastResult.parse(try script(Scripts.fastShow(mediaShape: mediaShape))),
           fast.slideIndex == show.currentSlide {
            var updated = show
            updated.state = fast.state == "paused" ? .paused : .running
            updated.overlay = fast.state == "black" ? .black : fast.state == "white" ? .white : .none
            updated.media = fast.media
            tracking.observe(slide: fast.slideIndex, buildCount: show.buildCount ?? 0)
            updated.buildPosition = tracking.position
            var snapshot = last
            snapshot.show = updated
            lastFull = snapshot
            return snapshot
        }
        let snapshot = try fullPollSync()
        lastFull = snapshot
        lastFullAt = Date()
        needsFull = false
        return snapshot
    }

    private func fullPollSync() throws -> BackendSnapshot {
        let raw = try PollResult.parse(try script(Scripts.poll))
        var presentations: [PresentationInfo] = []
        for p in raw.presentations {
            let structure = try structureSync(for: p.name, slideCount: p.slideCount)
            presentations.append(PresentationInfo(
                name: p.name, path: p.path, slideCount: p.slideCount, saved: p.saved,
                slideshow: p.name == raw.show?.presentation, hidden: structure.hidden, sections: structure.sections))
        }
        mediaShape = raw.show?.mediaShape ?? 0
        guard let rawShow = raw.show else {
            tracking.reset()
            let active = raw.active.isEmpty ? presentations.first?.name : raw.active
            return BackendSnapshot(presentations: presentations, activePresentation: active)
        }
        let slideCount = presentations.first { $0.name == rawShow.presentation }?.slideCount ?? 0
        let slide = rawShow.slideIndex > 0 ? rawShow.slideIndex : slideCount
        tracking.observe(slide: slide, buildCount: rawShow.effectCount)
        let show = ShowInfo(
            presentationName: rawShow.presentation,
            currentSlide: slide,
            state: rawShow.state == "paused" ? .paused : .running,
            overlay: rawShow.state == "black" ? .black : rawShow.state == "white" ? .white : .none,
            buildPosition: tracking.position,
            buildCount: rawShow.effectCount,
            notes: rawShow.notes,
            media: rawShow.media)
        return BackendSnapshot(presentations: presentations, activePresentation: rawShow.presentation, show: show)
    }

    private func structureSync(for name: String, slideCount: Int) throws -> (hidden: [Bool], sections: [SectionInfo]) {
        if let cached = structureCache[name], cached.slideCount == slideCount,
           Date().timeIntervalSince(cached.fetched) < structureTTL {
            return (cached.hidden, cached.sections)
        }
        let parsed = try StructureResult.parse(try script(Scripts.structure(of: name)), slideCount: slideCount)
        structureCache[name] = (slideCount, Date(), parsed.hidden, parsed.sections)
        return (parsed.hidden, parsed.sections)
    }

    // MARK: Actions

    public func perform(_ action: SlideAction, options: BackendOptions) async throws {
        try await worker.run { try self.performSync(action, options: options) }
    }

    func performSync(_ action: SlideAction, options: BackendOptions) throws {
        // Actions that can't change the slide or presentation are followed by the quick poll.
        switch action {
        case .black, .white, .pause, .resume, .mediaPlay, .mediaPause, .mediaPlayPause, .mediaStop, .mediaSeek,
             .mediaBookmarkNext, .mediaBookmarkPrevious:
            break
        default:
            needsFull = true
        }
        switch action {
        case .next:
            let (before, after) = try step(Scripts.next)
            tracking.stepped(forward: true, from: before, to: after)
        case .previous:
            let (before, after) = try step(Scripts.previous)
            tracking.stepped(forward: false, from: before, to: after)
        case .gotoFirst:
            try requireShow(Scripts.inShow("go to first slide v"))
        case .gotoLast:
            try requireShow(Scripts.inShow("go to last slide v"))
        case .gotoSlide(let n):
            try gotoSlide(n, options: options)
        case .gotoSection(let name):
            try gotoSlide(try firstSlide(ofSection: name), options: options)
        case .hideSlide(let n), .unhideSlide(let n):
            let hide = if case .hideSlide = action { true } else { false }
            _ = try script(Scripts.setHidden(slide: n, hidden: hide))
            structureCache.removeAll()
        case .startShow(let from):
            try startShow(from: from, options: options)
        case .startFromCurrent:
            let current = Int(try script(Scripts.currentEditSlide)) ?? 1
            try startShow(from: current, options: options)
        case .startSection(let name):
            try startShow(from: try firstSlide(ofSection: name), options: options)
        case .endShow:
            _ = try script(Scripts.inShow("exit slide show v", orElse: ""))
        case .black(let on):
            try setOverlay("black", on: on)
        case .white(let on):
            try setOverlay("white", on: on)
        case .pause:
            try requireShow(Scripts.inShow("set slide state of v to slide show state paused"))
        case .resume:
            try requireShow(Scripts.inShow("set slide state of v to slide show state running"))
        case .laserPointer:
            throw BackendError.unsupported(.laserPointer)
        case .mediaPlay:
            try media("play player pl")
        case .mediaPause:
            try media("pause player pl")
        case .mediaPlayPause:
            try media("if player state of pl is player state playing then\npause player pl\nelse\nplay player pl\nend if")
        case .mediaStop:
            try media("stop player pl") // also rewinds; setting the position afterwards would report "paused"
        case .mediaSeek(let seek):
            switch seek {
            case .fromStart(let ms): try media("set current position of pl to \(max(ms, 0))")
            case .forward(let ms): try media("set current position of pl to (current position of pl) + \(max(ms, 0))")
            case .back(let ms):
                try media("set p to (current position of pl) - \(max(ms, 0))\nif p < 0 then set p to 0\nset current position of pl to p")
            case .beforeEnd, .percent:
                throw BackendError.unsupported(.mediaDuration) // PowerPoint doesn't expose clip duration
            }
        case .mediaBookmarkNext:
            try media("go to next bookmark for player pl")
        case .mediaBookmarkPrevious:
            try media("go to previous bookmark for player pl")
        case .activatePresentation(let name):
            try activate(name, options: options)
        case .openFile(let url):
            _ = try script(Scripts.open(url.path))
        case .closePresentation(let name, let mode):
            let result = try script(Scripts.close(name: name, mode: mode))
            if result.hasPrefix("UNSAVED") { throw BackendError.unsavedChanges(String(result.dropFirst(8))) }
            if result == "NOTFOUND" { throw BackendError.notFound(name ?? "active presentation") }
            structureCache.removeAll()
        }
    }

    /// Runs a next/previous script that returns "before<US>after" slide indexes.
    private func step(_ source: String) throws -> (Int, Int) {
        let result = try script(source)
        if result == "NOSHOW" { throw BackendError.noShow }
        let parts = result.split(separator: AS.unit).map { Int($0) ?? -1 }
        return (parts.first ?? -1, parts.count > 1 ? parts[1] : -1)
    }

    private func requireShow(_ source: String) throws {
        if try script(source) == "NOSHOW" { throw BackendError.noShow }
    }

    private func media(_ body: String) throws {
        switch try script(Scripts.media(body)) {
        case "NOSHOW": throw BackendError.noShow
        case "NOMEDIA": throw BackendError.notFound("media on current slide")
        default: break
        }
    }

    private func setOverlay(_ kind: String, on: Bool?) throws {
        let state = try script(Scripts.inShow("return my stateName(slide state of v)"))
        if state == "NOSHOW" { throw BackendError.noShow }
        let turnOn = on ?? (state != kind)
        let target = turnOn ? "slide show state \(kind) screen" : "slide show state running"
        if !turnOn && state != kind { return }
        try requireShow(Scripts.inShow("set slide state of v to \(target)"))
    }

    private func firstSlide(ofSection name: String) throws -> Int {
        let result = try script(Scripts.sectionFirstSlide(named: name))
        guard let n = Int(result), n > 0 else { throw BackendError.notFound("section \(name)") }
        return n
    }

    // MARK: Go to slide / start show

    /// `go to slide` on the slide show view always fails with -50 (a PowerPoint bug),
    /// so jump by restarting the show: select the slide in the editor and press
    /// Slide Show > Play from Current Slide (keeps the whole deck reachable), or, without
    /// Accessibility, restart with a range that begins at the slide.
    private func gotoSlide(_ n: Int, options: BackendOptions) throws {
        let inShow = try script(Scripts.showSlideIndex)
        guard let current = Int(inShow) else {
            // Not in a show: just select the slide in the editor.
            _ = try script(Scripts.selectSlide(n))
            return
        }
        if current == n { return }
        try startShow(from: n, options: options)
    }

    private func startShow(from requested: Int?, options: BackendOptions) throws {
        guard let n = requested, n > 1 else {
            _ = try script(Scripts.startAll)
            tracking.reset()
            return
        }
        if options.uiScriptingAllowed, Accessibility.isTrusted, let pid = monitor?.runningApp(bundleIdentifier)?.processIdentifier {
            _ = try script(Scripts.exitShowAndSelect(n))
            // The menu item is disabled for a moment after the show window closes.
            for _ in 0..<10 {
                if Accessibility.pressMenuItem(pid: pid, path: ["Slide Show", "Play from Current Slide"]) {
                    tracking.reset()
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        _ = try script(Scripts.startRange(from: n))
        tracking.reset()
    }

    private func activate(_ name: String, options: BackendOptions) throws {
        // Switching the active presentation by script doesn't work on Mac (see capabilities.md);
        // the Window menu does.
        guard try script(Scripts.hasPresentation(name)) == "YES" else { throw BackendError.notFound(name) }
        guard options.uiScriptingAllowed, Accessibility.isTrusted,
              let pid = monitor?.runningApp(bundleIdentifier)?.processIdentifier else {
            throw BackendError.needsAccessibility
        }
        // PowerPoint only switches windows from the Window menu while it's frontmost.
        if !(monitor?.isFrontmost(bundleIdentifier) ?? true) {
            guard options.activatingAppAllowed else { throw BackendError.script(code: 0, message: "PowerPoint must be frontmost") }
            monitor?.runningApp(bundleIdentifier)?.activate()
            for _ in 0..<20 where !(monitor?.isFrontmost(bundleIdentifier) ?? true) {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        let title = (name as NSString).deletingPathExtension
        if !Accessibility.pressMenuItem(pid: pid, path: ["Window", title]),
           !Accessibility.pressMenuItem(pid: pid, path: ["Window", name]) {
            throw BackendError.notFound("window \(name)")
        }
    }

    // MARK: Script plumbing

    private func script(_ body: String) throws -> String {
        guard isAppRunning() else { throw BackendError.appNotRunning }
        let result = try runner.run(Scripts.wrap(body, bundleID: bundleIdentifier))
        if result == "NOTRUNNING" { throw BackendError.appNotRunning }
        return result
    }
}

// MARK: - Build position tracking

/// PowerPoint reports how many effects a slide has but not how many have played,
/// so count our own next/previous steps. Clicks made directly on the Mac aren't seen.
struct BuildTracker {
    private(set) var slide: Int?
    private(set) var position: Int?
    private var count = 0
    private var arrivedBackward = false

    mutating func reset() {
        slide = nil
        position = nil
        arrivedBackward = false
    }

    mutating func stepped(forward: Bool, from before: Int, to after: Int) {
        guard before > 0, after > 0 else { return }
        if before == after, slide == after, let pos = position {
            position = forward ? min(pos + 1, count) : max(pos - 1, 0)
        } else if before != after {
            slide = nil
            arrivedBackward = !forward
        }
    }

    mutating func observe(slide current: Int, buildCount: Int) {
        count = buildCount
        if slide != current {
            slide = current
            position = arrivedBackward ? buildCount : 0
            arrivedBackward = false
        }
        if let pos = position, pos > buildCount { position = buildCount }
    }
}

// MARK: - Parsing

struct PollResult: Equatable {
    struct Presentation: Equatable {
        var name: String
        var path: String
        var saved: Bool
        var slideCount: Int
    }

    struct Show: Equatable {
        var presentation: String
        var slideIndex: Int
        var state: String
        var effectCount: Int
        var media: MediaInfo?
        var mediaShape: Int
        var notes: String
    }

    var presentations: [Presentation] = []
    var active = ""
    var show: Show?

    /// Records: `P|name|path|saved|count`, `A|active`,
    /// `S|pres|index|state|effects|mediaState|mediaPos|mediaShape|notes` (notes last: it can contain anything).
    static func parse(_ text: String) throws -> PollResult {
        var result = PollResult()
        for record in text.split(separator: AS.record, omittingEmptySubsequences: true) {
            let f = record.split(separator: AS.unit, maxSplits: 8, omittingEmptySubsequences: false).map(String.init)
            switch f.first {
            case "P" where f.count >= 5:
                result.presentations.append(Presentation(name: f[1], path: f[2], saved: f[3] == "true", slideCount: Int(f[4]) ?? 0))
            case "A" where f.count >= 2:
                result.active = f[1]
            case "S" where f.count >= 8:
                let media = MediaState(rawValue: f[5]).map { MediaInfo(state: $0, position: Int(f[6]) ?? 0) }
                result.show = Show(presentation: f[1], slideIndex: Int(f[2]) ?? -1, state: f[3], effectCount: Int(f[4]) ?? 0,
                                   media: media, mediaShape: Int(f[7]) ?? 0, notes: f.count > 8 ? f[8] : "")
            default:
                continue
            }
        }
        return result
    }
}

/// Result of `Scripts.fastShow`: `index|state|mediaState|mediaPos`, or nil when no show is running.
struct FastResult: Equatable {
    var slideIndex: Int
    var state: String
    var media: MediaInfo?

    static func parse(_ text: String) throws -> FastResult? {
        guard text != "NOSHOW" else { return nil }
        let f = text.split(separator: AS.unit, omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 4 else { return nil }
        return FastResult(slideIndex: Int(f[0]) ?? -1, state: f[1],
                          media: MediaState(rawValue: f[2]).map { MediaInfo(state: $0, position: Int(f[3]) ?? 0) })
    }
}

struct StructureResult: Equatable {
    var hidden: [Bool]
    var sections: [SectionInfo]

    /// Records: `H|0,0,1,...` then `X|id|name|first|count` per section.
    static func parse(_ text: String, slideCount: Int) throws -> StructureResult {
        var result = StructureResult(hidden: [], sections: [])
        for record in text.split(separator: AS.record) {
            let f = record.split(separator: AS.unit, omittingEmptySubsequences: false).map(String.init)
            switch f.first {
            case "H" where f.count >= 2:
                result.hidden = f[1].split(separator: ",").map { $0 == "true" }
            case "X" where f.count >= 5:
                let first = Int(f[3]) ?? 0, count = Int(f[4]) ?? 0
                guard first > 0, count > 0 else { continue } // empty sections don't contain slides
                result.sections.append(SectionInfo(id: f[1], name: f[2], firstSlide: first, slideCount: count))
            default:
                continue
            }
        }
        return result
    }
}

// MARK: - Scripts

enum Scripts {
    static func wrap(_ body: String, bundleID: String) -> String {
        AS.wrap(body, bundleID: bundleID, handlers: """
        on stateName(stateValue)
            tell application id "\(bundleID)"
                if stateValue is slide show state paused then return "paused"
                if stateValue is slide show state black screen then return "black"
                if stateValue is slide show state white screen then return "white"
                if stateValue is slide show state done then return "done"
            end tell
            return "running"
        end stateName
        on endShowAndWait()
            -- PowerPoint ignores "run slide show" until a closing show's window is gone.
            tell application id "\(bundleID)"
                if (count of slide show windows) = 0 then return
                exit slide show (slideshow view of slide show window 1)
                repeat 60 times
                    if (count of slide show windows) = 0 then exit repeat
                    delay 0.05
                end repeat
            end tell
            delay 0.25
        end endShowAndWait
        on runShow(ss)
            tell application id "\(bundleID)"
                run slide show ss
                repeat 2 times
                    delay 0.3
                    if (count of slide show windows) > 0 then return
                    run slide show ss
                end repeat
            end tell
        end runShow
        """)
    }

    static let poll = """
        set recs to {}
        repeat with i from 1 to count of presentations
            set p to presentation i
            set end of recs to "P" & US & (name of p) & US & (path of p) & US & (saved of p as text) & US & ((count of slides of p) as text)
        end repeat
        set activeName to ""
        try
            set activeName to name of active presentation
        end try
        set end of recs to "A" & US & activeName
        if (count of slide show windows) > 0 then
            set w to slide show window 1
            set v to slideshow view of w
            set stText to my stateName(slide state of v)
            set idx to -1
            set fx to 0
            set notesText to ""
            set mState to ""
            set mPos to "0"
            set mShape to 0
            try
                set s to slide of v
                set idx to slide index of s
                try
                    set fx to count of effects of main sequence of timeline of s
                end try
                try
                    set notesText to content of text range of text frame of place holder 2 of notes page of s
                end try
                try
                    repeat with k from 1 to count of shapes of s
                        if shape type of shape k of s is shape type media then
                            set pl to get player from v for (shape k of s)
                            set ps to player state of pl
                            set mState to "notready"
                            if ps is player state playing then set mState to "playing"
                            if ps is player state paused then set mState to "paused"
                            if ps is player state stopped then set mState to "stopped"
                            set mPos to (current position of pl) as text
                            set mShape to k
                            exit repeat
                        end if
                    end repeat
                end try
            end try
            set end of recs to "S" & US & (name of presentation of w) & US & (idx as text) & US & stText & US & (fx as text) & US & mState & US & mPos & US & (mShape as text) & US & notesText
        end if
        return my joinList(recs, RS)
        """

    /// Cheap per-tick show poll. `mediaShape` is the index of the media shape found by the
    /// last full poll on this slide, or 0 for none.
    static func fastShow(mediaShape: Int) -> String {
        """
        if (count of slide show windows) = 0 then return "NOSHOW"
        set v to slideshow view of slide show window 1
        set idx to -1
        try
            set idx to slide index of slide of v
        end try
        set stText to my stateName(slide state of v)
        set mState to ""
        set mPos to "0"
        if \(mediaShape) > 0 then
            try
                set pl to get player from v for (shape \(mediaShape) of slide of v)
                set ps to player state of pl
                set mState to "notready"
                if ps is player state playing then set mState to "playing"
                if ps is player state paused then set mState to "paused"
                if ps is player state stopped then set mState to "stopped"
                set mPos to (current position of pl) as text
            end try
        end if
        return (idx as text) & US & stText & US & mState & US & mPos
        """
    }

    static func structure(of name: String) -> String {
        """
        set p to presentation \(AS.literal(name))
        set flags to {}
        repeat with i from 1 to count of slides of p
            set end of flags to (hidden of slide show transition of slide i of p) as text
        end repeat
        set recs to {"H" & US & my joinList(flags, ",")}
        try
            set sp to section properties of p
            repeat with k from 1 to (get count of sections sp)
                set end of recs to "X" & US & (get id of section sp at position k) & US & (get name of section sp at position k) & US & ((get first slide of section sp at position k) as text) & US & ((get slide count of section sp at position k) as text)
            end repeat
        end try
        return my joinList(recs, RS)
        """
    }

    /// Runs `body` with `v` bound to the running show's view; returns `orElse` if no show.
    static func inShow(_ body: String, orElse: String = "NOSHOW") -> String {
        """
        if (count of slide show windows) = 0 then return \(AS.literal(orElse))
        set v to slideshow view of slide show window 1
        \(body)
        return ""
        """
    }

    static let next = stepScript("go to next slide v")
    static let previous = stepScript("go to previous slide v")

    private static func stepScript(_ command: String) -> String {
        """
        if (count of slide show windows) = 0 then return "NOSHOW"
        set v to slideshow view of slide show window 1
        set beforeIdx to -1
        try
            set beforeIdx to slide index of slide of v
        end try
        \(command)
        set afterIdx to -1
        try
            set afterIdx to slide index of slide of v
        end try
        return (beforeIdx as text) & US & (afterIdx as text)
        """
    }

    static let showSlideIndex = """
        if (count of slide show windows) = 0 then return "NOSHOW"
        return (slide index of slide of slideshow view of slide show window 1) as text
        """

    static let currentEditSlide = """
        try
            return (slide index of slide of view of document window 1) as text
        end try
        return "1"
        """

    static func selectSlide(_ n: Int) -> String {
        """
        set p to active presentation
        set n to \(n)
        if n < 1 then set n to 1
        if n > (count of slides of p) then set n to count of slides of p
        go to slide (view of document window 1) number n
        """
    }

    /// Ends any show and selects slide n in the editor of the show's presentation.
    static func exitShowAndSelect(_ n: Int) -> String {
        """
        set pName to name of active presentation
        if (count of slide show windows) > 0 then set pName to name of presentation of slide show window 1
        my endShowAndWait()
        -- A reference obtained through the show window dies with it, so look up by name.
        set p to presentation pName
        set n to \(n)
        if n > (count of slides of p) then set n to count of slides of p
        go to slide (view of document window 1) number n
        """
    }

    static let startAll = """
        set pName to name of active presentation
        if (count of slide show windows) > 0 then set pName to name of presentation of slide show window 1
        my endShowAndWait()
        -- A reference obtained through the show window dies with it, so look up by name.
        set p to presentation pName
        set ss to slide show settings of p
        set range type of ss to slide show range show all
        my runShow(ss)
        """

    static func startRange(from n: Int) -> String {
        """
        set pName to name of active presentation
        if (count of slide show windows) > 0 then set pName to name of presentation of slide show window 1
        my endShowAndWait()
        -- A reference obtained through the show window dies with it, so look up by name.
        set p to presentation pName
        set ss to slide show settings of p
        set lastN to count of slides of p
        set n to \(n)
        if n > lastN then set n to lastN
        set range type of ss to slide show range
        set starting slide of ss to n
        set ending slide of ss to lastN
        my runShow(ss)
        """
    }

    static func setHidden(slide n: Int, hidden: Bool) -> String {
        """
        set p to active presentation
        if (count of slide show windows) > 0 then set p to presentation of slide show window 1
        if \(n) < 1 or \(n) > (count of slides of p) then return "RANGE"
        set hidden of slide show transition of slide \(n) of p to \(hidden)
        """
    }

    static func sectionFirstSlide(named name: String) -> String {
        """
        set p to active presentation
        if (count of slide show windows) > 0 then set p to presentation of slide show window 1
        set sp to section properties of p
        repeat with k from 1 to (get count of sections sp)
            if (get name of section sp at position k) is \(AS.literal(name)) then
                considering case
                    if (get name of section sp at position k) = \(AS.literal(name)) then return (get first slide of section sp at position k) as text
                end considering
            end if
        end repeat
        return "0"
        """
    }

    static func media(_ body: String) -> String {
        """
        if (count of slide show windows) = 0 then return "NOSHOW"
        set v to slideshow view of slide show window 1
        set s to slide of v
        repeat with k from 1 to count of shapes of s
            if shape type of shape k of s is shape type media then
                set pl to get player from v for (shape k of s)
                \(body)
                return ""
            end if
        end repeat
        return "NOMEDIA"
        """
    }

    static func hasPresentation(_ name: String) -> String {
        """
        if exists presentation \(AS.literal(name)) then return "YES"
        return "NO"
        """
    }

    static func open(_ path: String) -> String {
        "open (POSIX file \(AS.literal(path)))"
    }

    static func close(name: String?, mode: CloseMode) -> String {
        let target = name.map { "presentation \(AS.literal($0))" } ?? "active presentation"
        let closing = switch mode {
        case .abort: "close p saving no"
        case .force: "close p saving no"
        case .save: "save p\nclose p saving no"
        }
        return """
        if not (exists \(target)) then return "NOTFOUND"
        set p to \(target)
        set nm to name of p
        if \(mode == .abort ? "true" : "false") and not (saved of p) then return "UNSAVED " & nm
        \(closing)
        """
    }
}
