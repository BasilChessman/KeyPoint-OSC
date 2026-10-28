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

/// PowerPoint's scripting doesn't expose clip length, so read it from the saved .pptx:
/// find the slide's first media item, extract it, and ask AVFoundation. Lookups never block;
/// the first call for a slide starts a background read and returns nil until it's done.
/// Results are cached per file version, so a re-save is picked up.
final class MediaDurationResolver: @unchecked Sendable {
    private struct Key: Hashable {
        var path: String
        var modified: Date
        var slide: Int
    }

    private let lock = NSLock()
    private var cache: [Key: MediaClip?] = [:] // a nil value: looked, found nothing usable
    private var pending: Set<Key> = []
    private let queue = DispatchQueue(label: "keypoint.media-duration", qos: .utility)

    /// The media clip on slide `slide` (1-based) of the saved file at `path`, if known yet.
    func clip(deckPath path: String, slide: Int) -> MediaClip? {
        guard !path.isEmpty, slide > 0,
              let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return nil }
        let key = Key(path: path, modified: modified, slide: slide)
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        if pending.insert(key).inserted {
            queue.async {
                let clip = PPTXMedia.clip(deckPath: path, slide: slide)
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
              let ms = duration(of: media.source, deckPath: deckPath)
        else { return nil }
        return MediaClip(fileDuration: ms, trimStart: media.trimStart, trimEnd: media.trimEnd)
    }

    /// The first top-level media item on the slide: the one PowerPoint's `shapes of slide`
    /// loop (and so the media actions) finds first.
    static func media(deckPath: String, slide: Int) throws -> Media? {
        let presentationRels = try relationships(try Zip.read("ppt/_rels/presentation.xml.rels", from: deckPath))
        let presentation = try XMLDocument(data: try Zip.read("ppt/presentation.xml", from: deckPath))
        let slideIDs = try presentation.nodes(forXPath: "//*[local-name()='sldIdLst']/*[local-name()='sldId']")
        guard slide <= slideIDs.count,
              let rid = (slideIDs[slide - 1] as? XMLElement)?.attribute(forLocalName: "id", uri: relNS)?.stringValue,
              let target = presentationRels[rid]?.target
        else { return nil }
        let slidePath = resolve(target, from: "ppt/presentation.xml")
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

    // MARK: Duration

    private static func duration(of source: Media.Source, deckPath: String) -> Int? {
        switch source {
        case .file(let path):
            return assetDuration(URL(fileURLWithPath: path))
        case .entry(let entry):
            // AVFoundation needs a file, so extract the clip to a temporary one.
            let ext = (entry as NSString).pathExtension
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("KeyPointOSC-media-\(UUID().uuidString)")
                .appendingPathExtension(ext.isEmpty ? "mov" : ext)
            defer { try? FileManager.default.removeItem(at: temp) }
            guard (try? Zip.extract(entry, from: deckPath, to: temp)) != nil else { return nil }
            return assetDuration(temp)
        }
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

/// Minimal zip reading via the system `unzip` (Foundation has no zip API).
enum Zip {
    struct Failed: Error {
        var entry: String
        var status: Int32
    }

    static func read(_ entry: String, from archive: String) throws -> Data {
        let pipe = Pipe()
        let process = unzip(entry, archive, output: pipe.fileHandleForWriting)
        try process.run()
        try? pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { throw Failed(entry: entry, status: process.terminationStatus) }
        return data
    }

    static func extract(_ entry: String, from archive: String, to file: URL) throws {
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw Failed(entry: entry, status: -1) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let process = unzip(entry, archive, output: handle)
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failed(entry: entry, status: process.terminationStatus) }
    }

    private static func unzip(_ entry: String, _ archive: String, output: FileHandle) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // -p: to stdout; -qq: quiet. unzip treats the entry name as a wildcard pattern,
        // so escape the pattern characters.
        let pattern = entry.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
        process.arguments = ["-p", "-qq", archive, pattern]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        return process
    }
}
