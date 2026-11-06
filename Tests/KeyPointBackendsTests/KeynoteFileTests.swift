import Foundation
import Testing
@testable import KeyPointBackends

/// The fixtures are real Keynote 14.3 saves (index only, movie replaced by an empty stand-in),
/// each differing from the one before in one setting. See Fixtures/keynote/README.md.
@Suite struct KeynoteFileTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/keynote")

    func movies(_ name: String) throws -> [KeynoteFileMovie] {
        let deck = try #require(KeynoteFile.media(deckPath: Self.fixtures.appendingPathComponent(name + ".key").path))
        #expect(deck.slides.count == 1)
        return try #require(deck.slides.first)
    }

    @Test func newMovieStartsOnClick() throws {
        let m = try movies("on-click")
        #expect(m.count == 1)
        #expect(m[0].storedName == "clip10-9089.mov")
        #expect(m[0].start == KeynoteMovieStart(click: 1, offset: 0))
        #expect(m[0].trimStart == 0 && m[0].trimEnd == 10_000 && m[0].playableLength == 10_000)
        #expect(m[0].playAcrossSlides)
    }

    @Test func afterTransitionWithDelay() throws {
        #expect(try movies("after-transition-2.5s")[0].start == KeynoteMovieStart(click: 0, offset: 2500))
    }

    @Test func secondMovieTiming() throws {
        let click = try movies("two-on-click")
        #expect(click.map(\.start) == [.init(click: 1, offset: 0), .init(click: 2, offset: 0)])
        // After build 1 (a 0.5 s step) plus a 1.5 s delay.
        #expect(try movies("two-after-build1-1.5s")[1].start == KeynoteMovieStart(click: 1, offset: 2000))
        #expect(try movies("two-with-build1-0.75s")[1].start == KeynoteMovieStart(click: 1, offset: 750))
    }

    @Test func trimAndPlayAcross() throws {
        let trimmed = try movies("trim-2-6.5s")[1]
        #expect(trimmed.trimStart == 2000 && trimmed.trimEnd == 6500 && trimmed.playableLength == 4500)
        #expect(try movies("no-play-across")[1].playAcrossSlides == false)
        #expect(try movies("no-play-across")[0].playAcrossSlides)
    }

    @Test func transitionDelaysFirstAutomaticStep() {
        let step = KeynoteBuildChunk(drawable: 1, movieStart: true, automatic: true, withPrevious: false, delay: 0.5, duration: 0.5)
        #expect(KeynoteFile.start(of: 1, chunks: [step], transition: 2.25) == KeynoteMovieStart(click: 0, offset: 2750))
        // No build for the movie: it plays once the transition is over.
        #expect(KeynoteFile.start(of: 9, chunks: [step], transition: 2.25) == KeynoteMovieStart(click: 0, offset: 2250))
    }

    @Test func scheduleChainsStepsAcrossClicks() {
        func chunk(_ id: UInt64, auto: Bool, with: Bool = false, delay: Double = 0, duration: Double = 1, movie: Bool = false) -> KeynoteBuildChunk {
            KeynoteBuildChunk(drawable: id, movieStart: movie, automatic: auto, withPrevious: with, delay: delay, duration: duration)
        }
        // Title after transition, text on click, then the movie 1 s after the text, then a caption with the movie.
        let chunks = [chunk(1, auto: true), chunk(2, auto: false, duration: 2), chunk(3, auto: true, delay: 1, movie: true),
                      chunk(4, auto: true, with: true, delay: 0.25)]
        #expect(KeynoteFile.schedule(chunks, transition: 0.5) == [
            .init(click: 0, offset: 500), .init(click: 1, offset: 0), .init(click: 1, offset: 3000), .init(click: 1, offset: 3250),
        ])
        // The Start Movie step wins over the movie's own build in.
        let buildIn = chunk(3, auto: false)
        #expect(KeynoteFile.start(of: 3, chunks: [buildIn] + chunks, transition: 0) == KeynoteMovieStart(click: 2, offset: 3000))
        #expect(KeynoteFile.start(of: 3, chunks: [buildIn], transition: 0) == KeynoteMovieStart(click: 1, offset: 0))
    }

    @Test func storedNames() {
        #expect(KeynoteFile.storedName("JennaJeep-9082.mov", hasID: 9082))
        #expect(!KeynoteFile.storedName("JennaJeep-19082.mov", hasID: 9082))
        #expect(!KeynoteFile.storedName("posterImage-9083.png", hasID: 9082))
    }

    @Test func rejectsGarbage() {
        #expect(throws: (any Error).self) { try IWA.decompress([0, 5, 0, 0, 1, 2]) }
        #expect(throws: (any Error).self) { try Snappy.decompress([10, 0x0A, 1][...]) } // copy before any output
        #expect((try? Snappy.decompress([3, 8, 0x61, 0x62, 0x63][...])) == Array("abc".utf8))
        #expect(KeynoteFile.media(deckPath: "/no/such.key") == nil)
    }
}

/// Reads the spike deck's movie timing: KEYPOINT_LIVE=1 scripts/test.sh --filter SpikeKeynoteFile
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KEYPOINT_LIVE"] != nil))
struct SpikeKeynoteFile {
    @Test func spikeDeck() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../spike/keynote/KeyPointTest-builds.key").standardized.path
        let start = Date()
        let deck = try #require(KeynoteFile.media(deckPath: path))
        print("SPIKE keynote file: \(deck) in \(Date().timeIntervalSince(start)) s")
        #expect(deck.slides.count == 5)
        #expect(deck.slides[3].first?.storedName == "JennaJeep-9082.mov")
        #expect(deck.slides[3].first?.start == KeynoteMovieStart(click: 0, offset: 0))
        #expect(deck.slides[3].first?.playableLength == 59078)
    }
}

/// Prints the movie timing KeyPoint reads from any saved deck: KEYPOINT_DECK=/path/deck.key scripts/test.sh --filter PrintDeck
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KEYPOINT_DECK"] != nil))
struct PrintDeck {
    @Test func printDeck() throws {
        let path = ProcessInfo.processInfo.environment["KEYPOINT_DECK"]!
        let deck = try #require(KeynoteFile.media(deckPath: path))
        for (i, movies) in deck.slides.enumerated() where !movies.isEmpty {
            for m in movies {
                print("DECK slide \(i + 1): \(m.storedName ?? "?") click \(m.start.click) +\(m.start.offset) ms, "
                      + "trim \(m.trimStart)-\(m.trimEnd) ms, play across \(m.playAcrossSlides)")
            }
        }
    }
}
