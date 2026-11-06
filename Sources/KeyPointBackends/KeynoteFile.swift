import Foundation

// Reads movie timing and build steps from a saved Keynote file. Keynote's scripting doesn't
// say when a movie starts, how it's trimmed or what builds a slide has, but the file does. The format (IWA: Snappy-compressed protobuf
// objects in `Index/*.iwa`) is undocumented, so everything here was worked out by saving decks
// that differ in one setting (see docs/capabilities.md). Any surprise makes the parse return
// nil, and the backend falls back to timing from slide arrival.

/// When and how a slide's movie plays, as saved in the file.
struct KeynoteFileMovie: Equatable, Sendable {
    /// Name of the stored copy in the file's `Data/` folder, e.g. `Clip-9082.mov`.
    var storedName: String?
    /// Trim points in ms. `trimEnd` is where playback stops, 0 if not saved.
    var trimStart: Int
    var trimEnd: Int
    var playAcrossSlides: Bool
    var start: KeynoteMovieStart

    /// Playable length in ms, if the file has the trim end.
    var playableLength: Int? { trimEnd > trimStart ? trimEnd - trimStart : nil }
}

/// When a movie starts: `offset` ms after click number `click` on its slide
/// (0 = the slide appearing, 1 = the first click on the slide, …).
struct KeynoteMovieStart: Equatable, Sendable {
    var click: Int
    var offset: Int
}

/// Movies per slide, index 0 = slide 1, in the order they're drawn on the slide, and the
/// number of clicks each slide's builds take.
struct KeynoteDeckMedia: Equatable, Sendable {
    var slides: [[KeynoteFileMovie]]
    /// On Click build steps per slide: the clicks it takes before the next one moves to the
    /// next slide. Steps set to After or With run on their own and aren't counted.
    var buildClicks: [Int] = []

    /// Build clicks on `slide` (1-based), if the file has the same number of slides as the
    /// open deck.
    func buildClicks(slide: Int, slideCount: Int) -> Int? {
        guard buildClicks.count == slideCount, slides.count == slideCount, slide >= 1, slide <= slideCount else { return nil }
        return buildClicks[slide - 1]
    }
}

/// One step in a slide's build order.
struct KeynoteBuildChunk: Equatable {
    var drawable: UInt64?
    /// A "Start Movie" action rather than a build in or out.
    var movieStart: Bool
    /// Runs without a click: "After Transition", "After Build N" or "With Build N".
    var automatic: Bool
    /// "With Build N" rather than "After".
    var withPrevious: Bool
    var delay: Double // s
    var duration: Double // s
}

enum KeynoteFile {
    // Object types (TSPersistence registry ids).
    static let showType: UInt32 = 2
    static let slideNodeType: UInt32 = 4
    static let slideType: UInt32 = 5
    static let buildType: UInt32 = 8
    static let buildChunkType: UInt32 = 153
    static let movieType: UInt32 = 3007

    /// Reads a saved .key (a zip, or a package folder).
    static func media(deckPath: String) -> KeynoteDeckMedia? {
        guard let (index, dataNames) = try? read(deckPath) else { return nil }
        return try? media(index: index, dataNames: dataNames)
    }

    /// All `Index/*.iwa` bytes (concatenated: each is a run of whole chunks) and the names in `Data/`.
    static func read(_ deckPath: String) throws -> ([UInt8], [String]) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: deckPath, isDirectory: &isDirectory) else { throw IWA.Corrupt() }
        guard isDirectory.boolValue else {
            let names = try Zip.list(deckPath)
            let index = try Zip.read(pattern: "Index/*.iwa", from: deckPath)
            return ([UInt8](index), names.filter { $0.hasPrefix("Data/") }.map { String($0.dropFirst(5)) })
        }
        let fm = FileManager.default
        let dataNames = (try? fm.contentsOfDirectory(atPath: (deckPath as NSString).appendingPathComponent("Data"))) ?? []
        let indexZip = (deckPath as NSString).appendingPathComponent("Index.zip")
        if fm.fileExists(atPath: indexZip) {
            return ([UInt8](try Zip.read(pattern: "*.iwa", from: indexZip)), dataNames)
        }
        let dir = (deckPath as NSString).appendingPathComponent("Index")
        var bytes: [UInt8] = []
        for name in try fm.contentsOfDirectory(atPath: dir).sorted() where name.hasSuffix(".iwa") {
            bytes += [UInt8](try Data(contentsOf: URL(fileURLWithPath: (dir as NSString).appendingPathComponent(name))))
        }
        return (bytes, dataNames)
    }

    static func media(index: [UInt8], dataNames: [String]) throws -> KeynoteDeckMedia {
        let objects = try IWA.objects(try IWA.decompress(index))
        func object(_ id: UInt64?, _ type: UInt32) -> [ProtoField]? {
            guard let id, let o = objects[id], o.type == type else { return nil }
            return try? Proto.fields(o.payload)
        }
        // The show lists the slide nodes in order; each points at its slide.
        guard let show = objects.values.first(where: { $0.type == showType }),
              let tree = try Proto.fields(show.payload).message(3)
        else { throw IWA.Corrupt() }
        var slides: [[KeynoteFileMovie]] = []
        var clicks: [Int] = []
        for nodeRef in tree.all(2) {
            guard let node = object(try Proto.fields(nodeRef).ref(), slideNodeType),
                  let slideID = node.messageRef(2), let slide = object(slideID, slideType)
            else { throw IWA.Corrupt() }
            let chunks = buildChunks(slide: slide, object: object)
            slides.append(movies(slide: slide, chunks: chunks, object: object, dataNames: dataNames))
            clicks.append(chunks.filter { !$0.automatic }.count)
        }
        return KeynoteDeckMedia(slides: slides, buildClicks: clicks)
    }

    /// The slide's build steps, in Build Order order.
    private static func buildChunks(slide: [ProtoField], object: (UInt64?, UInt32) -> [ProtoField]?) -> [KeynoteBuildChunk] {
        slide.all(43).compactMap { ref in
            guard let chunk = object(try? Proto.fields(ref).ref(), buildChunkType),
                  let build = chunk.messageRef(1), let buildFields = object(build, buildType)
            else { return nil }
            let effect = buildFields.message(4).flatMap { $0.message(18) }.flatMap { $0.string(2) }
            return KeynoteBuildChunk(
                drawable: buildFields.messageRef(1), movieStart: effect == "apple:movie-start",
                automatic: (chunk.varint(5) ?? 0) != 0, withPrevious: chunk.varint(6) == 0,
                delay: chunk.double(3) ?? 0, duration: chunk.double(4) ?? 0)
        }
    }

    private static func movies(slide: [ProtoField], chunks: [KeynoteBuildChunk], object: (UInt64?, UInt32) -> [ProtoField]?,
                               dataNames: [String]) -> [KeynoteFileMovie] {
        let transition = slide.message(4).flatMap { $0.message(2) }.flatMap { $0.message(8) }
        let transitionLength = transition.flatMap { t in t.string(2).map { $0 == "none" ? 0 : t.double(3) ?? 0 } } ?? 0
        var out: [KeynoteFileMovie] = []
        for ref in slide.all(7) {
            guard let id = try? Proto.fields(ref).ref(), let movie = object(id, movieType) else { continue }
            let dataID = movie.messageRef(14)
            out.append(KeynoteFileMovie(
                storedName: dataID.flatMap { id in dataNames.first { storedName($0, hasID: id) } },
                trimStart: ms(movie.float(3)), trimEnd: ms(movie.float(4)),
                playAcrossSlides: movie.varint(28) == 1,
                start: start(of: id, chunks: chunks, transition: transitionLength)))
        }
        return out
    }

    /// `Clip-9082.mov` is data 9082.
    static func storedName(_ name: String, hasID id: UInt64) -> Bool {
        let stem = (name as NSString).deletingPathExtension
        return stem.hasSuffix("-\(id)") || stem == String(id)
    }

    /// When the movie `drawable` starts: at its Start Movie step, else when it builds in,
    /// else when the slide's transition ends.
    static func start(of drawable: UInt64, chunks: [KeynoteBuildChunk], transition: Double) -> KeynoteMovieStart {
        let times = schedule(chunks, transition: transition)
        let index = chunks.firstIndex { $0.drawable == drawable && $0.movieStart }
            ?? chunks.firstIndex { $0.drawable == drawable }
        guard let index else { return KeynoteMovieStart(click: 0, offset: ms(transition)) }
        return times[index]
    }

    /// Start of each step: the click that sets it off, and how long after that click it runs.
    static func schedule(_ chunks: [KeynoteBuildChunk], transition: Double) -> [KeynoteMovieStart] {
        var out: [KeynoteMovieStart] = []
        var click = 0
        var previousStart = 0.0, previousEnd = 0.0
        for (i, chunk) in chunks.enumerated() {
            let start: Double
            if !chunk.automatic {
                click += 1
                start = max(chunk.delay, 0)
            } else if i == 0 || out.isEmpty {
                start = transition + max(chunk.delay, 0) // "After Transition"
            } else {
                start = (chunk.withPrevious ? previousStart : previousEnd) + max(chunk.delay, 0)
            }
            out.append(KeynoteMovieStart(click: click, offset: ms(start)))
            previousStart = start
            previousEnd = start + max(chunk.duration, 0)
        }
        return out
    }

    private static func ms(_ seconds: Double?) -> Int {
        guard let seconds, seconds.isFinite, seconds > 0 else { return 0 }
        return Int((seconds * 1000).rounded())
    }

    private static func ms(_ seconds: Float?) -> Int { ms(seconds.map(Double.init)) }
}

// MARK: - IWA and protobuf

enum IWA {
    struct Corrupt: Error {}

    /// IWA chunks: a 0 byte, a 3-byte little-endian length, then a raw Snappy block.
    static func decompress(_ data: [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = []
        var p = 0
        while p < data.count {
            guard data[p] == 0, data.count - p >= 4 else { throw Corrupt() }
            let length = Int(data[p + 1]) | Int(data[p + 2]) << 8 | Int(data[p + 3]) << 16
            guard data.count - p - 4 >= length else { throw Corrupt() }
            out += try Snappy.decompress(data[(p + 4)..<(p + 4 + length)])
            p += 4 + length
        }
        return out
    }

    /// Objects by id: each is a length-prefixed ArchiveInfo (id, message types and lengths)
    /// followed by the messages. Only the first message of each object is kept.
    static func objects(_ bytes: [UInt8]) throws -> [UInt64: (type: UInt32, payload: ArraySlice<UInt8>)] {
        var out: [UInt64: (type: UInt32, payload: ArraySlice<UInt8>)] = [:]
        var p = 0
        while p < bytes.count {
            let length = Int(try Proto.varint(bytes[...], at: &p))
            guard length >= 0, bytes.count - p >= length else { throw Corrupt() }
            let info = try Proto.fields(bytes[p..<(p + length)])
            p += length
            guard let id = info.varint(1) else { throw Corrupt() }
            var first = true
            for message in info.all(2) {
                let m = try Proto.fields(message)
                let size = Int(m.varint(3) ?? 0)
                guard size >= 0, bytes.count - p >= size else { throw Corrupt() }
                if first, let type = m.varint(1) {
                    out[id] = (UInt32(truncatingIfNeeded: type), bytes[p..<(p + size)])
                }
                first = false
                p += size
            }
        }
        return out
    }
}

enum Snappy {
    /// Decompresses one raw Snappy block (no framing).
    static func decompress(_ src: ArraySlice<UInt8>) throws -> [UInt8] {
        var p = src.startIndex
        let expected = Int(try Proto.varint(src, at: &p))
        guard expected <= 512 << 20 else { throw IWA.Corrupt() }
        var out: [UInt8] = []
        out.reserveCapacity(expected)
        func byte() throws -> Int {
            guard p < src.endIndex else { throw IWA.Corrupt() }
            defer { p += 1 }
            return Int(src[p])
        }
        while p < src.endIndex {
            let tag = try byte()
            let length: Int, offset: Int
            switch tag & 3 {
            case 0: // literal
                var n = tag >> 2
                if n >= 60 {
                    let count = n - 59
                    n = 0
                    for i in 0..<count { n |= try byte() << (8 * i) }
                }
                n += 1
                guard src.endIndex - p >= n else { throw IWA.Corrupt() }
                out += src[p..<(p + n)]
                p += n
                continue
            case 1:
                length = ((tag >> 2) & 7) + 4
                offset = (tag >> 5) << 8 | (try byte())
            case 2:
                length = (tag >> 2) + 1
                offset = try byte() | (try byte()) << 8
            default:
                length = (tag >> 2) + 1
                offset = try byte() | (try byte()) << 8 | (try byte()) << 16 | (try byte()) << 24
            }
            guard offset > 0, offset <= out.count, out.count + length <= expected else { throw IWA.Corrupt() }
            for _ in 0..<length { out.append(out[out.count - offset]) }
        }
        guard out.count == expected else { throw IWA.Corrupt() }
        return out
    }
}

/// One protobuf field: a varint, or the raw bytes of a fixed32/fixed64/length-delimited value.
struct ProtoField {
    var number: Int
    var wireType: Int
    var varint: UInt64 = 0
    var bytes: ArraySlice<UInt8> = []
}

enum Proto {
    static func varint(_ b: ArraySlice<UInt8>, at p: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard p < b.endIndex, shift < 64 else { throw IWA.Corrupt() }
            let x = b[p]
            p += 1
            value |= UInt64(x & 0x7F) << shift
            if x < 0x80 { return value }
            shift += 7
        }
    }

    static func fields(_ b: ArraySlice<UInt8>) throws -> [ProtoField] {
        var out: [ProtoField] = []
        var p = b.startIndex
        while p < b.endIndex {
            let key = try varint(b, at: &p)
            var f = ProtoField(number: Int(key >> 3), wireType: Int(key & 7))
            guard f.number > 0 else { throw IWA.Corrupt() }
            let size: Int
            switch f.wireType {
            case 0:
                f.varint = try varint(b, at: &p)
                out.append(f)
                continue
            case 1: size = 8
            case 2:
                let n = try varint(b, at: &p)
                guard n <= UInt64(b.endIndex - p) else { throw IWA.Corrupt() }
                size = Int(n)
            case 5: size = 4
            default: throw IWA.Corrupt()
            }
            guard b.endIndex - p >= size else { throw IWA.Corrupt() }
            f.bytes = b[p..<(p + size)]
            p += size
            out.append(f)
        }
        return out
    }
}

extension [ProtoField] {
    func first(_ number: Int) -> ProtoField? { first { $0.number == number } }
    func all(_ number: Int) -> [ArraySlice<UInt8>] { filter { $0.number == number && $0.wireType == 2 }.map(\.bytes) }
    func varint(_ number: Int) -> UInt64? { first { $0.number == number && $0.wireType == 0 }?.varint }
    func message(_ number: Int) -> [ProtoField]? {
        first { $0.number == number && $0.wireType == 2 }.flatMap { try? Proto.fields($0.bytes) }
    }
    func string(_ number: Int) -> String? {
        first { $0.number == number && $0.wireType == 2 }.map { String(decoding: $0.bytes, as: UTF8.self) }
    }
    func double(_ number: Int) -> Double? {
        guard let f = first(where: { $0.number == number && $0.wireType == 1 }) else { return nil }
        return Double(bitPattern: f.bytes.reversed().reduce(0) { $0 << 8 | UInt64($1) })
    }
    func float(_ number: Int) -> Float? {
        guard let f = first(where: { $0.number == number && $0.wireType == 5 }) else { return nil }
        return Float(bitPattern: f.bytes.reversed().reduce(0) { $0 << 8 | UInt32($1) })
    }
    /// A TSP.Reference: a message whose field 1 is the object id.
    func ref() throws -> UInt64 {
        guard let id = varint(1) else { throw IWA.Corrupt() }
        return id
    }
    func messageRef(_ number: Int) -> UInt64? { message(number).flatMap { $0.varint(1) } }
}
