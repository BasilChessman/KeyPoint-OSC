import Foundation
import Testing
@testable import KeyPointCore

@Suite struct RouterTests {
    func route(_ address: String, _ args: OSCArgument...) -> Command? {
        Router.route(OSCMessage(address, args))
    }

    @Test func navigation() {
        #expect(route("/oscpoint/next") == .slide(.next))
        #expect(route("/oscpoint/previous") == .slide(.previous))
        #expect(route("/oscpoint/goto/slide", .int(4)) == .slide(.gotoSlide(4)))
        #expect(route("/oscpoint/goto/slide", .float(4)) == .slide(.gotoSlide(4)))
        #expect(route("/oscpoint/goto/slide") == nil)
        #expect(route("/oscpoint/goto/slide/first") == .slide(.gotoFirst))
        #expect(route("/oscpoint/goto/slide/last") == .slide(.gotoLast))
    }

    @Test func textArgumentsAcceptStringOrUTF8Blob() {
        #expect(route("/oscpoint/goto/section", .string("Intro")) == .slide(.gotoSection("Intro")))
        #expect(route("/oscpoint/goto/section", .blob(Data("Médias".utf8))) == .slide(.gotoSection("Médias")))
    }

    @Test func toggles() {
        #expect(route("/oscpoint/slideshow/black") == .slide(.black(nil)))
        #expect(route("/oscpoint/slideshow/black", .int(1)) == .slide(.black(true)))
        #expect(route("/oscpoint/slideshow/white", .int(0)) == .slide(.white(false)))
        #expect(route("/oscpoint/slideshow/laserpointer", .bool(true)) == .slide(.laserPointer(true)))
    }

    @Test func showControl() {
        #expect(route("/oscpoint/slideshow/start") == .slide(.startShow(from: nil)))
        #expect(route("/oscpoint/slideshow/start", .int(5)) == .slide(.startShow(from: 5)))
        #expect(route("/oscpoint/slideshow/start/current") == .slide(.startFromCurrent))
        #expect(route("/oscpoint/slideshow/end") == .slide(.endShow))
    }

    @Test func media() {
        #expect(route("/oscpoint/media/playpause") == .slide(.mediaPlayPause))
        #expect(route("/oscpoint/media/goto/position/back", .int(5000)) == .slide(.mediaSeek(.back(5000))))
        #expect(route("/oscpoint/media/goto/position/percent", .float(50)) == .slide(.mediaSeek(.percent(50))))
    }

    @Test func filesNeedOptIn() {
        let close = route("/oscpoint/files/close/force", .string("a.pptx"))
        #expect(close == .filesClose(name: "a.pptx", mode: .force))
        #expect(close?.needsFileAccess == true)
        #expect(route("/oscpoint/files/close") == .filesClose(name: nil, mode: .abort))
        #expect(route("/oscpoint/presentations/activate", .string("a.pptx"))?.needsFileAccess == false)
    }

    @Test func keypointPrefix() {
        #expect(route("/keypoint/next") == .slide(.next))
        #expect(route("/keypoint/goto/slide", .int(2)) == .slide(.gotoSlide(2)))
        #expect(route("/keypoint/ping") == .ping)
        #expect(route("/keypoint/app/select", .string("powerpoint")) == .selectApp(.powerpoint))
        #expect(route("/keypoint/app/select", .string("nope")) == nil)
        #expect(route("/oscpoint/ping") == nil) // KeyPoint-only
    }

    @Test func systemAndUnknown() {
        #expect(route("/oscpoint/actions/disable") == .setActionsEnabled(false))
        #expect(route("/oscpoint/feedbacks/refresh") == .refreshFeedbacks)
        #expect(route("/oscpoint/nope") == nil)
        #expect(route("/other/next") == nil)
        #expect(route("/oscpointnext") == nil)
        #expect(Router.route(OSCMessage("/keypoint/next"), prefix: "/keypoint") == .slide(.next))
    }
}
