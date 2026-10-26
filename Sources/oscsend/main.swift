import Foundation
import KeyPointCore

// oscsend: send one OSC message and print any feedback that comes back.
//
//   oscsend [--host 127.0.0.1] [--port 35551] [--listen 35550] [--wait 1.5] /address [args...]
//
// Arguments: integers -> i, decimals -> f, true/false -> T/F, b:text -> UTF-8 blob,
// s:text or anything else -> string. With --listen, feedback is printed for --wait seconds.

var host = "127.0.0.1"
var port: UInt16 = 35551
var listenPort: UInt16?
var wait = 1.5
var positional: [String] = []

var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--host": host = args.next() ?? host
    case "--port": port = args.next().flatMap(UInt16.init) ?? port
    case "--listen": listenPort = args.next().flatMap(UInt16.init)
    case "--wait": wait = args.next().flatMap(Double.init) ?? wait
    default: positional.append(arg)
    }
}

func describe(_ arg: OSCArgument) -> String {
    switch arg {
    case .string(let s): return "\"\(s)\""
    case .blob(let d): return "blob(\(String(data: d, encoding: .utf8).map { "\"\($0)\"" } ?? "\(d.count) bytes"))"
    case .int(let i): return "\(i)"
    case .float(let f): return "\(f)f"
    case .bool(let b): return "\(b)"
    default: return "\(arg)"
    }
}

let listener = UDPListener()
if let listenPort {
    try listener.start(port: listenPort, localOnly: false) { data, peer in
        guard let packet = try? OSCDecoder.decode(data) else { return }
        for m in packet.messages {
            let text = m.arguments.map(describe).joined(separator: " ")
            print("<- \(m.address) \(text.count > 300 ? String(text.prefix(300)) + "…" : text)")
        }
    }
}

if let address = positional.first {
    let oscArgs: [OSCArgument] = positional.dropFirst().map { a in
        if a.hasPrefix("b:") { return .blob(Data(a.dropFirst(2).utf8)) }
        if a.hasPrefix("s:") { return .string(String(a.dropFirst(2))) }
        if a == "true" || a == "false" { return .bool(a == "true") }
        if let i = Int32(a) { return .int(i) }
        if a.contains("."), let f = Float(a) { return .float(f) }
        return .string(a)
    }
    try UDPSender().send(OSCEncoder.encode(OSCMessage(address, oscArgs)), to: host, port: port)
    print("-> \(address) \(oscArgs.map(describe).joined(separator: " "))")
}

if listenPort != nil {
    Thread.sleep(forTimeInterval: wait)
}
