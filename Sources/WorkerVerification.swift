import Foundation
import Darwin

// Protocol/lifecycle verification uses mock workers: it never reads HAL, plays
// a sound, creates a tap, or changes the user's saved application volumes.
enum WorkerVerification {
    static func run(reportURL: URL) {
        var checks: [String] = []
        var clients: [AudioEngine] = []
        var report: [String: Any] = ["usesRealAudio": false]
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw AudioFailure(message: message) }
        }
        func awaitValue<T>(_ body: (@escaping (T) -> Void) -> Void) throws -> T {
            let ready = DispatchSemaphore(value: 0)
            var result: T?
            body { result = $0; ready.signal() }
            guard ready.wait(timeout: .now() + 5) == .success, let result else {
                throw AudioFailure(message: "Worker test callback timed out")
            }
            return result
        }
        func client(_ mode: String) -> AudioEngine {
            let value = AudioEngine(workerMode: mode, requestTimeout: 0.4, enableTimeout: 0.4, stopTimeout: 0.2)
            clients.append(value); return value
        }
        do {
            let normal = client("fixture")
            let enabled: Result<Void, Error> = try awaitValue { normal.enable(completion: $0) }
            try enabled.get()
            let value: EngineSnapshot = try awaitValue { normal.refresh(settings: [:], completion: $0) }
            try require(value.sources.first?.id == "fixture", "Snapshot did not survive JSON framing")
            let levels: [String: Float] = try awaitValue { normal.meters(completion: $0) }
            try require(levels["fixture"] == 0.25, "Meter reply incorrect")
            let child = normal.workerPID!
            let _: Bool = try awaitValue { callback in normal.disable { callback(true) } }
            Thread.sleep(forTimeInterval: 0.1)
            try require(kill(child, 0) != 0, "Worker remained after disable")
            checks.append("Enable/refresh/meters round trip and disable terminates child")

            let hung = client("hang-refresh")
            let start = ProcessInfo.processInfo.systemUptime
            let failed: EngineSnapshot = try awaitValue { hung.refresh(settings: [:], completion: $0) }
            try require(failed.errors["output"] != nil && hung.workerPID == nil, "Hung HAL request did not stop worker")
            try require(ProcessInfo.processInfo.systemUptime - start < 2, "Hung request blocked too long")
            let attempts = hung.requestStatistics["refresh"]
            let _: EngineSnapshot = try awaitValue { hung.refresh(settings: [:], completion: $0) }
            try require(hung.requestStatistics["refresh"] == attempts, "Timeout automatically respawned worker")
            checks.append("Hung request has bounded deadline and no automatic respawn")

            let cancel = client("hang-enable")
            var canceled: Result<Void, Error>?
            cancel.enable { canceled = $0 }
            Thread.sleep(forTimeInterval: 0.08)
            let cancelStart = ProcessInfo.processInfo.systemUptime
            let _: Bool = try awaitValue { callback in cancel.disable { callback(true) } }
            try require(cancel.workerPID == nil && ProcessInfo.processInfo.systemUptime - cancelStart < 1, "Enable cancellation failed")
            try require(canceled != nil, "Canceled enable lost its completion")
            checks.append("Cancel interrupts unanswered enable without waiting for permission deadline")

            let stop = client("hang-disable")
            let stoppedEnable: Result<Void, Error> = try awaitValue { stop.enable(completion: $0) }
            try stoppedEnable.get()
            let stopPID = stop.workerPID!
            let _: Bool = try awaitValue { callback in stop.disable { callback(true) } }
            Thread.sleep(forTimeInterval: 0.1)
            try require(kill(stopPID, 0) != 0, "Blocked teardown kept worker alive")
            checks.append("Blocked teardown is terminated at stop deadline")

            let crashed = client("crash")
            let crash: EngineSnapshot = try awaitValue { crashed.refresh(settings: [:], completion: $0) }
            try require(crash.errors["output"] != nil && crashed.workerPID == nil, "Crash was not reported")
            checks.append("Unexpected worker death is reported without hanging UI")

            let missing = AudioEngine(executable: URL(fileURLWithPath: "/private/tmp/volume-mixer-no-such-worker-\(UUID().uuidString)"))
            clients.append(missing)
            let missingSnapshot: EngineSnapshot = try awaitValue { missing.refresh(settings: [:], completion: $0) }
            try require(missingSnapshot.errors["output"] != nil, "Worker launch error was hidden")
            checks.append("Worker launch failure is visible and does not keep retrying")

            let dragging = client("slow-refresh")
            let suite = "io.github.HaomingLyu613.VolumeMixer.test.\(UUID().uuidString)"
            let store = UserDefaults(suiteName: suite)!
            defer { store.removePersistentDomain(forName: suite) }
            var model: MixerModel!
            DispatchQueue.main.sync {
                model = MixerModel(engine: dragging, automaticRefresh: false, settingsStore: store)
                let source = AudioSource(id: "fixture", name: "Test App", bundleURL: nil, processes: [], running: false)
                for index in 0..<1000 { model.setVolume(Double(index % 101), for: source) }
                model.setVolume(37, for: source)
            }
            Thread.sleep(forTimeInterval: 0.8)
            var finalVolume = 0.0, outputName = ""
            DispatchQueue.main.sync {
                finalVolume = model.setting(for: "fixture").volume
                outputName = model.outputName
                model.shutdown()
            }
            let scans = dragging.requestStatistics["refresh"] ?? 0
            try require((1...3).contains(scans), "Slider burst queued \(scans) scans")
            try require(finalVolume == 37 && outputName == "Test Output 37.0", "Latest slider setting was lost")
            checks.append("1001 slider updates coalesce to \(scans) scans; final 37% reaches worker")
            report["passed"] = true
        } catch {
            report["passed"] = false; report["error"] = error.localizedDescription
        }
        for client in clients { client.shutdown() }
        report["checks"] = checks
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: reportURL, options: .atomic)
        }
    }
}
