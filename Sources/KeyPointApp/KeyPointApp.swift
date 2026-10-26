import AppKit
import KeyPointBackends
import KeyPointCore
import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--bench") {
            Bench.run()
        } else {
            KeyPointApp.main()
        }
    }
}

/// `KeyPointOSC --bench [next]`: times backend calls in-process, for diagnosing latency.
/// BENCH_N sets the number of polls; KEYPOINT_TRACE=1 prints each script's time.
enum Bench {
    static func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        let backend = PowerPointBackend()
        let clock = ContinuousClock()
        let polls = Int(ProcessInfo.processInfo.environment["BENCH_N"] ?? "5") ?? 5
        Task.detached {
            do {
                for i in 0..<polls {
                    var snap = BackendSnapshot.empty
                    let t = try await clock.measure { snap = try await backend.poll() }
                    print("poll \(i): \(t) slide=\(snap.show?.currentSlide ?? -1) build=\(snap.show?.buildPosition ?? -1)")
                }
                if CommandLine.arguments.contains("next") {
                    for i in 0..<3 {
                        let t = try await clock.measure { try await backend.perform(.next, options: BackendOptions()) }
                        print("next \(i): \(t)")
                    }
                }
            } catch {
                print("error: \(error)")
            }
            exit(0)
        }
        // Scripts compile on the main thread, so keep its run loop going.
        RunLoop.main.run()
    }
}

struct KeyPointApp: App {
    @State private var engine: Engine

    init() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let engine = Engine(
            backends: [PowerPointBackend(), KeynoteBackend()],
            settings: SettingsStore.load(),
            sink: UDPSender(),
            version: "KeyPoint OSC \(version)",
            onSettingsChange: { SettingsStore.save($0) })
        _engine = State(initialValue: engine)
        engine.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(engine: engine)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        if engine.listenError != nil || engine.lastError == .notAuthorized { return "exclamationmark.triangle" }
        if engine.snapshot.show != nil { return "play.rectangle.fill" }
        return engine.activeBackend == nil ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle"
    }
}
