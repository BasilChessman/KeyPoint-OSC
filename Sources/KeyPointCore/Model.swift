import Foundation

public enum BackendKind: String, Codable, Sendable, CaseIterable {
    case powerpoint
    case keynote

    public var appName: String {
        switch self {
        case .powerpoint: "PowerPoint"
        case .keynote: "Keynote"
        }
    }
}

/// What a backend can do. Unsupported actions are ignored (and logged), and unsupported
/// feedbacks are simply not sent, so a client sees the gaps rather than wrong values.
public enum Capability: String, Codable, Sendable, CaseIterable {
    case navigate // next / previous / first / last
    case gotoSlide
    case sections
    case hideSlides
    case startShow
    case endShow
    case blackWhite
    case laserPointer
    case pauseResume
    case media
    case mediaDuration
    case buildCount
    case buildPosition
    case notes
    case openClose
    case activatePresentation
}

public enum ShowState: String, Sendable, Equatable {
    case edit, running, paused
}

public enum ScreenOverlay: String, Sendable, Equatable {
    case none, black, white
}

public enum MediaState: String, Sendable, Equatable {
    case playing, paused, stopped, notready
}

public struct MediaInfo: Equatable, Sendable {
    public var state: MediaState
    /// Playhead position in ms, counted from the trimmed start.
    public var position: Int
    /// Length of the media file in ms, if the backend can find it.
    public var duration: Int?
    /// Trimmed off the start and end of the file (PowerPoint's Trim Video), in ms.
    public var trimStart: Int
    public var trimEnd: Int

    public init(state: MediaState, position: Int, duration: Int? = nil, trimStart: Int = 0, trimEnd: Int = 0) {
        self.state = state
        self.position = position
        self.duration = duration
        self.trimStart = trimStart
        self.trimEnd = trimEnd
    }

    /// What plays: the file minus the trims.
    public var trimmedDuration: Int? { duration.map { max($0 - trimStart - trimEnd, 0) } }

    /// Time left until the clip ends.
    public var remaining: Int? { trimmedDuration.map { max($0 - position, 0) } }
}

public struct SectionInfo: Equatable, Sendable, Codable {
    public var id: String
    public var name: String
    public var firstSlide: Int
    public var lastSlide: Int
    public var slideCount: Int

    public init(id: String, name: String, firstSlide: Int, slideCount: Int) {
        self.id = id
        self.name = name
        self.firstSlide = firstSlide
        self.slideCount = slideCount
        self.lastSlide = firstSlide + max(slideCount, 1) - 1
    }
}

public struct PresentationInfo: Equatable, Sendable {
    public var name: String
    /// Containing folder, empty for unsaved presentations.
    public var path: String
    public var slideCount: Int
    public var saved: Bool
    public var slideshow: Bool
    /// Per-slide hidden flags, index 0 = slide 1. Empty if not loaded.
    public var hidden: [Bool]
    public var sections: [SectionInfo]

    public init(name: String, path: String = "", slideCount: Int, saved: Bool = true, slideshow: Bool = false,
                hidden: [Bool] = [], sections: [SectionInfo] = []) {
        self.name = name
        self.path = path
        self.slideCount = slideCount
        self.saved = saved
        self.slideshow = slideshow
        self.hidden = hidden
        self.sections = sections
    }

    public var visibleSlideCount: Int {
        hidden.isEmpty ? slideCount : hidden.prefix(slideCount).filter { !$0 }.count
    }

    public func isHidden(_ slide: Int) -> Bool {
        slide >= 1 && slide <= hidden.count && hidden[slide - 1]
    }

    /// Section containing `slide` (1-based index into `sections`).
    public func sectionIndex(of slide: Int) -> Int? {
        sections.firstIndex { slide >= $0.firstSlide && slide <= $0.lastSlide }.map { $0 + 1 }
    }

    /// Visible slides after `slide`, up to and including `last`.
    public func visibleSlides(after slide: Int, through last: Int) -> Int {
        guard slide < last else { return 0 }
        return (slide + 1...last).filter { !isHidden($0) }.count
    }
}

public struct ShowInfo: Equatable, Sendable {
    public var presentationName: String
    /// Real 1-based slide index.
    public var currentSlide: Int
    public var state: ShowState
    public var overlay: ScreenOverlay
    public var buildPosition: Int?
    public var buildCount: Int?
    public var notes: String?
    public var media: MediaInfo?

    public init(presentationName: String, currentSlide: Int, state: ShowState = .running, overlay: ScreenOverlay = .none,
                buildPosition: Int? = nil, buildCount: Int? = nil, notes: String? = nil, media: MediaInfo? = nil) {
        self.presentationName = presentationName
        self.currentSlide = currentSlide
        self.state = state
        self.overlay = overlay
        self.buildPosition = buildPosition
        self.buildCount = buildCount
        self.notes = notes
        self.media = media
    }
}

/// Everything a backend reports in one poll.
public struct BackendSnapshot: Equatable, Sendable {
    public var presentations: [PresentationInfo]
    /// Name of the presentation feedback refers to (the one in a show, else the front one).
    public var activePresentation: String?
    public var show: ShowInfo?

    public init(presentations: [PresentationInfo] = [], activePresentation: String? = nil, show: ShowInfo? = nil) {
        self.presentations = presentations
        self.activePresentation = activePresentation
        self.show = show
    }

    public static let empty = BackendSnapshot()

    public var active: PresentationInfo? {
        presentations.first { $0.name == activePresentation }
    }
}
