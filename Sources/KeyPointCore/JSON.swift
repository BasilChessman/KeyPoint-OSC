import Foundation

/// Minimal JSON writer that keeps key order (to match OSCPoint's output) and can
/// escape non-ASCII as \uXXXX so the result is safe in an ASCII OSC string.
public indirect enum JSONValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (a: JSONValue, b: JSONValue) -> Bool {
        a.serialized() == b.serialized()
    }

    public func serialized(asciiOnly: Bool = false) -> String {
        var out = ""
        write(to: &out, asciiOnly: asciiOnly)
        return out
    }

    private func write(to out: inout String, asciiOnly: Bool) {
        switch self {
        case .string(let s): Self.writeString(s, to: &out, asciiOnly: asciiOnly)
        case .int(let i): out += String(i)
        case .bool(let b): out += b ? "true" : "false"
        case .null: out += "null"
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                item.write(to: &out, asciiOnly: asciiOnly)
            }
            out += "]"
        case .object(let pairs):
            out += "{"
            for (i, (key, value)) in pairs.enumerated() {
                if i > 0 { out += "," }
                Self.writeString(key, to: &out, asciiOnly: asciiOnly)
                out += ":"
                value.write(to: &out, asciiOnly: asciiOnly)
            }
            out += "}"
        }
    }

    private static func writeString(_ s: String, to out: inout String, asciiOnly: Bool) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || (asciiOnly && !scalar.isASCII) {
                    for unit in String(scalar).utf16 {
                        out += String(format: "\\u%04x", unit)
                    }
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
