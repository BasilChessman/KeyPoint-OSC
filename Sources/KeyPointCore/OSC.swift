import Foundation

/// A single OSC argument. Covers the OSC 1.0 core types plus the common extensions
/// that Companion and other clients send (T/F/N/I, int64, double).
public enum OSCArgument: Equatable, Sendable {
    case int(Int32)
    case float(Float)
    case string(String)
    case blob(Data)
    case bool(Bool)
    case int64(Int64)
    case double(Double)
    case null
    case impulse
    case timeTag(UInt64)

    var typeTag: Character {
        switch self {
        case .int: "i"
        case .float: "f"
        case .string: "s"
        case .blob: "b"
        case .bool(let v): v ? "T" : "F"
        case .int64: "h"
        case .double: "d"
        case .null: "N"
        case .impulse: "I"
        case .timeTag: "t"
        }
    }
}

public extension OSCArgument {
    /// Integer value for any numeric argument (and numeric strings), as clients differ in what they send.
    var intValue: Int? {
        switch self {
        case .int(let v): Int(v)
        case .int64(let v): Int(exactly: v)
        case .float(let v): v.isFinite ? Int(v.rounded()) : nil
        case .double(let v): v.isFinite ? Int(v.rounded()) : nil
        case .bool(let v): v ? 1 : 0
        case .string(let s): Int(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let v): Double(v)
        case .int64(let v): Double(v)
        case .float(let v): Double(v)
        case .double(let v): v
        case .string(let s): Double(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    /// Text value: OSC strings as-is, blobs decoded as UTF-8 (the OSCPoint convention).
    var textValue: String? {
        switch self {
        case .string(let s): s
        case .blob(let d): String(data: d, encoding: .utf8)
        default: nil
        }
    }
}

public struct OSCMessage: Equatable, Sendable {
    public var address: String
    public var arguments: [OSCArgument]

    public init(_ address: String, _ arguments: [OSCArgument] = []) {
        self.address = address
        self.arguments = arguments
    }
}

public enum OSCPacket: Equatable, Sendable {
    case message(OSCMessage)
    case bundle(timeTag: UInt64, elements: [OSCPacket])

    /// All messages in this packet, with bundles flattened in order.
    public var messages: [OSCMessage] {
        switch self {
        case .message(let m): [m]
        case .bundle(_, let elements): elements.flatMap(\.messages)
        }
    }
}

public enum OSCDecodeError: Error, Equatable {
    case truncated
    case badString
    case badAddress
    case badTypeTags
    case unsupportedType(Character)
    case badBundle
    case nestingTooDeep
}

// MARK: - Encoding

public enum OSCEncoder {
    public static func encode(_ message: OSCMessage) -> Data {
        var out = Data()
        appendString(message.address, to: &out)
        appendString("," + String(message.arguments.map(\.typeTag)), to: &out)
        for arg in message.arguments {
            switch arg {
            case .int(let v): appendBE(UInt32(bitPattern: v), to: &out)
            case .float(let v): appendBE(v.bitPattern, to: &out)
            case .string(let s): appendString(s, to: &out)
            case .blob(let d):
                appendBE(UInt32(d.count), to: &out)
                out.append(d)
                pad(&out)
            case .int64(let v): appendBE(UInt64(bitPattern: v), to: &out)
            case .double(let v): appendBE(v.bitPattern, to: &out)
            case .timeTag(let v): appendBE(v, to: &out)
            case .bool, .null, .impulse: break
            }
        }
        return out
    }

    public static func encode(_ packet: OSCPacket) -> Data {
        switch packet {
        case .message(let m):
            return encode(m)
        case .bundle(let timeTag, let elements):
            var out = Data()
            appendString("#bundle", to: &out)
            appendBE(timeTag, to: &out)
            for element in elements {
                let body = encode(element)
                appendBE(UInt32(body.count), to: &out)
                out.append(body)
            }
            return out
        }
    }

    private static func appendString(_ s: String, to out: inout Data) {
        out.append(contentsOf: Array(s.utf8))
        out.append(0)
        pad(&out)
    }

    private static func pad(_ out: inout Data) {
        while out.count % 4 != 0 { out.append(0) }
    }

    private static func appendBE<T: FixedWidthInteger>(_ v: T, to out: inout Data) {
        withUnsafeBytes(of: v.bigEndian) { out.append(contentsOf: $0) }
    }
}

// MARK: - Decoding

public enum OSCDecoder {
    static let maxBundleDepth = 8

    public static func decode(_ data: Data) throws -> OSCPacket {
        var reader = Reader(bytes: [UInt8](data))
        return try decodePacket(&reader, depth: 0)
    }

    private static func decodePacket(_ r: inout Reader, depth: Int) throws -> OSCPacket {
        guard let first = r.peek() else { throw OSCDecodeError.truncated }
        if first == UInt8(ascii: "#") {
            guard depth < maxBundleDepth else { throw OSCDecodeError.nestingTooDeep }
            guard try r.readString() == "#bundle" else { throw OSCDecodeError.badBundle }
            let timeTag = try r.readUInt64()
            var elements: [OSCPacket] = []
            while !r.atEnd {
                let size = Int(try r.readUInt32())
                guard size > 0, size % 4 == 0 else { throw OSCDecodeError.badBundle }
                var sub = Reader(bytes: try r.readBytes(size))
                elements.append(try decodePacket(&sub, depth: depth + 1))
            }
            return .bundle(timeTag: timeTag, elements: elements)
        }
        return .message(try decodeMessage(&r))
    }

    private static func decodeMessage(_ r: inout Reader) throws -> OSCMessage {
        let address = try r.readString()
        guard address.hasPrefix("/") else { throw OSCDecodeError.badAddress }
        // A message with no type tag string is legal in old OSC; treat it as no arguments.
        if r.atEnd { return OSCMessage(address) }
        let tags = try r.readString()
        guard tags.first == "," else { throw OSCDecodeError.badTypeTags }
        var args: [OSCArgument] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "i": args.append(.int(Int32(bitPattern: try r.readUInt32())))
            case "f": args.append(.float(Float(bitPattern: try r.readUInt32())))
            case "s", "S": args.append(.string(try r.readString()))
            case "b":
                let n = Int(try r.readUInt32())
                args.append(.blob(Data(try r.readBytes(n))))
                try r.skipPadding(n)
            case "h": args.append(.int64(Int64(bitPattern: try r.readUInt64())))
            case "d": args.append(.double(Double(bitPattern: try r.readUInt64())))
            case "t": args.append(.timeTag(try r.readUInt64()))
            case "T": args.append(.bool(true))
            case "F": args.append(.bool(false))
            case "N": args.append(.null)
            case "I": args.append(.impulse)
            case "c", "r", "m": _ = try r.readUInt32() // char, RGBA, MIDI: not used, skip
            case "[", "]": continue // arrays: flatten
            default: throw OSCDecodeError.unsupportedType(tag)
            }
        }
        return OSCMessage(address, args)
    }

    private struct Reader {
        let bytes: [UInt8]
        var pos = 0

        var atEnd: Bool { pos >= bytes.count }
        func peek() -> UInt8? { atEnd ? nil : bytes[pos] }

        mutating func readBytes(_ n: Int) throws -> [UInt8] {
            guard n >= 0, pos + n <= bytes.count else { throw OSCDecodeError.truncated }
            defer { pos += n }
            return Array(bytes[pos..<pos + n])
        }

        mutating func skipPadding(_ n: Int) throws {
            let padded = (n + 3) & ~3
            _ = try readBytes(padded - n)
        }

        mutating func readString() throws -> String {
            guard let end = bytes[pos...].firstIndex(of: 0) else { throw OSCDecodeError.truncated }
            let raw = bytes[pos..<end]
            let length = end - pos
            pos = end + 1
            pos += (4 - (length + 1) % 4) % 4
            guard pos <= bytes.count else { throw OSCDecodeError.truncated }
            guard let s = String(bytes: raw, encoding: .utf8) else { throw OSCDecodeError.badString }
            return s
        }

        mutating func readUInt32() throws -> UInt32 {
            try readBytes(4).reduce(0) { $0 << 8 | UInt32($1) }
        }

        mutating func readUInt64() throws -> UInt64 {
            try readBytes(8).reduce(0) { $0 << 8 | UInt64($1) }
        }
    }
}

public extension String {
    /// OSC strings are ASCII by convention. Non-ASCII characters become "?" so that
    /// clients that assume ASCII don't choke; the UTF-8 text goes alongside as a blob.
    var oscASCII: String {
        String(unicodeScalars.map { $0.isASCII ? Character($0) : "?" })
    }
}
