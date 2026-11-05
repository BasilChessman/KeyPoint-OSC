import Foundation
import Network
import Testing
@testable import KeyPointCore

/// The client against a local stand-in for the bridge: a TCP server sending DSAN lines.
@Suite struct PerfectCueClientTests {
    final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var events: [PerfectCueEvent] = []
        var states: [Bool] = []
        func add(_ e: PerfectCueEvent) { lock.withLock { events.append(e) } }
        func add(_ s: Bool) { lock.withLock { states.append(s) } }
        var snapshot: ([PerfectCueEvent], [Bool]) { lock.withLock { (events, states) } }
    }

    @Test func receivesPressesAndReconnects() async throws {
        let queue = DispatchQueue(label: "test.bridge")
        let listener = try NWListener(using: .tcp, on: .any)
        let accepted = Recorder()
        listener.newConnectionHandler = { conn in
            conn.start(queue: queue)
            accepted.add(true)
            // Split mid-message, as TCP may; the first connection then closes.
            let first = accepted.snapshot.1.count == 1
            conn.send(content: Data(">BLKLEDOF 63\r>FRWLEDON 81\r>FRWLEDOF 79\r>RVSL".utf8), completion: .contentProcessed { _ in
                conn.send(content: Data("EDON 8D\r>FRWLEDON 00\r".utf8), completion: .contentProcessed { _ in
                    if first { queue.asyncAfter(deadline: .now() + 0.1) { conn.cancel() } }
                })
            })
        }
        listener.start(queue: queue)
        for _ in 0..<200 where (listener.port?.rawValue ?? 0) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let port = try #require(listener.port?.rawValue)
        defer { listener.cancel() }

        let got = Recorder()
        let client = PerfectCueClient(onEvent: { e, _ in got.add(e) }, onState: { c, _ in got.add(c) })
        client.retryDelay = 0.2
        client.start(host: "127.0.0.1", port: port)
        defer { client.stop() }
        for _ in 0..<300 where got.snapshot.0.count < 6 { try await Task.sleep(for: .milliseconds(10)) }
        let (events, states) = got.snapshot
        // Two connections' worth: blank off, forward, back (bad checksum dropped), each time.
        #expect(events == [.blankOff, .forward, .back, .blankOff, .forward, .back])
        #expect(states.prefix(3) == [true, false, true])
    }
}
