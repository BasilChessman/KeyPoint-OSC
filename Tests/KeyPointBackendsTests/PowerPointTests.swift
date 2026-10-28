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

@Suite struct MediaDurationTests {
    @Test func partPaths() {
        #expect(PPTXMedia.resolve("slides/slide2.xml", from: "ppt/presentation.xml") == "ppt/slides/slide2.xml")
        #expect(PPTXMedia.resolve("../media/media%201.mov", from: "ppt/slides/slide2.xml") == "ppt/media/media 1.mov")
        #expect(PPTXMedia.resolve("/ppt/media/a.mp4", from: "ppt/slides/slide2.xml") == "ppt/media/a.mp4")
        #expect(PPTXMedia.relsPath(for: "ppt/slides/slide2.xml") == "ppt/slides/_rels/slide2.xml.rels")
        #expect(PPTXMedia.externalPath("file:///Users/me/Clip%20A.mov", deckPath: "/x/D.pptx") == "/Users/me/Clip A.mov")
        #expect(PPTXMedia.externalPath("Clips/A.mov", deckPath: "/x/D.pptx") == "/x/Clips/A.mov")
        #expect(PPTXMedia.externalPath("https://youtube.com/watch?v=1", deckPath: "/x/D.pptx") == nil)
    }

    /// A two-slide deck: slide order differs from file names, slide 2 has a trimmed 1.5 s WAV.
    @Test func readsEmbeddedClipAndTrim() throws {
        let deck = try Self.makeDeck(trim: #"<p14:trim st="200" end="300.5"/>"#)
        defer { try? FileManager.default.removeItem(at: deck.deletingLastPathComponent()) }
        #expect(try PPTXMedia.media(deckPath: deck.path, slide: 1) == nil)
        let media = try PPTXMedia.media(deckPath: deck.path, slide: 2)
        #expect(media == .init(source: .entry("ppt/media/media1.wav"), trimStart: 200, trimEnd: 301))
        let clip = PPTXMedia.clip(deckPath: deck.path, slide: 2)
        #expect(clip?.fileDuration == 1500)
        #expect(clip?.duration == 999)
        #expect(PPTXMedia.clip(deckPath: deck.path, slide: 3) == nil)
    }

    @Test func resolverCachesInBackground() throws {
        let deck = try Self.makeDeck(trim: "")
        defer { try? FileManager.default.removeItem(at: deck.deletingLastPathComponent()) }
        let resolver = MediaDurationResolver()
        #expect(resolver.clip(deckPath: deck.path, slide: 2) == nil) // started, not done
        resolver.drain()
        #expect(resolver.clip(deckPath: deck.path, slide: 2)?.duration == 1500)
        #expect(resolver.clip(deckPath: "/no/such.pptx", slide: 2) == nil)
    }

    static func makeDeck(trim: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kp-deck-\(UUID().uuidString)")
        let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let pkg = "http://schemas.openxmlformats.org/package/2006/relationships"
        let p = "http://schemas.openxmlformats.org/presentationml/2006/main"
        let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
        let p14 = "http://schemas.microsoft.com/office/powerpoint/2010/main"
        let files: [String: Data] = [
            "ppt/presentation.xml": Data(#"<p:presentation xmlns:p="\#(p)" xmlns:r="\#(r)"><p:sldIdLst><p:sldId id="256" r:id="rId7"/><p:sldId id="257" r:id="rId3"/></p:sldIdLst></p:presentation>"#.utf8),
            "ppt/_rels/presentation.xml.rels": Data(#"<Relationships xmlns="\#(pkg)"><Relationship Id="rId3" Type="x" Target="slides/slide1.xml"/><Relationship Id="rId7" Type="x" Target="slides/slide2.xml"/></Relationships>"#.utf8),
            "ppt/slides/slide2.xml": Data(#"<p:sld xmlns:p="\#(p)"><p:cSld><p:spTree/></p:cSld></p:sld>"#.utf8),
            "ppt/slides/_rels/slide2.xml.rels": Data(#"<Relationships xmlns="\#(pkg)"/>"#.utf8),
            "ppt/slides/slide1.xml": Data(#"""
                <p:sld xmlns:p="\#(p)" xmlns:a="\#(a)" xmlns:r="\#(r)"><p:cSld><p:spTree>
                <p:sp/><p:pic><p:nvPicPr><p:nvPr/></p:nvPicPr></p:pic>
                <p:pic><p:nvPicPr><p:nvPr><a:audioFile r:link="rId2"/><p:extLst><p:ext><p14:media xmlns:p14="\#(p14)" r:embed="rId1">\#(trim)</p14:media></p:ext></p:extLst></p:nvPr></p:nvPicPr></p:pic>
                </p:spTree></p:cSld></p:sld>
                """#.utf8),
            "ppt/slides/_rels/slide1.xml.rels": Data(#"<Relationships xmlns="\#(pkg)"><Relationship Id="rId1" Type="m" Target="../media/media1.wav"/><Relationship Id="rId2" Type="a" Target="../media/media1.wav"/></Relationships>"#.utf8),
            "ppt/media/media1.wav": wav(milliseconds: 1500),
        ]
        let src = dir.appendingPathComponent("src")
        for (path, data) in files {
            let url = src.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let deck = dir.appendingPathComponent("Deck.pptx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = src
        zip.arguments = ["-qr", deck.path, "."]
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)
        return deck
    }

    /// Silent 8 kHz mono 16-bit PCM.
    static func wav(milliseconds: Int) -> Data {
        let rate = 8000, samples = rate * milliseconds / 1000, bytes = samples * 2
        var d = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes); d.append(Data(count: bytes))
        return d
    }
}

/// Reads the real test deck's clip: KEYPOINT_LIVE=1 scripts/test.sh --filter SpikeDeckMedia
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KEYPOINT_LIVE"] != nil))
struct SpikeDeckMedia {
    @Test func testDeckClip() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../spike/powerpoint/KeyPointTest.pptx").standardized.path
        let start = Date()
        let clip = PPTXMedia.clip(deckPath: path, slide: 4)
        print("SPIKE clip: \(String(describing: clip)) in \(Date().timeIntervalSince(start)) s")
        #expect(clip != nil)
    }
}
