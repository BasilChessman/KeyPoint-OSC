import Foundation
import Testing
@testable import KeyPointBackends
@testable import KeyPointCore

@Suite struct KeynoteParsingTests {
    let us = String(AS.unit), rs = String(AS.record)

    @Test func parsesPollWhilePlaying() throws {
        let text = ["D\(us)Deck.key\(us)/Users/me/Deck.key\(us)true\(us)false,false,true,false",
                    "D\(us)Untitled\(us)\(us)false\(us)false",
                    "F\(us)Deck.key",
                    "S\(us)3\(us)Notes\rwith ✓"].joined(separator: rs)
        let r = try KeynotePoll.parse(text)
        #expect(r.documents.count == 2)
        #expect(r.documents[0].folder == "/Users/me")
        #expect(r.documents[0].skipped == [false, false, true, false])
        #expect(r.documents[1].folder == "" && !r.documents[1].saved)
        #expect(r.front == "Deck.key")
        #expect(r.playing && r.visibleOrdinal == 3)
        #expect(r.notes == "Notes\rwith ✓")
    }

    @Test func parsesPollInEditMode() throws {
        let r = try KeynotePoll.parse("D\(us)A.key\(us)\(us)true\(us)false" + rs + "F\(us)A.key")
        #expect(!r.playing && r.notes == nil)
    }

    @Test func mapsVisibleOrdinalToRealIndex() {
        let skipped = [false, false, true, false, false]
        #expect(KeynoteBackend.realIndex(ofVisible: 1, skipped: skipped) == 1)
        #expect(KeynoteBackend.realIndex(ofVisible: 3, skipped: skipped) == 4)
        #expect(KeynoteBackend.realIndex(ofVisible: 4, skipped: skipped) == 5)
        #expect(KeynoteBackend.realIndex(ofVisible: 5, skipped: skipped) == nil)
        #expect(KeynoteBackend.realIndex(ofVisible: -1, skipped: skipped) == nil)
    }

    @Test func buildTracker() {
        var t = KeynoteBuildTracker()
        t.observe(slide: 2)
        #expect(t.position == 0)
        t.stepped(forward: true, sameSlide: true)
        t.stepped(forward: true, sameSlide: true)
        #expect(t.position == 2)
        t.stepped(forward: false, sameSlide: false)
        t.observe(slide: 1)
        #expect(t.position == nil) // arrived backwards: build state unknown
        t.stepped(forward: true, sameSlide: false)
        t.observe(slide: 2)
        #expect(t.position == 0)
    }
}

@MainActor
@Suite(.serialized, .enabled(if: FileManager.default.fileExists(atPath: "/Applications/Keynote.app")))
struct KeynoteScriptCompileTests {
    nonisolated static let scripts: [(String, String)] = [
        ("poll", KeynoteScripts.poll), ("isPlaying", KeynoteScripts.isPlaying), ("selection", KeynoteScripts.selection),
("step", KeynoteScripts.step("show next")),
        ("stepActivate", KeynoteScripts.step("show previous", activateFirst: true)),
        ("showSlide", KeynoteScripts.showSlide("(count of slides of d)")), ("selectSlide", KeynoteScripts.selectSlide(2)),
        ("setSkipped", KeynoteScripts.setSkipped(slide: 2, skipped: true)), ("start", KeynoteScripts.start(from: "3")),
        ("stop", KeynoteScripts.stop), ("raise", KeynoteScripts.raise("A \"b\".key")), ("open", KeynoteScripts.open("/tmp/a.key")),
        ("closeAbort", KeynoteScripts.close(name: nil, mode: .abort)), ("closeSave", KeynoteScripts.close(name: "a.key", mode: .save)),
    ]

    @Test(arguments: scripts.map(\.0))
    func compiles(_ name: String) throws {
        let body = Self.scripts.first { $0.0 == name }!.1
        let script = try #require(NSAppleScript(source: AS.wrap(body, bundleID: "com.apple.iWork.Keynote")))
        var error: NSDictionary?
        let ok = script.compileAndReturnError(&error)
        #expect(ok, "\(name): \(error?[NSAppleScript.errorMessage] ?? "") \(error?[NSAppleScript.errorRange] ?? "")")
    }
}
