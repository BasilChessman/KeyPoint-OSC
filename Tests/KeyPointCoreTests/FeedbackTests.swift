import Foundation
import Testing
@testable import KeyPointCore

@Suite struct FeedbackTests {
    let allCaps = FeedbackContext(capabilities: Set(Capability.allCases))

    var deck: PresentationInfo {
        PresentationInfo(name: "Deck.pptx", path: "/Users/me", slideCount: 6, saved: true, slideshow: true,
                         hidden: [false, false, true, false, false, false],
                         sections: [SectionInfo(id: "1", name: "Intro", firstSlide: 1, slideCount: 3),
                                    SectionInfo(id: "2", name: "Média", firstSlide: 4, slideCount: 3)])
    }

    func snapshot(slide: Int, build: Int? = 0, show: Bool = true) -> BackendSnapshot {
        BackendSnapshot(presentations: [deck], activePresentation: "Deck.pptx",
                        show: show ? ShowInfo(presentationName: "Deck.pptx", currentSlide: slide, buildPosition: build,
                                              buildCount: 3, notes: "Line 1\nLine 2 ✓") : nil)
    }

    func values(_ msgs: [OSCMessage]) -> [String: [OSCArgument]] {
        Dictionary(msgs.map { ($0.address, $0.arguments) }, uniquingKeysWith: { a, _ in a })
    }

    @Test func fullStateDuringShow() {
        let v = values(FeedbackPublisher().stateMessages(snapshot(slide: 2, build: 1), context: allCaps))
        #expect(v["/oscpoint/slideshow/state"] == [.string("running")])
        #expect(v["/oscpoint/slideshow/currentslide"] == [.int(2)])
        #expect(v["/oscpoint/presentation/slides/count"] == [.int(6)])
        #expect(v["/oscpoint/presentation/slides/count/visible"] == [.int(5)])
        #expect(v["/oscpoint/slideshow/slidesremaining"] == [.int(3)]) // 4, 5, 6 (3 is hidden)
        #expect(v["/oscpoint/slideshow/builds/remaining"] == [.int(2)])
        #expect(v["/oscpoint/slideshow/section/index"] == [.int(1)])
        #expect(v["/oscpoint/slideshow/section/slidesremaining"] == [.int(0)]) // only hidden 3 left in Intro
        #expect(v["/oscpoint/slideshow/notes"] == [.string("Line 1\rLine 2 ?")])
        #expect(v["/oscpoint/slideshow/notes-utf8"] == [.blob(Data("Line 1\rLine 2 ✓".utf8))])
    }

    @Test func presentationJSONMatchesOSCPointShape() throws {
        let v = values(FeedbackPublisher().stateMessages(snapshot(slide: 1), context: allCaps))
        guard case .string(let ascii) = v["/oscpoint/v2/presentation"]?[0],
              case .blob(let utf8) = v["/oscpoint/v2/presentation"]?[1] else {
            Issue.record("missing presentation JSON")
            return
        }
        #expect(ascii.allSatisfy { $0.isASCII })
        #expect(ascii.hasPrefix(#"{"name":"Deck.pptx","path":"/Users/me","slideCount":6,"saved":true,"active":true"#))
        // Both forms decode to the same object.
        let a = try JSONSerialization.jsonObject(with: Data(ascii.utf8)) as? NSDictionary
        let b = try JSONSerialization.jsonObject(with: utf8) as? NSDictionary
        #expect(a == b)
        let sections = a?["sections"] as? [[String: Any]]
        #expect(sections?.last?["name"] as? String == "Média")
        #expect(sections?.last?["lastSlide"] as? Int == 6)
    }

    @Test func blankPresentationWhenNothingOpen() {
        let v = values(FeedbackPublisher().stateMessages(.empty, context: allCaps))
        #expect(v["/oscpoint/v2/presentation"]?.first ==
            .string(#"{"name":"","path":"","slideCount":0,"saved":false,"active":false,"slideshow":false,"sections":null}"#))
        #expect(v["/oscpoint/presentation/name"] == nil)
    }

    @Test func onlyChangesAreResent() {
        let pub = FeedbackPublisher()
        let first = pub.update(snapshot(slide: 1), context: allCaps)
        #expect(first.count > 10)
        #expect(pub.update(snapshot(slide: 1), context: allCaps).isEmpty)
        let next = pub.update(snapshot(slide: 1, build: 1), context: allCaps)
        #expect(Set(next.map(\.address)) == [
            "/oscpoint/v2/event",
            "/oscpoint/slideshow/builds/position",
            "/oscpoint/slideshow/builds/remaining",
        ])
        pub.invalidate()
        #expect(pub.update(snapshot(slide: 1, build: 1), context: allCaps).count == first.count)
    }

    @Test func unsupportedFeedbacksAreOmitted() {
        let ctx = FeedbackContext(capabilities: [.navigate, .notes])
        let addresses = Set(FeedbackPublisher().stateMessages(snapshot(slide: 2), context: ctx).map(\.address))
        #expect(!addresses.contains("/oscpoint/slideshow/builds/count"))
        #expect(!addresses.contains("/oscpoint/slideshow/section/name"))
        #expect(addresses.contains("/oscpoint/slideshow/notes"))
    }

    @Test func events() {
        let pub = FeedbackPublisher()
        let edit = snapshot(slide: 1, show: false)
        #expect(pub.events(from: .empty, to: edit).map { $0.arguments[0] } ==
            [.string("presentation_open"), .string("window_activate")])
        let begin = pub.events(from: edit, to: snapshot(slide: 1))
        #expect(begin.first?.arguments == [.string("slideshow_begin"), .string("Deck.pptx"), .blob(Data("Deck.pptx".utf8)), .int(1)])
        let slide = pub.events(from: snapshot(slide: 1), to: snapshot(slide: 2))
        #expect(slide.first?.arguments == [.string("slideshow_next_slide"), .int(2), .int(0), .int(3)])
        let build = pub.events(from: snapshot(slide: 2), to: snapshot(slide: 2, build: 1))
        #expect(build.first?.arguments.first == .string("slideshow_next_build"))
        #expect(pub.events(from: snapshot(slide: 2), to: edit).first?.arguments.first == .string("slideshow_end"))
    }

    @Test func showOnlyFeedbackIsResentOnNextShow() {
        let pub = FeedbackPublisher()
        _ = pub.update(snapshot(slide: 1), context: allCaps)
        _ = pub.update(snapshot(slide: 1, show: false), context: allCaps)
        let again = pub.update(snapshot(slide: 1), context: allCaps).map(\.address)
        #expect(again.contains("/oscpoint/slideshow/currentslide"))
        #expect(again.contains("/oscpoint/slideshow/notes-utf8"))
    }

    @Test func utf8TruncationKeepsCharactersWhole() {
        let data = Data("aé".utf8) // 61 C3 A9
        #expect(FeedbackPublisher.truncateUTF8(data, to: 2) == Data("a".utf8))
        #expect(FeedbackPublisher.truncateUTF8(data, to: 3) == data)
    }

    @Test func keypointExtras() {
        var snap = snapshot(slide: 2)
        snap.show?.overlay = .black
        var ctx = allCaps
        ctx.app = .keynote
        let v = values(FeedbackPublisher(prefix: "/keypoint").stateMessages(snap, context: ctx))
        #expect(v["/keypoint/app"] == [.string("keynote")])
        #expect(v["/keypoint/slideshow/overlay"] == [.string("black")])
        guard case .string(let caps) = v["/keypoint/capabilities"]?.first else {
            Issue.record("missing capabilities")
            return
        }
        #expect(caps.hasPrefix(#"["navigate","gotoSlide""#))
        // The OSCPoint format leaves them out.
        let o = values(FeedbackPublisher(prefix: "/oscpoint").stateMessages(snap, context: ctx))
        #expect(o["/oscpoint/app"] == nil && o["/oscpoint/slideshow/overlay"] == nil)
    }

    func mediaSnapshot(slide: Int, _ media: MediaInfo?) -> BackendSnapshot {
        var snap = snapshot(slide: slide)
        snap.show?.media = media
        return snap
    }

    @Test func mediaDurationAndTrims() {
        let media = MediaInfo(state: .playing, position: 4000, duration: 59078, trimStart: 10000, trimEnd: 20000)
        let v = values(FeedbackPublisher().stateMessages(mediaSnapshot(slide: 4, media), context: allCaps))
        #expect(v["/oscpoint/slideshow/media/duration"] == [.int(59078)])
        #expect(v["/oscpoint/slideshow/media/durationtrimmed"] == [.int(29078)])
        #expect(v["/oscpoint/slideshow/media/startpoint"] == [.int(10000)])
        #expect(v["/oscpoint/slideshow/media/endpoint"] == [.int(39078)])
        #expect(v["/oscpoint/slideshow/media/remaining"] == [.int(25078)])
    }

    @Test func keypointClearsMediaValues() {
        let kp = FeedbackPublisher(prefix: "/keypoint")
        let playing = MediaInfo(state: .playing, position: 1000, duration: 5000)
        _ = kp.update(mediaSnapshot(slide: 4, playing), context: allCaps)
        // Length not known yet for another clip: cleared rather than left over.
        let unknown = values(kp.update(mediaSnapshot(slide: 5, MediaInfo(state: .notready, position: 0)), context: allCaps))
        #expect(unknown["/keypoint/slideshow/media/remaining"] == [.string("")])
        // No media: empty state, and the next clip's values are all resent.
        let none = values(kp.update(mediaSnapshot(slide: 6, nil), context: allCaps))
        #expect(none["/keypoint/slideshow/media/state"] == [.string("")])
        let back = values(kp.update(mediaSnapshot(slide: 4, playing), context: allCaps))
        #expect(back["/keypoint/slideshow/media/position"] == [.int(1000)])
        #expect(back["/keypoint/slideshow/media/remaining"] == [.int(4000)])
        // The OSCPoint format is unchanged: nothing sent for a slide without media.
        let osc = values(FeedbackPublisher().stateMessages(mediaSnapshot(slide: 6, nil), context: allCaps))
        #expect(osc["/oscpoint/slideshow/media/state"] == nil)
    }

    @Test func jsonEscaping() {
        let v = JSONValue.object([("k", .string("a\"b\\c\n✓😀"))])
        #expect(v.serialized() == #"{"k":"a\"b\\c\n✓😀"}"#)
        #expect(v.serialized(asciiOnly: true) == "{\"k\":\"a\\\"b\\\\c\\n\\u2713\\ud83d\\ude00\"}")
    }
}
