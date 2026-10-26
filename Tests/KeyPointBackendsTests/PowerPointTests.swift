import Foundation
import Testing
@testable import KeyPointBackends
@testable import KeyPointCore

@Suite struct PowerPointParsingTests {
    let us = String(AS.unit), rs = String(AS.record)

    @Test func parsesPollWithShowAndMedia() throws {
        let text = ["P\(us)Deck.pptx\(us)/Users/me\(us)true\(us)6",
                    "P\(us)Untitled\(us)\(us)false\(us)1",
                    "A\(us)Deck.pptx",
                    "S\(us)Deck.pptx\(us)4\(us)paused\(us)3\(us)playing\(us)1200\(us)2\(us)Notes\(us)with separators? no\rline 2"]
            .joined(separator: rs)
        let r = try PollResult.parse(text)
        #expect(r.presentations.count == 2)
        #expect(r.presentations[1] == .init(name: "Untitled", path: "", saved: false, slideCount: 1))
        #expect(r.active == "Deck.pptx")
        #expect(r.show?.slideIndex == 4)
        #expect(r.show?.state == "paused")
        #expect(r.show?.effectCount == 3)
        #expect(r.show?.media == MediaInfo(state: .playing, position: 1200))
        #expect(r.show?.mediaShape == 2)
        // Notes are the last field, so a stray unit separator inside them survives.
        #expect(r.show?.notes == "Notes\(us)with separators? no\rline 2")
    }

    @Test func parsesPollWithoutShowOrMedia() throws {
        let r = try PollResult.parse("A\(us)")
        #expect(r.presentations.isEmpty && r.active.isEmpty && r.show == nil)
        let s = try PollResult.parse("S\(us)D\(us)2\(us)running\(us)0\(us)\(us)0\(us)0\(us)")
        #expect(s.show?.media == nil)
        #expect(s.show?.notes == "")
    }

    @Test func parsesFastShow() throws {
        #expect(try FastResult.parse("NOSHOW") == nil)
        #expect(try FastResult.parse("3\(us)black\(us)\(us)0") == FastResult(slideIndex: 3, state: "black", media: nil))
        #expect(try FastResult.parse("4\(us)running\(us)paused\(us)900")?.media == MediaInfo(state: .paused, position: 900))
    }

    @Test func parsesStructure() throws {
        let text = "H\(us)false,false,true" + rs + "X\(us){A}\(us)Intro\(us)1\(us)2" + rs + "X\(us){B}\(us)Empty\(us)0\(us)0" + rs + "X\(us){C}\(us)Rest\(us)3\(us)1"
        let r = try StructureResult.parse(text, slideCount: 3)
        #expect(r.hidden == [false, false, true])
        #expect(r.sections.map(\.name) == ["Intro", "Rest"])
        #expect(r.sections.last?.lastSlide == 3)
    }

    @Test func appleScriptLiteralEscaping() {
        #expect(AS.literal(#"a "b" \c"#) == #""a \"b\" \\c""#)
    }
}

@Suite struct BuildTrackerTests {
    @Test func countsStepsWithinASlide() {
        var t = BuildTracker()
        t.observe(slide: 2, buildCount: 3)
        #expect(t.position == 0)
        t.stepped(forward: true, from: 2, to: 2)
        t.stepped(forward: true, from: 2, to: 2)
        #expect(t.position == 2)
        t.stepped(forward: false, from: 2, to: 2)
        #expect(t.position == 1)
        t.stepped(forward: true, from: 2, to: 2)
        t.stepped(forward: true, from: 2, to: 2)
        t.stepped(forward: true, from: 2, to: 2)
        #expect(t.position == 3) // clamped to count
    }

    @Test func goingBackLandsWithAllBuildsShown() {
        var t = BuildTracker()
        t.observe(slide: 4, buildCount: 0)
        t.stepped(forward: false, from: 4, to: 2)
        t.observe(slide: 2, buildCount: 3)
        #expect(t.position == 3)
        t.stepped(forward: true, from: 2, to: 4)
        t.observe(slide: 4, buildCount: 1)
        #expect(t.position == 0)
    }

    @Test func externalSlideChangeResets() {
        var t = BuildTracker()
        t.observe(slide: 1, buildCount: 2)
        t.stepped(forward: true, from: 1, to: 1)
        t.observe(slide: 5, buildCount: 2) // someone clicked on the Mac
        #expect(t.position == 0)
    }
}

/// Scripts compile against PowerPoint's dictionary, which catches syntax errors and
/// reserved-word clashes without running anything (compiling doesn't launch the app).
/// NSAppleScript isn't thread-safe, so these run one at a time on the main actor.
@MainActor
@Suite(.serialized, .enabled(if: FileManager.default.fileExists(atPath: "/Applications/Microsoft PowerPoint.app")))
struct PowerPointScriptCompileTests {
    nonisolated static let scripts: [(String, String)] = [
        ("poll", Scripts.poll), ("fastShow", Scripts.fastShow(mediaShape: 2)), ("structure", Scripts.structure(of: "A \"quoted\" name")),
        ("next", Scripts.next), ("previous", Scripts.previous), ("showSlideIndex", Scripts.showSlideIndex),
        ("currentEditSlide", Scripts.currentEditSlide), ("selectSlide", Scripts.selectSlide(3)),
        ("exitShowAndSelect", Scripts.exitShowAndSelect(3)), ("startAll", Scripts.startAll),
        ("startRange", Scripts.startRange(from: 3)), ("setHidden", Scripts.setHidden(slide: 2, hidden: true)),
        ("sectionFirstSlide", Scripts.sectionFirstSlide(named: "Intro")), ("media", Scripts.media("play player pl")),
        ("hasPresentation", Scripts.hasPresentation("x")), ("open", Scripts.open("/tmp/x.pptx")),
        ("closeAbort", Scripts.close(name: nil, mode: .abort)), ("closeSave", Scripts.close(name: "x", mode: .save)),
        ("inShow", Scripts.inShow("return my stateName(slide state of v)")),
    ]

    @Test(arguments: scripts.map(\.0))
    func compiles(_ name: String) throws {
        let body = Self.scripts.first { $0.0 == name }!.1
        let source = Scripts.wrap(body, bundleID: "com.microsoft.Powerpoint")
        let script = try #require(NSAppleScript(source: source))
        var error: NSDictionary?
        let ok = script.compileAndReturnError(&error)
        #expect(ok, "\(name): \(error?[NSAppleScript.errorMessage] ?? "") \(error?[NSAppleScript.errorRange] ?? "")")
    }
}

/// Talks to the real PowerPoint. Run with: KEYPOINT_LIVE=1 scripts/test.sh --filter Live
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KEYPOINT_LIVE"] == "1"))
struct LivePowerPointTests {
    let backend = PowerPointBackend()

    @Test func pollTiming() async throws {
        _ = try await backend.poll() // compile + warm up
        let clock = ContinuousClock()
        var snap = BackendSnapshot.empty
        let elapsed = try await clock.measure {
            for _ in 0..<10 { snap = try await backend.poll() }
        }
        print("LIVE poll x10: \(elapsed / 10) each; snapshot: \(snap)")
        #expect(!snap.presentations.isEmpty)
    }
}

/// Writes the generated scripts to a folder for running by hand: KEYPOINT_DUMP=/path scripts/test.sh --filter Dump
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KEYPOINT_DUMP"] != nil))
struct DumpScripts {
    @Test func dump() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEYPOINT_DUMP"]!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, body) in PowerPointScriptCompileTests.scripts {
            try Scripts.wrap(body, bundleID: "com.microsoft.Powerpoint")
                .write(to: dir.appendingPathComponent("\(name).applescript"), atomically: true, encoding: .utf8)
        }
    }
}
