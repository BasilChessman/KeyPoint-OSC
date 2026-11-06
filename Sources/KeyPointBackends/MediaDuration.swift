import AVFoundation
import Foundation

/// A slide's video or audio item as saved in the presentation file.
struct MediaClip: Equatable, Sendable {
    /// Full length of the media file in ms.
    var fileDuration: Int
    /// Trimmed off the start and end in PowerPoint (Playback > Trim), in ms.
    var trimStart: Int = 0
    var trimEnd: Int = 0

    /// What plays: the file minus the trims.
    var duration: Int { max(fileDuration - trimStart - trimEnd, 0) }
}

/// Clip lengths, read from the saved presentation file: neither app's scripting exposes them.
typealias MediaDurationResolver = DeckFileCache<MediaClip>

/// Values read from a saved presentation file (`lookup` does the reading). Lookups never block:
/// the first call for an item starts a background read and returns nil until it's done.
/// Results are cached per file version, so a re-save is picked up.
final class DeckFileCache<Value: Sendable>: @unchecked Sendable {
    private struct Key: Hashable {
        var path: String
        var modified: Date
        var item: String
    }

    /// Reads the clip `item` (a slide number, a file name: whatever the backend uses) from the deck at a path.
    typealias Lookup = @Sendable (_ deckPath: String, _ item: String) -> Value?

    private let read: Lookup
    private let lock = NSLock()
    private var cache: [Key: Value?] = [:] // a nil value: looked, found nothing usable
    private var pending: Set<Key> = []
    private let queue = DispatchQueue(label: "keypoint.media-duration", qos: .utility)

    init(lookup: @escaping Lookup) {
        self.read = lookup
    }

    /// Keynote: movie timing per slide, from a saved .key (`item` is ignored).
    static func keynoteDeck() -> DeckFileCache<KeynoteDeckMedia> {
        DeckFileCache<KeynoteDeckMedia> { path, _ in KeynoteFile.media(deckPath: path) }
    }

    /// PowerPoint: the first media item on slide `slide` (1-based) of a saved .pptx.
    static func pptx() -> MediaDurationResolver {
        MediaDurationResolver { path, item in Int(item).flatMap { PPTXMedia.clip(deckPath: path, slide: $0) } }
    }

    /// PowerPoint: the animations on every slide of a saved .pptx (`item` is ignored).
    static func pptxBuilds() -> DeckFileCache<DeckBuilds> {
        DeckFileCache<DeckBuilds> { path, _ in PPTXBuilds.deck(deckPath: path) }
    }

    /// Keynote: the movie or audio file named `item`, stored in a saved .key.
    static func keynote() -> MediaDurationResolver {
        MediaDurationResolver { path, item in KeynoteMedia.clip(deckPath: path, fileName: item) }
    }

    /// The media clip on slide `slide` (1-based) of the saved file at `path`, if known yet.
    func clip(deckPath path: String, slide: Int) -> Value? {
        slide > 0 ? clip(deckPath: path, item: String(slide)) : nil
    }

    /// The clip `item` of the saved file at `path`, if known yet.
    func clip(deckPath path: String, item: String) -> Value? {
        lookup(deckPath: path, item: item) ?? nil
    }

    /// `nil` while the background read is still running; `.some(nil)` if it found nothing
    /// (or there's no saved file).
    func lookup(deckPath path: String, item: String) -> Value?? {
        guard !path.isEmpty, !item.isEmpty,
              let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return .some(nil) }
        let key = Key(path: path, modified: modified, item: item)
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        if pending.insert(key).inserted {
            queue.async {
                let clip = self.read(path, item)
                self.lock.lock()
                self.cache[key] = .some(clip)
                self.pending.remove(key)
                self.lock.unlock()
            }
        }
        return nil
    }

    /// Waits for background reads to finish (tests).
    func drain() {
        queue.sync {}
    }
}

/// A slide's animations in a saved .pptx: every effect in the main sequence, and how many of
/// them wait for a click. Effects set to With Previous or After Previous run on their own.
struct SlideBuilds: Equatable, Sendable {
    var effects: Int
    var clicks: Int
}

/// Animations per slide of a saved .pptx, index 0 = slide 1 (nil where a slide can't be read).
struct DeckBuilds: Equatable, Sendable {
    var slides: [SlideBuilds?]

    func builds(slide: Int, slideCount: Int) -> SlideBuilds? {
        guard slides.count == slideCount, slide >= 1, slide <= slideCount else { return nil }
        return slides[slide - 1]
    }
}

enum PPTXBuilds {
    /// Reads every slide at once, so moving to another slide doesn't wait for the file.
    static func deck(deckPath: String) -> DeckBuilds? {
        guard let parts = try? PPTXMedia.slideParts(deckPath: deckPath) else { return nil }
        return DeckBuilds(slides: parts.map { part in
            part.flatMap { try? Zip.read($0, from: deckPath) }.flatMap { try? builds(slideXML: $0) }
        })
    }

    /// Effects are `p:cTn` nodes with `nodeType` `clickEffect`, `withEffect` or `afterEffect`
    /// under the main sequence. Interactive sequences (triggered by clicking a shape) aren't
    /// part of next/previous and aren't counted.
    static func builds(slideXML data: Data) throws -> SlideBuilds {
        let doc = try XMLDocument(data: data)
        let path = "//*[local-name()='cTn'][@nodeType='mainSeq']//*[local-name()='cTn']"
        func count(_ types: [String]) throws -> Int {
            let test = types.map { "@nodeType='\($0)'" }.joined(separator: " or ")
            return try doc.nodes(forXPath: "\(path)[\(test)]").count
        }
        return SlideBuilds(effects: try count(["clickEffect", "withEffect", "afterEffect"]),
                           clicks: try count(["clickEffect"]))
    }
}

/// Reads media info from an Office Open XML presentation (a zip of XML parts).
enum PPTXMedia {
    static let relNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    struct Media: Equatable {
        enum Source: Equatable {
            case entry(String) // zip entry path, e.g. ppt/media/media1.mov
            case file(String) // linked file on disk
        }

        var source: Source
        var trimStart = 0
        var trimEnd = 0
    }

    static func clip(deckPath: String, slide: Int) -> MediaClip? {
        guard let media = try? media(deckPath: deckPath, slide: slide),
              let ms = MediaFile.duration(of: media.source, deckPath: deckPath)
        else { return nil }
        return MediaClip(fileDuration: ms, trimStart: media.trimStart, trimEnd: media.trimEnd)
    }

    /// The first top-level media item on the slide: the one PowerPoint's `shapes of slide`
    /// loop (and so the media actions) finds first.
    static func media(deckPath: String, slide: Int) throws -> Media? {
        guard let slidePath = try slidePart(deckPath: deckPath, slide: slide) else { return nil }
        let slideRels = try relationships(try Zip.read(relsPath(for: slidePath), from: deckPath))
        let slideXML = try XMLDocument(data: try Zip.read(slidePath, from: deckPath))
        guard let item = try firstMediaItem(in: slideXML) else { return nil }

        guard let rel = item.relID.flatMap({ slideRels[$0] }) else { return nil }
        let source: Media.Source
        if rel.external {
            guard let path = externalPath(rel.target, deckPath: deckPath) else { return nil }
            source = .file(path)
        } else {
            source = .entry(resolve(rel.target, from: slidePath))
        }
        return Media(source: source, trimStart: item.trimStart, trimEnd: item.trimEnd)
    }

    /// The zip entry of slide `slide` (1-based, in show order), e.g. `ppt/slides/slide7.xml`.
    static func slidePart(deckPath: String, slide: Int) throws -> String? {
        let parts = try slideParts(deckPath: deckPath)
        return slide >= 1 && slide <= parts.count ? parts[slide - 1] : nil
    }

    /// The zip entry of every slide, in show order (nil where it can't be resolved).
    static func slideParts(deckPath: String) throws -> [String?] {
        let presentationRels = try relationships(try Zip.read("ppt/_rels/presentation.xml.rels", from: deckPath))
        let presentation = try XMLDocument(data: try Zip.read("ppt/presentation.xml", from: deckPath))
        // Only the presentation's own list: a deck with sections repeats the slide IDs in its section list.
        let slideIDs = try presentation.nodes(forXPath: "/*[local-name()='presentation']/*[local-name()='sldIdLst']/*[local-name()='sldId']")
        return slideIDs.map { node in
            guard let rid = (node as? XMLElement)?.attribute(forLocalName: "id", uri: relNS)?.stringValue,
                  let target = presentationRels[rid]?.target
            else { return nil }
            return resolve(target, from: "ppt/presentation.xml")
        }
    }

    private struct Item {
        var relID: String?
        var trimStart = 0
        var trimEnd = 0
    }

    private static func firstMediaItem(in doc: XMLDocument) throws -> Item? {
        guard let tree = try doc.nodes(forXPath: "//*[local-name()='cSld']/*[local-name()='spTree']").first as? XMLElement
        else { return nil }
        for child in tree.children ?? [] {
            guard let element = child as? XMLElement else { continue }
            // Newer media is often wrapped in mc:AlternateContent, with the p:pic in mc:Choice.
            let candidates = element.localName == "AlternateContent"
                ? (element.elements(forLocalName: "Choice", uri: element.uri ?? "").first?.children ?? [])
                    .compactMap { $0 as? XMLElement }
                : [element]
            for pic in candidates where pic.localName == "pic" {
                if let item = try mediaItem(pic) { return item }
            }
        }
        return nil
    }

    private static func mediaItem(_ pic: XMLElement) throws -> Item? {
        let nvPr = "./*[local-name()='nvPicPr']/*[local-name()='nvPr']"
        let file = try pic.nodes(forXPath: "\(nvPr)/*[local-name()='videoFile' or local-name()='audioFile' or local-name()='quickTimeFile']").first as? XMLElement
        let p14 = try pic.nodes(forXPath: "\(nvPr)//*[local-name()='media']").first as? XMLElement
        guard file != nil || p14 != nil else { return nil }
        var item = Item()
        // p14:media points at the embedded copy; a:videoFile at the original (often a link).
        item.relID = p14?.attribute(forLocalName: "embed", uri: relNS)?.stringValue
            ?? p14?.attribute(forLocalName: "link", uri: relNS)?.stringValue
            ?? file?.attribute(forLocalName: "link", uri: relNS)?.stringValue
            ?? file?.attribute(forLocalName: "embed", uri: relNS)?.stringValue
        if let trim = try p14?.nodes(forXPath: "./*[local-name()='trim']").first as? XMLElement {
            item.trimStart = milliseconds(trim.attribute(forName: "st")?.stringValue)
            item.trimEnd = milliseconds(trim.attribute(forName: "end")?.stringValue)
        }
        return item
    }

    private static func milliseconds(_ text: String?) -> Int {
        guard let text, let value = Double(text), value.isFinite, value > 0 else { return 0 }
        return Int(value.rounded())
    }

    // MARK: Relationships and part paths

    struct Relationship: Equatable {
        var target: String
        var external: Bool
    }

    static func relationships(_ data: Data) throws -> [String: Relationship] {
        let doc = try XMLDocument(data: data)
        var out: [String: Relationship] = [:]
        for node in try doc.nodes(forXPath: "//*[local-name()='Relationship']") {
            guard let e = node as? XMLElement, let id = e.attribute(forName: "Id")?.stringValue,
                  let target = e.attribute(forName: "Target")?.stringValue else { continue }
            out[id] = Relationship(target: target, external: e.attribute(forName: "TargetMode")?.stringValue == "External")
        }
        return out
    }

    /// `ppt/slides/slide4.xml` → `ppt/slides/_rels/slide4.xml.rels`.
    static func relsPath(for part: String) -> String {
        let dir = (part as NSString).deletingLastPathComponent
        return (dir.isEmpty ? "" : dir + "/") + "_rels/" + (part as NSString).lastPathComponent + ".rels"
    }

    /// Resolves a relationship target against the part that refers to it.
    static func resolve(_ target: String, from part: String) -> String {
        var components: [String]
        if target.hasPrefix("/") {
            components = []
        } else {
            components = (part as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        }
        for piece in target.split(separator: "/") {
            switch piece {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(String(piece))
            }
        }
        return components.joined(separator: "/").removingPercentEncoding ?? components.joined(separator: "/")
    }

    /// A linked media file: a file URL, or a path relative to the presentation's folder.
    static func externalPath(_ target: String, deckPath: String) -> String? {
        if let url = URL(string: target), let scheme = url.scheme {
            return scheme == "file" ? url.path : nil // online video has no file to read
        }
        let folder = (deckPath as NSString).deletingLastPathComponent
        let decoded = target.removingPercentEncoding ?? target
        return decoded.hasPrefix("/") ? decoded : ((folder as NSString).appendingPathComponent(decoded) as NSString).standardizingPath
    }
}

/// Measures media files with AVFoundation.
enum MediaFile {
    static func duration(of source: PPTXMedia.Media.Source, deckPath: String) -> Int? {
        switch source {
        case .file(let path): assetDuration(URL(fileURLWithPath: path))
        case .entry(let entry): duration(ofEntry: entry, inArchive: deckPath)
        }
    }

    /// AVFoundation needs a file, so extract the zip entry to a temporary one.
    static func duration(ofEntry entry: String, inArchive archive: String) -> Int? {
        let ext = (entry as NSString).pathExtension
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyPointOSC-media-\(UUID().uuidString)")
            .appendingPathExtension(ext.isEmpty ? "mov" : ext)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard (try? Zip.extract(entry, from: archive, to: temp)) != nil else { return nil }
        return assetDuration(temp)
    }

    static func assetDuration(_ url: URL) -> Int? {
        final class Box: @unchecked Sendable { var time: CMTime? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let asset = AVURLAsset(url: url)
        Task.detached {
            box.time = try? await asset.load(.duration)
            done.signal()
        }
        guard done.wait(timeout: .now() + 15) == .success, let time = box.time, time.isNumeric, time.seconds > 0 else { return nil }
        return Int((time.seconds * 1000).rounded())
    }
}

/// Finds a Keynote movie or audio file in a saved .key: a zip, or (older or "package" format)
/// a folder. Media lives in `Data/`, renamed with a number: `Clip.mov` is stored as `Data/Clip-9082.mov`.
/// Keynote's movie trims aren't scriptable or readable here, so the result is the whole file.
enum KeynoteMedia {
    static func clip(deckPath: String, fileName: String) -> MediaClip? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: deckPath, isDirectory: &isDirectory) else { return nil }
        let ms: Int?
        if isDirectory.boolValue {
            let data = (deckPath as NSString).appendingPathComponent("Data")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: data)) ?? []
            ms = match(fileName, in: names).flatMap { MediaFile.assetDuration(URL(fileURLWithPath: (data as NSString).appendingPathComponent($0))) }
        } else {
            let entries = ((try? Zip.list(deckPath)) ?? []).filter { $0.hasPrefix("Data/") && !$0.dropFirst(5).contains("/") }
            ms = match(fileName, in: entries.map { String($0.dropFirst(5)) })
                .flatMap { MediaFile.duration(ofEntry: "Data/" + $0, inArchive: deckPath) }
        }
        return ms.map { MediaClip(fileDuration: $0) }
    }

    /// The stored name for `fileName` among `names` (the contents of `Data/`).
    static func match(_ fileName: String, in names: [String]) -> String? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let stem = (fileName as NSString).deletingPathExtension
        func parts(_ name: String) -> (stem: String, ext: String) {
            var s = (name as NSString).deletingPathExtension
            // Drop Keynote's "-<number>" suffix.
            if let dash = s.lastIndex(of: "-"), s[s.index(after: dash)...].allSatisfy(\.isNumber), s.index(after: dash) < s.endIndex {
                s = String(s[..<dash])
            }
            return (s, (name as NSString).pathExtension.lowercased())
        }
        func loose(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        if names.contains(fileName) { return fileName }
        let candidates = names.filter { parts($0).ext == ext }
        return candidates.first { parts($0).stem == stem }
            ?? candidates.first { loose(parts($0).stem) == loose(stem) }
    }
}

/// Minimal zip reading via the system `unzip` (Foundation has no zip API).
enum Zip {
    struct Failed: Error {
        var entry: String
        var status: Int32
    }

    static func read(_ entry: String, from archive: String) throws -> Data {
        try read(pattern: escape(entry), from: archive)
    }

    /// Every entry matching an unzip wildcard pattern, concatenated in archive order.
    static func read(pattern: String, from archive: String) throws -> Data {
        let pipe = Pipe()
        let process = unzip(pattern: pattern, archive, output: pipe.fileHandleForWriting)
        try process.run()
        try? pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { throw Failed(entry: pattern, status: process.terminationStatus) }
        return data
    }

    /// Entry names in the archive.
    static func list(_ archive: String) throws -> [String] {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", archive]
        process.standardOutput = pipe.fileHandleForWriting
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failed(entry: "", status: process.terminationStatus) }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    static func extract(_ entry: String, from archive: String, to file: URL) throws {
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw Failed(entry: entry, status: -1) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let process = unzip(pattern: escape(entry), archive, output: handle)
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failed(entry: entry, status: process.terminationStatus) }
    }

    /// unzip treats entry names as wildcard patterns, so escape the pattern characters.
    private static func escape(_ entry: String) -> String {
        entry.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
    }

    private static func unzip(pattern: String, _ archive: String, output: FileHandle) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // -p: to stdout; -qq: quiet.
        process.arguments = ["-p", "-qq", archive, pattern]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        return process
    }
}
