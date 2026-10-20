import Foundation
import CoreAudio
import Darwin

// Run only while the user plays the supplied quiet Chrome fixture. Real Chrome
// is measured against its native baseline; raw audio is never saved.
enum ChromeVerification {
    static func run(reportURL: URL) {
        let engine = AudioEngine()
        let cleanup = OutputCleanupLog()
        var monitors: [OutputCaptureMonitor] = []
        var report: [String: Any] = ["passed": false, "audioSaved": false, "acousticLoudnessVerified": false]
        var checks: [String] = []
        func save(_ stage: String) {
            report["stage"] = stage; report["checks"] = checks
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: reportURL, options: .atomic)
            }
        }
        func awaitValue<T>(_ start: (@escaping (T) -> Void) -> Void) throws -> T {
            let ready = DispatchSemaphore(value: 0); var value: T?
            start { value = $0; ready.signal() }
            guard ready.wait(timeout: .now() + 70) == .success, let value else { throw AudioFailure(message: "Audio operation did not return") }
            return value
        }
        func peak(_ monitor: OutputCaptureMonitor) throws -> Float {
            _ = monitor.takePeak(); let before = monitor.callbacks
            Thread.sleep(forTimeInterval: 0.35)
            let value = monitor.takePeak()
            guard monitor.callbacks > before else { throw AudioFailure(message: "Monitoring channel received no audio callbacks") }
            return value
        }
        func objects(pid: pid_t) -> [AudioObjectID] {
            HAL.ids(HAL.system, kAudioHardwarePropertyProcessObjectList).filter {
                HAL.value($0, kAudioProcessPropertyPID, default: pid_t(0)) == pid
            }
        }
        save("waitingForChromePlayback")
        do {
            let originalOutput = try HAL.defaultOutput()
            let originalTaps = Set(HAL.ids(HAL.system, kAudioHardwarePropertyTapList))
            var source: AudioSource?
            let playbackDeadline = ProcessInfo.processInfo.systemUptime + 30
            while ProcessInfo.processInfo.systemUptime < playbackDeadline {
                source = SourceDiscovery.scan().first { $0.id == "com.google.Chrome" && $0.running }
                if source != nil { break }
                Thread.sleep(forTimeInterval: 0.3)
            }
            guard let source else { throw AudioFailure(message: "Chrome is not playing audio. Click Start test tone on the fixture page first.") }
            report["chromeProcesses"] = source.processes.map { object -> [String: Any] in
                ["object": object, "pid": HAL.value(object, kAudioProcessPropertyPID, default: pid_t(0)),
                 "running": HAL.value(object, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)),
                 "devices": HAL.ids(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)]
            }
            save("nativeBaseline")
            let activeProcesses = source.processes.filter {
                HAL.value($0, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
            }
            report["baselineProcessObjects"] = activeProcesses
            let baseline = try OutputCaptureMonitor(processes: activeProcesses, label: "Chrome-native", cleanup: cleanup)
            monitors.append(baseline)
            let readyAt = ProcessInfo.processInfo.systemUptime + 8
            var initialSignal: Float = 0
            while ProcessInfo.processInfo.systemUptime < readyAt {
                initialSignal = max(initialSignal, baseline.takePeak())
                if baseline.callbacks >= 3, initialSignal > 0.0000001 { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            report["baselineCallbacks"] = baseline.callbacks
            report["initialSignal"] = initialSignal
            let baseA = try peak(baseline), baseB = try peak(baseline)
            report["nativeBaseline"] = [baseA, baseB]
            if baseA == 0, baseB == 0 {
                // Separate Chrome's process-wide mixdown path from the exact
                // device-scoped path used by the production mixer.
                let deviceMonitor = try TapSession(processes: activeProcesses, output: originalOutput, gain: 0, playback: false)
                Thread.sleep(forTimeInterval: 0.5)
                _ = deviceMonitor.takePeak()
                Thread.sleep(forTimeInterval: 0.4)
                report["deviceScopedPeak"] = deviceMonitor.takePeak()
                report["deviceScopedCallbacks"] = deviceMonitor.callbacks
                report["deviceScopedValidCallbacks"] = deviceMonitor.validCallbacks
                report["deviceScopedCleanup"] = deviceMonitor.stop()
            }
            guard baseA > 0.0000001, baseB > 0.0000001, abs(baseA / baseB - 1) < 0.04 else {
                throw AudioFailure(message: "Chrome native signal is zero or unstable. Use the local fixture and allow system audio access.")
            }
            let native = (baseA + baseB) / 2
            checks.append("Real Chrome produces a stable native signal")
            save("enablingWorker")
            let enabled: Result<Void, Error> = try awaitValue { engine.enable(completion: $0) }
            try enabled.get()
            let settings = [source.id: VolumeSetting(volume: 50, muted: false, name: source.name)]
            var connected = false
            save("connectingChrome")
            for _ in 0..<35 {
                let snapshot: EngineSnapshot = try awaitValue { engine.refresh(settings: settings, completion: $0) }
                guard snapshot.errors.isEmpty else { throw AudioFailure(message: snapshot.errors.values.joined(separator: "; ")) }
                if snapshot.controlled.contains(source.id) { connected = true; break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            guard connected, let worker = engine.workerPID else { throw AudioFailure(message: "Chrome audio connection did not become valid") }
            report["workerPID"] = worker
            let workerObjects = objects(pid: worker)
            guard !workerObjects.isEmpty else { throw AudioFailure(message: "Audio worker output not found") }
            report["workerObjects"] = workerObjects
            let replay = try OutputCaptureMonitor(processes: workerObjects, label: "Chrome-replay", cleanup: cleanup)
            monitors.append(replay)
            checks.append("Real Chrome connects through production AudioEngine worker")
            save("measuringGains")
            var samples: [[String: Any]] = []
            for volume in [50.0, 25.0, 0.0] {
                let snapshot: EngineSnapshot = try awaitValue {
                    engine.refresh(settings: [source.id: VolumeSetting(volume: volume, muted: false, name: source.name)], completion: $0)
                }
                guard snapshot.errors.isEmpty, snapshot.controlled.contains(source.id) else { throw AudioFailure(message: "Chrome connection interrupted during adjustment") }
                Thread.sleep(forTimeInterval: 0.2)
                let observed = try peak(replay), ratio = observed / native
                let diagnostics: [String: EngineSessionDiagnostics] = try awaitValue { engine.diagnostics(completion: $0) }
                let diagnostic = diagnostics[source.id]
                samples.append(["requestedVolume": volume, "replayPeak": observed, "relativeToNative": ratio,
                                "controlProcesses": diagnostic?.processes ?? [], "controlInputPeak": diagnostic?.inputPeak ?? 0,
                                "controlOutputPeak": diagnostic?.outputPeak ?? 0, "controlValidCallbacks": diagnostic?.validCallbacks ?? 0])
                report["gainSamples"] = samples; save("measuringGains")
                let expected = Float(volume / 100)
                guard abs(ratio - expected) < (volume == 0 ? 0.001 : 0.04) else {
                    throw AudioFailure(message: "Chrome digital output does not match the requested \(Int(volume))% gain")
                }
            }
            checks.append("Independent replay capture matches Chrome native baseline at 50%, 25% and mute")
            save("restoringNative")
            let _: Bool = try awaitValue { callback in engine.disable { callback(true) } }
            Thread.sleep(forTimeInterval: 0.3)
            report["workerStopError"] = engine.lastStopError ?? ""
            report["workerExited"] = kill(worker, 0) != 0
            guard engine.lastStopError == nil, engine.workerPID == nil, kill(worker, 0) != 0 else {
                throw AudioFailure(message: "Audio worker did not clean up and exit normally")
            }
            let restored = try peak(baseline)
            report["restoredNativePeak"] = restored
            guard abs(restored / native - 1) < 0.04 else { throw AudioFailure(message: "Chrome did not return to the native signal baseline after release") }
            checks.append("Disable restores Chrome native baseline")
            for monitor in monitors { monitor.stop() }; monitors.removeAll()
            guard !cleanup.hasUnreleasedObjects else { throw AudioFailure(message: "Independent monitoring channel not fully released") }
            // A foreign client cannot inspect private taps. Cleanup evidence is
            // each owner's successful destroy replies and the worker's exit.
            // Retain the observer's local list as diagnostics, not a global leak test.
            let listed = Set(HAL.ids(HAL.system, kAudioHardwarePropertyTapList)).subtracting(originalTaps)
            report["observerTapListBeforeExit"] = listed.sorted()
            guard try HAL.defaultOutput() == originalOutput else { throw AudioFailure(message: "Default output device changed") }
            checks.append("Worker cleanup acknowledged and process exited; monitor destroy calls succeeded; default output unchanged")
            report["passed"] = true
        } catch { report["error"] = error.localizedDescription }
        engine.shutdown()
        for monitor in monitors { monitor.stop() }
        report["cleanupOperations"] = cleanup.operations
        save("finished")
    }
}
