import Foundation

/// Maps incoming OSC addresses to commands. Actions are accepted under `/keypoint/`
/// (KeyPoint's own Companion module) and `/oscpoint/` (OSCPoint-compatible clients).
/// The paths after the prefix are the same; `ping` and `app/select` are KeyPoint-only.
public enum Router {
    public static let keypointPrefix = "/keypoint"
    public static let oscpointPrefix = "/oscpoint"
    public static let defaultPrefix = oscpointPrefix

    public static func route(_ message: OSCMessage) -> Command? {
        route(message, prefix: keypointPrefix) ?? route(message, prefix: oscpointPrefix)
    }

    public static func route(_ message: OSCMessage, prefix: String) -> Command? {
        guard message.address.hasPrefix(prefix + "/") else { return nil }
        let path = String(message.address.dropFirst(prefix.count + 1))
        if prefix == keypointPrefix, let command = keypointOnly(path, message.arguments) {
            return command
        }
        let args = message.arguments
        let int = args.first?.intValue
        let text = args.first?.textValue
        let toggle: Bool? = int.map { $0 != 0 }

        switch path {
        case "next": return .slide(.next)
        case "previous": return .slide(.previous)
        case "goto/slide": return int.map { .slide(.gotoSlide($0)) }
        case "goto/slide/first": return .slide(.gotoFirst)
        case "goto/slide/last": return .slide(.gotoLast)
        case "goto/section": return text.map { .slide(.gotoSection($0)) }
        case "slide/hide": return int.map { .slide(.hideSlide($0)) }
        case "slide/unhide": return int.map { .slide(.unhideSlide($0)) }

        case "slideshow/start": return .slide(.startShow(from: int))
        case "slideshow/start/current": return .slide(.startFromCurrent)
        case "slideshow/start/section": return text.map { .slide(.startSection($0)) }
        case "slideshow/end": return .slide(.endShow)
        case "slideshow/black": return .slide(.black(toggle))
        case "slideshow/white": return .slide(.white(toggle))
        case "slideshow/laserpointer": return .slide(.laserPointer(toggle))
        case "slideshow/pause": return .slide(.pause)
        case "slideshow/resume": return .slide(.resume)

        case "media/play": return .slide(.mediaPlay)
        case "media/pause": return .slide(.mediaPause)
        case "media/playpause": return .slide(.mediaPlayPause)
        case "media/stop": return .slide(.mediaStop)
        case "media/goto/position/fromstart": return int.map { .slide(.mediaSeek(.fromStart($0))) }
        case "media/goto/position/beforeend": return int.map { .slide(.mediaSeek(.beforeEnd($0))) }
        case "media/goto/position/forward": return int.map { .slide(.mediaSeek(.forward($0))) }
        case "media/goto/position/back": return int.map { .slide(.mediaSeek(.back($0))) }
        case "media/goto/position/percent":
            return args.first?.doubleValue.map { .slide(.mediaSeek(.percent($0))) }
        case "media/goto/bookmark/next": return .slide(.mediaBookmarkNext)
        case "media/goto/bookmark/previous": return .slide(.mediaBookmarkPrevious)

        case "presentations/activate": return text.map { .slide(.activatePresentation($0)) }
        case "files/setpath": return text.map { .filesSetPath($0) }
        case "files/list": return .filesList
        case "files/open": return text.map { .filesOpen($0) }
        case "files/close": return .filesClose(name: text, mode: .abort)
        case "files/close/force": return .filesClose(name: text, mode: .force)
        case "files/close/save": return .filesClose(name: text, mode: .save)

        case "actions/enable": return .setActionsEnabled(true)
        case "actions/disable": return .setActionsEnabled(false)
        case "feedbacks/enable": return .setFeedbacksEnabled(true)
        case "feedbacks/disable": return .setFeedbacksEnabled(false)
        case "feedbacks/refresh": return .refreshFeedbacks
        default: return nil
        }
    }

    private static func keypointOnly(_ path: String, _ args: [OSCArgument]) -> Command? {
        switch path {
        case "ping": return .ping
        case "app/select": return args.first?.textValue.flatMap { BackendMode(rawValue: $0.lowercased()) }.map(Command.selectApp)
        default: return nil
        }
    }
}
