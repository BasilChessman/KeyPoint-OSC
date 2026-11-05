import Foundation
import Network

/// A press on a DSAN PerfectCue, as reported by the PerfectCue bridge
/// (github.com/BasilChessman/perfectcue-bridge). The base station also sends the press to the
/// presentation Mac as a keystroke, so each Forward or Back is one step in the show.
public enum PerfectCueEvent: Equatable, Sendable {
    case forward, back, blankOn, blankOff
}

/// DSAN's cue light messages: `>` + command + space + 2-digit hex checksum + CR, where the
/// checksum is the low byte of the sum of the command's bytes and the space.
public enum PerfectCueProtocol {
    public static func checksum(_ command: String) -> String {
        String(format: "%02X", (command + " ").utf8.reduce(UInt8(0)) { $0 &+ $1 })
    }

    public static func message(_ command: String) -> String {
        ">\(command) \(checksum(command))\r"
    }

    /// The event a line announces. A light turning on is the press; turning off is ignored,
    /// except for Blank, which is a state.
    public static func event(fromLine line: String) -> PerfectCueEvent? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(">") else { return nil }
        let parts = text.dropFirst().split(separator: " ")
        guard parts.count == 2, checksum(String(parts[0])) == parts[1].uppercased() else { return nil }
        switch parts[0] {
        case "FRWLEDON": return .forward
        case "RVSLEDON": return .back
        case "BLKLEDON": return .blankOn
        case "BLKLEDOF": return .blankOff
        default: return nil
        }
    }

    /// Splits a TCP stream into lines (CR or LF), keeping any incomplete tail in `buffer`.
    public static func lines(appending data: Data, to buffer: inout Data) -> [String] {
        buffer.append(data)
        var out: [String] = []
        while let end = buffer.firstIndex(where: { $0 == 13 || $0 == 10 }) {
            let line = buffer[buffer.startIndex..<end]
            buffer.removeSubrange(buffer.startIndex...end)
            if !line.isEmpty { out.append(String(decoding: line, as: UTF8.self)) }
        }
        if buffer.count > 4096 { buffer.removeAll() } // not a cue light stream
        return out
    }
}

/// Listens to a PerfectCue bridge over TCP and reports presses. It never sends anything to
/// the bridge, and reconnects every few seconds while enabled.
public final class PerfectCueClient: @unchecked Sendable {
    public typealias EventHandler = @Sendable (PerfectCueEvent, Date) -> Void
    /// Connected or not, plus a reason when not.
    public typealias StateHandler = @Sendable (Bool, String?) -> Void

    private let queue = DispatchQueue(label: "keypoint.perfectcue")
    private let onEvent: EventHandler
    private let onState: StateHandler
    // Touched only on `queue`.
    private var connection: NWConnection?
    private var endpoint: (host: String, port: UInt16)?
    private var buffer = Data()
    private var generation = 0
    public var retryDelay: TimeInterval = 3

    public init(onEvent: @escaping EventHandler, onState: @escaping StateHandler) {
        self.onEvent = onEvent
        self.onState = onState
    }

    public func start(host: String, port: UInt16) {
        queue.async {
            self.stopLocked()
            self.endpoint = (host, port)
            self.connectLocked()
        }
    }

    public func stop() {
        queue.async {
            self.stopLocked()
            self.endpoint = nil
        }
    }

    private func stopLocked() {
        generation += 1
        connection?.cancel()
        connection = nil
        buffer.removeAll()
    }

    private func connectLocked() {
        guard let endpoint, let port = NWEndpoint.Port(rawValue: endpoint.port) else { return }
        generation += 1
        let current = generation
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 5
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: NWParameters(tls: nil, tcp: tcp))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, current == self.generation else { return }
            switch state {
            case .ready:
                self.onState(true, nil)
                self.receiveLocked(connection, current)
            case .waiting(let error), .failed(let error):
                self.onState(false, "\(error)")
                self.retryLocked(current)
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveLocked(_ connection: NWConnection, _ current: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, current == self.generation else { return }
            let now = Date()
            if let data, !data.isEmpty {
                for line in PerfectCueProtocol.lines(appending: data, to: &self.buffer) {
                    if let event = PerfectCueProtocol.event(fromLine: line) { self.onEvent(event, now) }
                }
            }
            if complete || error != nil {
                self.onState(false, error.map { "\($0)" } ?? "bridge closed the connection")
                self.retryLocked(current)
            } else {
                self.receiveLocked(connection, current)
            }
        }
    }

    private func retryLocked(_ current: Int) {
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        queue.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self, current == self.generation, self.endpoint != nil else { return }
            self.connectLocked()
        }
    }
}
