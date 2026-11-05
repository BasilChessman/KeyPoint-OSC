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
        #expect(r.documents[0].path == "/Users/me/Deck.key")
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

@Suite struct KeynoteMediaTests {
    let us = String(AS.unit)

    @Test func parsesMovie() throws {
        #expect(try KeynoteMovie.parse("") == nil)
        #expect(try KeynoteMovie.parse("Clip.mov\(us)none") == KeynoteMovie(fileName: "Clip.mov", repetition: .none))
        #expect(try KeynoteMovie.parse("Clip.mov\(us)loop back and forth")?.repetition == .loopBackAndForth)
        #expect(try KeynoteMovie.parse("Clip.mov\(us)something new")?.repetition == KeynoteMovie.Repetition.none)
    }

    static let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    func plan(click: Int, offset: Int = 0, trim: (Int, Int) = (0, 10_000), across: Bool = true) -> KeynoteFileMovie {
        KeynoteFileMovie(storedName: "a-9001.mov", trimStart: trim.0, trimEnd: trim.1, playAcrossSlides: across,
                         start: KeynoteMovieStart(click: click, offset: offset))
    }

    func timer(_ plan: KeynoteFileMovie?, repetition: KeynoteMovie.Repetition = .none) -> KeynoteMediaTimer {
        KeynoteMediaTimer(movie: .init(fileName: "a.mov", repetition: repetition), arrivedAt: Self.t0,
                          plan: plan, planResolved: true)
    }

    func at(_ seconds: Double) -> Date { Self.t0.addingTimeInterval(seconds) }

    @Test func fallbackCountsFromSlideArrival() {
        let t = timer(nil)
        let early = t.media(fileDuration: 10_000, clicks: [:], now: at(4))
        #expect(early == MediaInfo(state: .playing, position: 4000, duration: 10_000, estimated: true))
        #expect(early.remaining == 6000)
        let done = t.media(fileDuration: 10_000, clicks: [:], now: at(12))
        #expect(done.state == .stopped && done.remaining == 0)
        // Length not known (yet): position only.
        let unknown = t.media(fileDuration: nil, clicks: [:], now: at(2))
        #expect(unknown.duration == nil && unknown.position == 2000 && unknown.estimated)
    }

    @Test func waitsForTheFileToBeRead() {
        var t = timer(nil)
        t.planResolved = false
        #expect(t.media(fileDuration: 10_000, clicks: [:], now: at(3)).state == .notready)
    }

    @Test func automaticStartWithDelay() {
        let t = timer(plan(click: 0, offset: 2500))
        let waiting = t.media(fileDuration: 10_000, clicks: [:], now: at(2))
        #expect(waiting.state == .notready && waiting.position == 0 && waiting.remaining == 10_000)
        #expect(t.media(fileDuration: 10_000, clicks: [:], now: at(5)).remaining == 7500)
    }

    @Test func onClickWaitsForKeyPointsClick() {
        let t = timer(plan(click: 2, offset: 750))
        #expect(t.media(fileDuration: 10_000, clicks: [1: at(1)], now: at(9)).state == .notready)
        let playing = t.media(fileDuration: 10_000, clicks: [1: at(1), 2: at(5)], now: at(8))
        #expect(playing.state == .playing && playing.position == 2250 && playing.remaining == 7750)
    }

    @Test func trimsShortenTheCountdown() {
        let t = timer(plan(click: 0, trim: (2000, 6500)))
        let m = t.media(fileDuration: 10_000, clicks: [:], now: at(1))
        #expect(m.duration == 10_000 && m.trimStart == 2000 && m.trimEnd == 3500)
        #expect(m.trimmedDuration == 4500 && m.remaining == 3500)
        // Before the media file is measured, the trim end stands in for its length.
        #expect(t.media(fileDuration: nil, clicks: [:], now: at(1)).remaining == 3500)
    }

    @Test func steppingBackOntoTheSlideIsUnknown() {
        var t = timer(plan(click: 0))
        t.arrivedBackward = true
        #expect(t.media(fileDuration: 10_000, clicks: [:], now: at(3)).state == .notready)
    }

    @Test func playAcrossSlidesKeepsTheTimer() {
        let first = timer(plan(click: 0))
        var next = KeynoteMediaTimer(movie: first.movie, arrivedAt: at(4))
        next.continueFrom(first, clicks: [:], now: at(4))
        #expect(next.media(fileDuration: 10_000, clicks: [:], now: at(6)).position == 6000)
        var restarted = KeynoteMediaTimer(movie: first.movie, arrivedAt: at(4))
        restarted.continueFrom(timer(plan(click: 0, across: false)), clicks: [:], now: at(4))
        #expect(restarted.continuedStart == nil)
    }

    @Test func resolvesPlanOnlyWhenTheFileMatches() {
        let deck = KeynoteDeckMedia(slides: [[], [plan(click: 1)]])
        var t = KeynoteMediaTimer(movie: .init(fileName: "a.mov", repetition: .none), arrivedAt: Self.t0)
        t.resolvePlan(deck, slide: 2, slideCount: 2)
        #expect(t.planResolved && t.plan?.start.click == 1)
        var stale = t
        stale.plan = nil
        stale.resolvePlan(deck, slide: 2, slideCount: 3) // slides added since the save
        #expect(stale.planResolved && stale.plan == nil)
        var other = KeynoteMediaTimer(movie: .init(fileName: "b.mov", repetition: .none), arrivedAt: Self.t0)
        other.resolvePlan(deck, slide: 2, slideCount: 2)
        #expect(other.plan == nil)
    }

    @Test func timerRestartsEachLoop() {
        for rep in [KeynoteMovie.Repetition.loop, .loopBackAndForth] {
            let m = timer(nil, repetition: rep).media(fileDuration: 10_000, clicks: [:], now: at(23))
            #expect(m.state == .playing && m.position == 3000 && m.remaining == 7000)
        }
    }

    @Test func matchesStoredFileName() {
        let names = ["posterImage-9083.png", "Clip-2-9090.mov", "JennaJeep-9082.mov", "My_Movie-12.m4v", "song-5.m4a"]
        #expect(KeynoteMedia.match("JennaJeep.mov", in: names) == "JennaJeep-9082.mov")
        #expect(KeynoteMedia.match("Clip-2.mov", in: names) == "Clip-2-9090.mov")
        #expect(KeynoteMedia.match("My Movie.m4v", in: names) == "My_Movie-12.m4v")
        #expect(KeynoteMedia.match("song.m4a", in: names) == "song-5.m4a")
        #expect(KeynoteMedia.match("posterImage.mov", in: names) == nil)
        #expect(KeynoteMedia.match("Other.mov", in: names) == nil)
        #expect(KeynoteMedia.match("Exact.mov", in: ["Exact.mov"]) == "Exact.mov")
    }

    @Test func readsClipFromZipAndPackage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kp-key-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let package = dir.appendingPathComponent("Deck.key")
        let data = package.appendingPathComponent("Data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try MediaDurationTests.wav(milliseconds: 1500).write(to: data.appendingPathComponent("Narration-9001.wav"))
        try Data("x".utf8).write(to: package.appendingPathComponent("Index.zip"))
        #expect(KeynoteMedia.clip(deckPath: package.path, fileName: "Narration.wav")?.fileDuration == 1500)

        let zipped = dir.appendingPathComponent("Zipped.key")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = package
        zip.arguments = ["-qr", zipped.path, "."]
        try zip.run()
        zip.waitUntilExit()
        #expect(KeynoteMedia.clip(deckPath: zipped.path, fileName: "Narration.wav")?.fileDuration == 1500)
        #expect(KeynoteMedia.clip(deckPath: zipped.path, fileName: "Missing.wav") == nil)

        let resolver = MediaDurationResolver.keynote()
        #expect(resolver.clip(deckPath: zipped.path, item: "Narration.wav") == nil) // started, not done
        resolver.drain()
        #expect(resolver.clip(deckPath: zipped.path, item: "Narration.wav")?.fileDuration == 1500)
    }
}

/// Reads the real test deck's movie: KEYPOINT_LIVE=1 scripts/test.sh --filter SpikeKeynoteMedia
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KEYPOINT_LIVE"] != nil))
struct SpikeKeynoteMedia {
    @Test func testDeckMovie() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../spike/keynote/KeyPointTest-builds.key").standardized.path
        let start = Date()
        let clip = KeynoteMedia.clip(deckPath: path, fileName: "JennaJeep.mov")
        print("SPIKE keynote clip: \(String(describing: clip)) in \(Date().timeIntervalSince(start)) s")
        #expect(clip != nil)
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
        ("stop", KeynoteScripts.stop), ("movie", KeynoteScripts.movie(document: "A \"b\".key", slide: 4)), ("currentOrdinal", KeynoteScripts.currentOrdinal), ("raise", KeynoteScripts.raise("A \"b\".key")), ("open", KeynoteScripts.open("/tmp/a.key")),
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

/// Plays a deck whose slide 1 has a movie that starts on the first click, and checks the countdown
/// waits for KeyPoint's click: KEYPOINT_LIVE_KEYNOTE=/path/deck.key scripts/test.sh --filter LiveKeynoteMedia
/// (the deck must be open and frontmost in Keynote).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KEYPOINT_LIVE_KEYNOTE"] != nil))
struct LiveKeynoteMediaTests {
    let backend = KeynoteBackend()

    @Test func countdownWaitsForClick() async throws {
        try await backend.perform(.startShow(from: 1), options: BackendOptions())
        try await Task.sleep(for: .seconds(1.5))
        var media: [String] = []
        func sample(_ label: String) async throws -> MediaInfo? {
            let m = try await backend.poll().show?.media
            media.append("\(label): \(m.map { "\($0.state.rawValue) pos=\($0.position) left=\($0.remaining ?? -1)" } ?? "none")")
            return m
        }
        _ = try await sample("arrived")
        try await Task.sleep(for: .seconds(1))
        let waiting = try await sample("before click")
        try await backend.perform(.next, options: BackendOptions())
        _ = try await sample("after click")
        try await Task.sleep(for: .seconds(2))
        let playing = try await sample("2 s later")
        try await backend.perform(.endShow, options: BackendOptions())
        print("LIVE keynote media:\n" + media.joined(separator: "\n"))
        #expect(waiting?.state == .notready)
        #expect(playing?.state == .playing)
        #expect((playing?.position ?? 0) > 1800 && (playing?.position ?? 0) < 3000)
    }
}

/// PerfectCue presses against a scripted stand-in for Keynote.
@Suite(.serialized) struct KeynoteClickerTests {
    final class FakeKeynote: ScriptRunning, @unchecked Sendable {
        let lock = NSLock()
        var ordinal = 1
        var deck = ""
        var movie = ""
        var skipped = "false,false,false"
        func set(ordinal: Int) { lock.withLock { self.ordinal = ordinal } }
        func configure(deck: String, movie: String, skipped: String) {
            lock.withLock { (self.deck, self.movie, self.skipped) = (deck, movie, skipped) }
        }
        func run(_ source: String) throws -> String {
            lock.lock()
            defer { lock.unlock() }
            let us = String(AS.unit), rs = String(AS.record)
            if source.contains("set recs to {}") {
                return ["D\(us)Deck.key\(us)\(deck)\(us)true\(us)\(skipped)", "F\(us)Deck.key", "S\(us)\(ordinal)\(us)"]
                    .joined(separator: rs)
            }
            if source.contains("count of movies") { return ordinal == 1 ? movie : "" }
            if source.contains("return (slide number of current slide of front document) as text") { return String(ordinal) }
            return ""
        }
    }

    let fake = FakeKeynote()
    var backend: KeynoteBackend { KeynoteBackend(runner: fake, monitor: nil) }

    @Test func pressOnTheSameSlideIsABuildStep() async throws {
        let backend = self.backend
        #expect(try await backend.poll().show?.buildPosition == 0)
        await backend.clickerPressed(forward: true, at: Date())
        #expect(try await backend.poll().show?.buildPosition == 1)
        fake.set(ordinal: 2) // the next press moves to slide 2
        await backend.clickerPressed(forward: true, at: Date())
        let show = try await backend.poll().show
        #expect(show?.currentSlide == 2 && show?.buildPosition == 0)
    }

    @Test func pressStartsAnOnClickMovie() async throws {
        fake.configure(deck: KeynoteFileTests.fixtures.appendingPathComponent("on-click.key").path,
                       movie: "clip10.mov" + String(AS.unit) + "none",
                       skipped: "false") // the fixture's one slide is the whole deck
        let backend = self.backend
        var media = try await backend.poll().show?.media
        for _ in 0..<100 where media?.duration == nil {
            try await Task.sleep(for: .milliseconds(20))
            media = try await backend.poll().show?.media
        }
        #expect(media?.state == .notready && media?.remaining == 10_000)
        await backend.clickerPressed(forward: true, at: Date())
        try await Task.sleep(for: .seconds(1))
        media = try await backend.poll().show?.media
        #expect(media?.state == .playing)
        #expect((media?.position ?? 0) >= 1000 && (media?.position ?? 0) < 1600)
    }
}
