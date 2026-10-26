import Foundation

public enum MediaSeek: Equatable, Sendable {
    case fromStart(Int)
    case beforeEnd(Int)
    case forward(Int)
    case back(Int)
    case percent(Double)
}

public enum CloseMode: String, Equatable, Sendable {
    /// Don't close if there are unsaved changes.
    case abort
    /// Discard unsaved changes.
    case force
    /// Save over the file, then close.
    case save
}

/// An action carried out by the active backend. `nil` toggles for on/off actions.
public enum SlideAction: Equatable, Sendable {
    case next
    case previous
    case gotoSlide(Int)
    case gotoFirst
    case gotoLast
    case gotoSection(String)
    case hideSlide(Int)
    case unhideSlide(Int)
    case startShow(from: Int?)
    case startFromCurrent
    case startSection(String)
    case endShow
    case black(Bool?)
    case white(Bool?)
    case laserPointer(Bool?)
    case pause
    case resume
    case mediaPlay
    case mediaPause
    case mediaPlayPause
    case mediaStop
    case mediaSeek(MediaSeek)
    case mediaBookmarkNext
    case mediaBookmarkPrevious
    case activatePresentation(String)
    case openFile(URL)
    case closePresentation(name: String?, mode: CloseMode)

    /// The capability needed to perform this action.
    public var requiredCapability: Capability {
        switch self {
        case .next, .previous, .gotoFirst, .gotoLast: .navigate
        case .gotoSlide: .gotoSlide
        case .gotoSection, .startSection: .sections
        case .hideSlide, .unhideSlide: .hideSlides
        case .startShow, .startFromCurrent: .startShow
        case .endShow: .endShow
        case .black, .white: .blackWhite
        case .laserPointer: .laserPointer
        case .pause, .resume: .pauseResume
        case .mediaPlay, .mediaPause, .mediaPlayPause, .mediaStop, .mediaSeek, .mediaBookmarkNext, .mediaBookmarkPrevious:
            .media
        case .activatePresentation: .activatePresentation
        case .openFile, .closePresentation: .openClose
        }
    }
}

/// A routed OSC command: either a backend action or something the engine handles itself.
public enum Command: Equatable, Sendable {
    case slide(SlideAction)
    case setActionsEnabled(Bool)
    case setFeedbacksEnabled(Bool)
    case refreshFeedbacks
    case filesSetPath(String)
    case filesList
    case filesOpen(String)
    case filesClose(name: String?, mode: CloseMode)
    /// Reply with `/keypoint/pong` so a controller can tell the connection is alive.
    case ping
    case selectApp(BackendMode)

    /// File commands need the local "allow file access" opt-in.
    public var needsFileAccess: Bool {
        switch self {
        case .filesSetPath, .filesList, .filesOpen, .filesClose: true
        default: false
        }
    }
}
