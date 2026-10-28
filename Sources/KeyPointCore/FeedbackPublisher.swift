import Foundation

/// Engine-level values that feedback reports alongside backend state.
public struct FeedbackContext: Equatable, Sendable {
    public var capabilities: Set<Capability>
    public var filesEnabled: Bool
    /// Active folder relative to the home directory, and its full path.
    public var activeFolder: String
    public var activeFolderFullPath: String
    /// The app being controlled, reported under the KeyPoint prefix only.
    public var app: BackendKind?

    public init(capabilities: Set<Capability>, filesEnabled: Bool = false, activeFolder: String = "",
                activeFolderFullPath: String = "", app: BackendKind? = nil) {
        self.app = app
        self.capabilities = capabilities
        self.filesEnabled = filesEnabled
        self.activeFolder = activeFolder
        self.activeFolderFullPath = activeFolderFullPath
    }
}

/// Turns backend snapshots into OSCPoint-compatible feedback messages, sending each
/// address only when its value changes, plus `/v2/event` messages for transitions.
public final class FeedbackPublisher {
    public let prefix: String
    /// UDP datagrams top out near 64 KB; OSCPoint truncates notes to 32,000 characters.
    public static let maxNotesBytes = 32_000

    private var lastSent: [String: Data] = [:]
    private var previous: BackendSnapshot?

    public init(prefix: String = Router.defaultPrefix) {
        self.prefix = prefix
    }

    /// KeyPoint-only feedback (active app, capabilities, black/white) is sent only under `/keypoint`.
    var extended: Bool { prefix == Router.keypointPrefix }

    static let mediaDurationPaths = ["slideshow/media/duration", "slideshow/media/durationtrimmed",
                                     "slideshow/media/startpoint", "slideshow/media/endpoint", "slideshow/media/remaining"]

    /// Forget what was sent, so the next update resends everything.
    public func invalidate() {
        lastSent.removeAll()
    }

    /// Messages to send for a new snapshot: events first, then changed state.
    public func update(_ snapshot: BackendSnapshot, context: FeedbackContext) -> [OSCMessage] {
        let transitions = previous.map { events(from: $0, to: snapshot) } ?? []
        if previous?.show != nil && snapshot.show == nil {
            // Show-only feedback is resent in full when the next show starts.
            lastSent = lastSent.filter { !$0.key.hasPrefix(prefix + "/slideshow/") || $0.key == prefix + "/slideshow/state" }
        }
        if extended, previous?.show?.media != nil, snapshot.show?.media == nil {
            // Clients clear media values on the empty state, so resend them all for the next clip.
            lastSent = lastSent.filter { !$0.key.hasPrefix(prefix + "/slideshow/media/") }
        }
        previous = snapshot
        let changed = stateMessages(snapshot, context: context).filter { msg in
            let data = OSCEncoder.encode(msg)
            guard lastSent[msg.address] != data else { return false }
            lastSent[msg.address] = data
            return true
        }
        return transitions + changed
    }

    public func startupEvent(version: String) -> OSCMessage {
        event("add_in_startup", [.string(version)])
    }

    // MARK: State

    public func stateMessages(_ snap: BackendSnapshot, context: FeedbackContext) -> [OSCMessage] {
        let caps = context.capabilities
        var out: [OSCMessage] = []
        func add(_ path: String, _ args: OSCArgument...) { out.append(OSCMessage(prefix + "/" + path, args)) }

        add("v2/presentations", .string(JSONValue.array(snap.presentations.map { json($0, snap) }).serialized(asciiOnly: true)))
        let current = snap.active.map { json($0, snap) } ?? Self.blankPresentationJSON
        add("v2/presentation", .string(current.serialized(asciiOnly: true)), utf8(current.serialized()))
        add("v2/files/enabled", .bool(context.filesEnabled))
        add("v2/files/activefolder", .string(context.activeFolder.oscASCII), utf8(context.activeFolder))
        add("v2/files/activefolder/fullpath", .string(context.activeFolderFullPath.oscASCII), utf8(context.activeFolderFullPath))
        if extended {
            add("app", .string(context.app?.rawValue ?? "none"))
            add("capabilities", .string(JSONValue.array(Capability.allCases.filter(caps.contains).map { .string($0.rawValue) }).serialized()))
        }

        guard let pres = snap.active else { return out }
        add("presentation/name", .string(pres.name.oscASCII), utf8(pres.name))
        add("presentation/slides/count", .int(Int32(clamping: pres.slideCount)))
        add("presentation/slides/count/visible", .int(Int32(clamping: pres.visibleSlideCount)))

        guard let show = snap.show, show.presentationName == pres.name else {
            add("slideshow/state", .string(ShowState.edit.rawValue))
            return out
        }
        add("slideshow/state", .string(show.state.rawValue))
        if extended && caps.contains(.blackWhite) {
            add("slideshow/overlay", .string(show.overlay.rawValue))
        }
        add("slideshow/currentslide", .int(Int32(clamping: show.currentSlide)))
        add("slideshow/slidesremaining", .int(Int32(clamping: pres.visibleSlides(after: show.currentSlide, through: pres.slideCount))))

        if let count = show.buildCount, caps.contains(.buildCount) {
            add("slideshow/builds/count", .int(Int32(clamping: count)))
            if let pos = show.buildPosition, caps.contains(.buildPosition) {
                add("slideshow/builds/position", .int(Int32(clamping: pos)))
                add("slideshow/builds/remaining", .int(Int32(clamping: max(count - pos, 0))))
            }
        } else if let pos = show.buildPosition, caps.contains(.buildPosition) {
            add("slideshow/builds/position", .int(Int32(clamping: pos)))
        }

        if let notes = show.notes, caps.contains(.notes) {
            let normalized = notes.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
            let bytes = Data(normalized.utf8)
            let truncated = bytes.count > Self.maxNotesBytes ? Self.truncateUTF8(bytes, to: Self.maxNotesBytes) : bytes
            let text = String(decoding: truncated, as: UTF8.self)
            add("slideshow/notes", .string(text.oscASCII))
            add("slideshow/notes-utf8", .blob(truncated))
        }

        if caps.contains(.sections), let idx = pres.sectionIndex(of: show.currentSlide) {
            let section = pres.sections[idx - 1]
            add("slideshow/section/index", .int(Int32(idx)))
            add("slideshow/section/name", .string(section.name.oscASCII), utf8(section.name))
            add("slideshow/section/slidesremaining",
                .int(Int32(clamping: pres.visibleSlides(after: show.currentSlide, through: section.lastSlide))))
        }

        if let media = show.media, caps.contains(.media) {
            add("slideshow/media/state", .string(media.state.rawValue))
            add("slideshow/media/position", .int(Int32(clamping: media.position)))
            if let duration = media.duration, let trimmed = media.trimmedDuration, let remaining = media.remaining,
               caps.contains(.mediaDuration) {
                add("slideshow/media/duration", .int(Int32(clamping: duration)))
                add("slideshow/media/durationtrimmed", .int(Int32(clamping: trimmed)))
                add("slideshow/media/startpoint", .int(Int32(clamping: media.trimStart)))
                add("slideshow/media/endpoint", .int(Int32(clamping: max(duration - media.trimEnd, 0))))
                add("slideshow/media/remaining", .int(Int32(clamping: remaining)))
            } else if extended && caps.contains(.mediaDuration) {
                // Length not known (yet): clear values left over from another clip.
                for path in Self.mediaDurationPaths { add(path, .string("")) }
            }
        } else if extended && caps.contains(.media) {
            // No media on this slide: an empty state tells KeyPoint clients to clear media values.
            add("slideshow/media/state", .string(""))
        }
        return out
    }

    // MARK: Events

    public func events(from old: BackendSnapshot, to new: BackendSnapshot) -> [OSCMessage] {
        var out: [OSCMessage] = []
        let oldNames = Set(old.presentations.map(\.name))
        let newNames = Set(new.presentations.map(\.name))
        for p in new.presentations where !oldNames.contains(p.name) {
            out.append(event("presentation_open", nameArgs(p.name)))
        }
        for p in old.presentations where !newNames.contains(p.name) {
            out.append(event("presentation_close", nameArgs(p.name)))
        }
        if let active = new.activePresentation, active != old.activePresentation {
            out.append(event("window_activate", nameArgs(active)))
        }

        switch (old.show, new.show) {
        case (nil, let show?):
            out.append(event("slideshow_begin", nameArgs(show.presentationName) + [.int(Int32(clamping: show.currentSlide))]))
        case (let show?, nil):
            out.append(event("slideshow_end", nameArgs(show.presentationName)))
        case (let a?, let b?) where a.presentationName != b.presentationName:
            out.append(event("slideshow_end", nameArgs(a.presentationName)))
            out.append(event("slideshow_begin", nameArgs(b.presentationName) + [.int(Int32(clamping: b.currentSlide))]))
        case (let a?, let b?):
            let clickArgs: [OSCArgument] = [
                .int(Int32(clamping: b.currentSlide)),
                .int(Int32(clamping: b.buildPosition ?? 0)),
                .int(Int32(clamping: b.buildCount ?? 0)),
            ]
            if a.currentSlide != b.currentSlide {
                out.append(event("slideshow_next_slide", clickArgs))
            } else if let pos = b.buildPosition, pos != a.buildPosition {
                out.append(event("slideshow_next_build", clickArgs))
            }
        default:
            break
        }
        return out
    }

    // MARK: Helpers

    static let blankPresentationJSON = JSONValue.object([
        ("name", .string("")), ("path", .string("")), ("slideCount", .int(0)), ("saved", .bool(false)),
        ("active", .bool(false)), ("slideshow", .bool(false)), ("sections", .null),
    ])

    private func json(_ p: PresentationInfo, _ snap: BackendSnapshot) -> JSONValue {
        .object([
            ("name", .string(p.name)),
            ("path", .string(p.path)),
            ("slideCount", .int(p.slideCount)),
            ("saved", .bool(p.saved)),
            ("active", .bool(p.name == snap.activePresentation)),
            ("slideshow", .bool(p.slideshow)),
            ("sections", p.sections.isEmpty ? .null : .array(p.sections.map { s in
                .object([
                    ("id", .string(s.id)), ("name", .string(s.name)), ("firstSlide", .int(s.firstSlide)),
                    ("lastSlide", .int(s.lastSlide)), ("slideCount", .int(s.slideCount)),
                ])
            })),
        ])
    }

    private func event(_ type: String, _ args: [OSCArgument]) -> OSCMessage {
        OSCMessage(prefix + "/v2/event", [.string(type)] + args)
    }

    private func nameArgs(_ name: String) -> [OSCArgument] {
        [.string(name.oscASCII), utf8(name)]
    }

    private func utf8(_ s: String) -> OSCArgument {
        .blob(Data(s.utf8))
    }

    /// Cut at a byte limit without splitting a multi-byte character.
    static func truncateUTF8(_ data: Data, to limit: Int) -> Data {
        var end = min(limit, data.count)
        while end > 0 && end < data.count && (data[data.startIndex + end] & 0xC0) == 0x80 { end -= 1 }
        return data.prefix(end)
    }
}
