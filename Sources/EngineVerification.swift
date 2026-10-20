import Foundation
import CoreAudio

// Integration coverage for AudioEngine's reconciliation and watchdog, using only
// temporary helper processes. No real application's settings or volume are used.
enum EngineVerification {
    static func run(reportURL: URL) {
        // Called from a worker so AppKit's main queue remains free to deliver
        // the real engine's asynchronous refresh and enable completions.
        perform(reportURL: reportURL)
    }

    private static func perform(reportURL: URL) {
        var report: [String: Any] = [
            "passed": false, "audioSaved": false, "physicalOutputLoudnessVerified": false,
            "measurement": "Gain checks measure emitted DSP buffers; they do not prove physical speaker loudness.",
            "microphoneAudioRecorded": false, "inputParametersModified": false,
            "inputHardwarePreservationVerified": false, "remoteCallAudioOrAECVerified": false,
            "inputHardwarePreservationStatus": "not-evaluated",
            "transportMeasurement": "Capture/render rates and FIFO counters are observed per session. Startup or idle FIFO underflow alone is not a connection failure.",
            "inputMeasurement": "Read-only default-input UID, sample rate and supported input volume/mute controls. Unchanged controls do not prove unchanged remote call sound, echo cancellation (AEC), voice processing, or Bluetooth call behavior."
        ]
        let began = ProcessInfo.processInfo.systemUptime
        let before = hardwareSnapshot()
        let inputBefore = inputHardwareSnapshot()
        let originalTaps = Set(HAL.ids(HAL.system, kAudioHardwarePropertyTapList))
        let fixtures = FixtureSources()
        var children: [Process] = []
        var engine: LocalAudioEngine?
        var checks: [String] = []
        var observations: [[String: Any]] = []
        report["hardwareBefore"] = before
        report["inputHardwareBefore"] = inputBefore
        do {
            let output = try HAL.defaultOutput()
            fixtures.outputID = output.id
            let mixer = LocalAudioEngine(sourceProvider: { fixtures.scan() }, outputProvider: { output })
            engine = mixer
            let enabled: Result<Void, Error> = try awaitValue(timeout: 30) { mixer.enable(completion: $0) }
            try enabled.get()
            var settings = [
                FixtureSources.aID: VolumeSetting(volume: 25, muted: false, name: "Test A"),
                FixtureSources.bID: VolumeSetting(volume: 75, muted: false, name: "Test B")
            ]
            let b = try launchProbe(frequency: 1499, amplitude: 0.0007)
            children.append(b)
            fixtures.setPID(b.processIdentifier, for: FixtureSources.bID)
            let a = try launchProbe(frequency: 997, amplitude: 0.0004, profile: "idle-cycle")
            children.append(a)
            fixtures.setPID(a.processIdentifier, for: FixtureSources.aID)
            let profileStart = ProcessInfo.processInfo.systemUptime
            var idleStarted: TimeInterval?
            var longestIdle: TimeInterval = 0
            var observedResume = false
            var observedIndependentGains = false
            var bActiveSamples = 0
            var originalAProcesses: [AudioObjectID] = []

            func sample(_ stage: String) throws -> (EngineSnapshot, [String: EngineSessionDiagnostics]) {
                let snapshot: EngineSnapshot = try awaitValue { mixer.refresh(settings: settings, completion: $0) }
                let stats: [String: EngineSessionDiagnostics] = try awaitValue { mixer.diagnostics(completion: $0) }
                observations.append([
                    "stage": stage, "elapsed": ProcessInfo.processInfo.systemUptime - profileStart,
                    "errors": snapshot.errors, "controlled": snapshot.controlled.sorted(),
                    "sources": snapshot.sources.map { ["id": $0.id, "running": $0.running, "processes": $0.processes] as [String: Any] },
                    "sessions": stats.mapValues(serialize)
                ])
                guard snapshot.errors.isEmpty else {
                    throw AudioFailure(message: "\(stage): \(snapshot.errors)")
                }
                for (id, session) in stats {
                    guard session.physicalInputIOEnabled == 0,
                          session.captureSampleRate.isFinite, session.captureSampleRate > 0,
                          session.renderSampleRate.isFinite, session.renderSampleRate > 0 else {
                        throw AudioFailure(message: "\(stage): \(id) enabled physical input on the playback channel or reported invalid capture/render sample rates")
                    }
                }
                return (snapshot, stats)
            }

            // Cover the actual three-second watchdog repeatedly, including five
            // seconds with A's real AVAudioEngine stopped, followed by resumption.
            while ProcessInfo.processInfo.systemUptime - profileStart < 10 {
                let (snapshot, stats) = try sample("idle-resume")
                let elapsed = ProcessInfo.processInfo.systemUptime - profileStart
                let aRunning = snapshot.sources.first { $0.id == FixtureSources.aID }?.running ?? false
                if !aRunning {
                    if idleStarted == nil { idleStarted = ProcessInfo.processInfo.systemUptime }
                    longestIdle = max(longestIdle, ProcessInfo.processInfo.systemUptime - (idleStarted ?? profileStart))
                } else { idleStarted = nil }
                if let aStats = stats[FixtureSources.aID], aStats.processingActive {
                    if originalAProcesses.isEmpty { originalAProcesses = aStats.processes }
                    if elapsed > 6.5, validGain(aStats, expected: 0.25) { observedResume = true }
                }
                if let aStats = stats[FixtureSources.aID], let bStats = stats[FixtureSources.bID],
                   validGain(aStats, expected: 0.25), validGain(bStats, expected: 0.75) {
                    observedIndependentGains = true
                }
                if let bStats = stats[FixtureSources.bID], validGain(bStats, expected: 0.75) { bActiveSamples += 1 }
                Thread.sleep(forTimeInterval: 0.2)
            }
            report["longestIdleSeconds"] = longestIdle
            report["continuousBValidSamples"] = bActiveSamples
            guard longestIdle >= 4 else { throw AudioFailure(message: "Did not observe at least four seconds of actual idle I/O") }
            guard observedResume else { throw AudioFailure(message: "A did not automatically resume 25% output after idle") }
            guard observedIndependentGains, bActiveSamples >= 15 else { throw AudioFailure(message: "Independent gains did not remain effective for both applications") }
            checks += ["Real AudioEngine.refresh/completion ran through >3-second watchdog intervals", "A stopped real I/O for >4 seconds without a connection error", "A resumed automatically; B retained 75% emitted gain", "Independent emitted gains A=25%, B=75%"]
            report["hardwareDuring"] = hardwareSnapshot()
            report["inputHardwareDuring"] = inputHardwareSnapshot()

            // Replace the actual audio process while keeping the user's app ID.
            stopProbe(a)
            fixtures.setPID(nil, for: FixtureSources.aID)
            _ = try sample("process-stopped")
            let replacementA = try launchProbe(frequency: 997, amplitude: 0.0004)
            children.append(replacementA)
            fixtures.setPID(replacementA.processIdentifier, for: FixtureSources.aID)
            let restartDeadline = ProcessInfo.processInfo.systemUptime + 5
            var restarted = false
            var beforeSwap: EngineSessionDiagnostics?
            while ProcessInfo.processInfo.systemUptime < restartDeadline {
                let (_, stats) = try sample("process-restarted")
                if let aStats = stats[FixtureSources.aID], let bStats = stats[FixtureSources.bID],
                   !aStats.processes.isEmpty, aStats.processes != originalAProcesses,
                   validGain(aStats, expected: 0.25), validGain(bStats, expected: 0.75) {
                    report["originalAProcessObjects"] = originalAProcesses
                    report["replacementAProcessObjects"] = aStats.processes
                    beforeSwap = aStats
                    restarted = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            guard restarted else { throw AudioFailure(message: "Stable app ID volume setting did not resume after helper restart") }
            checks.append("New A process retained stable app ID and 25% setting")

            // Chrome can replace one active helper directly with another. Keep
            // the old helper alive, and make no intervening empty fixture scan,
            // so this specifically exercises updateProcesses on the same tap.
            guard let previous = beforeSwap, previous.tapID != 0, previous.aggregateID != 0 else {
                throw AudioFailure(message: "No verifiable active audio channel existed before process replacement")
            }
            let swapA = try launchProbe(frequency: 997, amplitude: 0.0004)
            children.append(swapA)
            let helperDeadline = ProcessInfo.processInfo.systemUptime + 3
            var swapObjects: [AudioObjectID] = []
            var swapReady = false
            while ProcessInfo.processInfo.systemUptime < helperDeadline {
                swapObjects = HAL.ids(HAL.system, kAudioHardwarePropertyProcessObjectList).filter {
                    HAL.value($0, kAudioProcessPropertyPID, default: pid_t(0)) == swapA.processIdentifier
                }.sorted()
                if !swapObjects.isEmpty, swapObjects.contains(where: {
                    HAL.value($0, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0 &&
                    HAL.ids($0, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput).contains(output.id)
                }) { swapReady = true; break }
                _ = try sample("new-helper-starting")
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard swapReady else { throw AudioFailure(message: "New helper did not start playing to the current output") }
            fixtures.setPID(swapA.processIdentifier, for: FixtureSources.aID)
            let swapStart = ProcessInfo.processInfo.systemUptime
            var swapSamples = 0
            while ProcessInfo.processInfo.systemUptime - swapStart < 1.6 {
                let (snapshot, stats) = try sample("active-nonempty-topology-swap")
                guard let aStats = stats[FixtureSources.aID], let bStats = stats[FixtureSources.bID],
                      snapshot.sources.first(where: { $0.id == FixtureSources.aID })?.processes == swapObjects,
                      aStats.processes == swapObjects, aStats.processes != previous.processes,
                      aStats.tapID == previous.tapID, aStats.aggregateID == previous.aggregateID,
                      aStats.processingActive, bStats.processingActive,
                      replacementA.isRunning else {
                    throw AudioFailure(message: "Active process replacement did not preserve the tap/aggregate, or produced an empty process set")
                }
                // Allow the first short interval to contain the membership
                // transition, then require both independent gains throughout.
                if ProcessInfo.processInfo.systemUptime - swapStart >= 0.2 {
                    guard validGain(aStats, expected: 0.25), validGain(bStats, expected: 0.75) else {
                        throw AudioFailure(message: "A=25% or B=75% emitted gain did not survive in-place active-process replacement")
                    }
                    swapSamples += 1
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            guard swapSamples >= 5 else { throw AudioFailure(message: "Insufficient sustained gain samples after in-place active-process replacement") }
            report["activeTopologySwap"] = [
                "oldProcesses": previous.processes, "newProcesses": swapObjects,
                "tapID": previous.tapID, "aggregateID": previous.aggregateID,
                "sameTapAndAggregate": true, "validIndependentGainSamples": swapSamples,
                "oldHelperAliveUntilVerified": replacementA.isRunning
            ] as [String: Any]
            stopProbe(replacementA)
            checks.append("Active nonempty A topology swap preserved the same tap/aggregate and sustained A=25%, B=75%")

            settings[FixtureSources.aID]?.muted = true
            _ = try sample("mute-transition")
            Thread.sleep(forTimeInterval: 0.15)
            _ = try sample("mute-settled") // Clear any peak from the short gain ramp.
            Thread.sleep(forTimeInterval: 0.25)
            let (_, mutedStats) = try sample("independent-mute")
            guard let mutedA = mutedStats[FixtureSources.aID], let playingB = mutedStats[FixtureSources.bID],
                  mutedA.processingActive, mutedA.inputPeak > 0.0000001, mutedA.outputPeak == 0,
                  validGain(playingB, expected: 0.75) else {
                throw AudioFailure(message: "Independent A mute or B=75% output did not take effect")
            }
            checks.append("Muting A emits silence while B retains 75%")

            settings[FixtureSources.aID]?.muted = false
            settings[FixtureSources.aID]?.volume = 50
            settings[FixtureSources.bID]?.volume = 30
            _ = try sample("gain-transition")
            Thread.sleep(forTimeInterval: 0.15)
            _ = try sample("gain-settled")
            Thread.sleep(forTimeInterval: 0.25)
            let (_, finalStats) = try sample("gain-changed")
            guard let finalA = finalStats[FixtureSources.aID], let finalB = finalStats[FixtureSources.bID],
                  validGain(finalA, expected: 0.5), validGain(finalB, expected: 0.3) else {
                throw AudioFailure(message: "Emitted gains did not match after unmuting and changing both volumes")
            }
            checks.append("Unmuting and changing both gains emits A=50%, B=30%")
            // Keep the complete engine exercise around sixteen seconds even
            // on fast hardware where process replacement completes immediately.
            while ProcessInfo.processInfo.systemUptime - profileStart < 16 {
                _ = try sample("sustained-playback")
                Thread.sleep(forTimeInterval: 0.2)
            }
            report["engineExerciseSeconds"] = ProcessInfo.processInfo.systemUptime - profileStart
            mixer.shutdown()
            children.forEach(stopProbe)
            children.removeAll()
            let after = hardwareSnapshot()
            report["hardwareAfter"] = after
            let inputAfter = inputHardwareSnapshot()
            report["inputHardwareAfter"] = inputAfter
            let leakedTaps = Set(HAL.ids(HAL.system, kAudioHardwarePropertyTapList)).subtracting(originalTaps)
            report["remainingNewTapObjects"] = Array(leakedTaps).sorted()
            guard leakedTaps.isEmpty else { throw AudioFailure(message: "New audio taps remained after disable") }
            guard hardwareUnchanged(before, after),
                  hardwareUnchanged(before, report["hardwareDuring"] as? [String: Any] ?? [:]) else {
                throw AudioFailure(message: "Default output, sample rate or hardware volume changed during verification; inspect hardware snapshots")
            }
            checks += ["No new audio taps remained after shutdown", "Default output UID, sample rate, master/channel scalar and mute unchanged"]
            checks.append("Every observed transport had valid capture/render rates and AUHAL physical input I/O disabled")
            let inputDuring = report["inputHardwareDuring"] as? [String: Any] ?? [:]
            let inputComparison = compareInputHardware(before: inputBefore, during: inputDuring, after: inputAfter)
            report["inputHardwarePreservationStatus"] = inputComparison.status
            report["inputHardwarePreservationVerified"] = inputComparison.verified
            if let reason = inputComparison.reason { report["inputHardwarePreservationReason"] = reason }
            if let failure = inputComparison.failure { throw AudioFailure(message: failure) }
            if inputComparison.verified {
                checks.append("Read-only default input UID, sample rate and supported input master/channel volume/mute controls unchanged")
            } else {
                checks.append("Default input unavailable; no microphone-control preservation claim")
            }
            report["passed"] = true
        } catch { report["error"] = error.localizedDescription }
        engine?.shutdown()
        children.forEach(stopProbe)
        report["hardwareAfterCleanup"] = hardwareSnapshot()
        report["inputHardwareAfterCleanup"] = inputHardwareSnapshot()
        report["checks"] = checks
        report["observations"] = observations
        report["durationSeconds"] = ProcessInfo.processInfo.systemUptime - began
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: reportURL, options: .atomic)
        } catch { fputs("Cannot write engine verification report: \(error)\n", stderr) }
    }

    private static func launchProbe(frequency: Double, amplitude: Float, profile: String = "continuous") throws -> Process {
        let child = Process()
        child.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AudioProbe")
        child.arguments = ["45", String(amplitude), String(frequency), profile]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        return child
    }

    private static func stopProbe(_ child: Process) {
        guard child.isRunning else { return }
        child.terminate()
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while child.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
    }

    private static func validGain(_ stats: EngineSessionDiagnostics, expected: Float) -> Bool {
        stats.processingActive && stats.validCallbacks >= 3 && stats.inputPeak > 0.0000001 &&
        stats.consecutiveInvalidBuffers == 0 && abs(stats.outputPeak / stats.inputPeak - expected) < 0.025
    }

    private static func serialize(_ stats: EngineSessionDiagnostics) -> [String: Any] {
        ["tapID": stats.tapID, "aggregateID": stats.aggregateID,
         "callbacks": stats.callbacks, "validCallbacks": stats.validCallbacks,
         "invalidBuffers": stats.invalidBuffers, "consecutiveInvalidBuffers": stats.consecutiveInvalidBuffers,
         "processingActive": stats.processingActive, "inputPeak": stats.inputPeak,
         "outputPeak": stats.outputPeak, "processes": stats.processes,
         "captureSampleRate": stats.captureSampleRate, "renderSampleRate": stats.renderSampleRate,
         "physicalInputIOEnabled": stats.physicalInputIOEnabled, "captureCallbacks": stats.captureCallbacks,
         "captureWaitingForInput": stats.captureWaitingForInput, "droppedFrames": stats.droppedFrames,
         "underflowFrames": stats.underflowFrames, "queuedFrames": stats.queuedFrames,
         "emittedGain": stats.inputPeak > 0 ? stats.outputPeak / stats.inputPeak : -1]
    }

    private static func awaitValue<T>(timeout: TimeInterval = 8, _ begin: (@escaping (T) -> Void) -> Void) throws -> T {
        let box = ResultBox<T>()
        let ready = DispatchSemaphore(value: 0)
        begin { value in box.set(value); ready.signal() }
        guard ready.wait(timeout: .now() + timeout) == .success, let value = box.get() else {
            throw AudioFailure(message: "Audio engine asynchronous operation timed out (\(timeout) seconds)")
        }
        return value
    }

    private static func hardwareSnapshot() -> [String: Any] {
        guard let output = try? HAL.defaultOutput() else { return ["available": false] }
        var controls: [String: Double] = [:]
        let channelCount = (try? HAL.buffers(output.id, scope: kAudioObjectPropertyScopeOutput).reduce(0, +)) ?? 0
        for channel in UInt32(0)...channelCount {
            for (selector, name) in [(kAudioDevicePropertyVolumeScalar, "scalar"), (kAudioDevicePropertyMute, "mute")] {
                var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: channel)
                guard AudioObjectHasProperty(output.id, &address) else { continue }
                if selector == kAudioDevicePropertyVolumeScalar {
                    var value: Float = 0, size = UInt32(MemoryLayout<Float>.size)
                    if AudioObjectGetPropertyData(output.id, &address, 0, nil, &size, &value) == noErr {
                        controls["\(channel).\(name)"] = Double(value)
                    }
                } else {
                    var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
                    if AudioObjectGetPropertyData(output.id, &address, 0, nil, &size, &value) == noErr {
                        controls["\(channel).\(name)"] = Double(value)
                    }
                }
            }
        }
        return ["available": true, "id": output.id, "uid": output.uid, "name": output.name,
                "sampleRate": output.sampleRate, "channels": channelCount, "controls": controls]
    }

    private static func hardwareUnchanged(_ before: [String: Any], _ after: [String: Any]) -> Bool {
        guard let aUID = before["uid"] as? String, let bUID = after["uid"] as? String, aUID == bUID,
              let aRate = before["sampleRate"] as? Double, let bRate = after["sampleRate"] as? Double, aRate == bRate,
              let a = before["controls"] as? [String: Double], let b = after["controls"] as? [String: Double], Set(a.keys) == Set(b.keys) else { return false }
        return a.allSatisfy { key, value in abs(value - (b[key] ?? -100)) < 0.00001 }
    }

    // Querying HAL properties neither opens an input stream nor records samples.
    // Missing controls are marked unsupported; failed reads remain incomplete.
    private static func inputHardwareSnapshot() -> [String: Any] {
        var defaultAddress = HAL.address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioObjectID(0), idSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(HAL.system, &defaultAddress, 0, nil, &idSize, &id)
        guard status == noErr else {
            return ["available": false, "complete": false, "status": "unavailable",
                    "reason": "default-input-query-failed", "readStatus": status]
        }
        guard id != 0 else {
            return ["available": false, "complete": true, "status": "unavailable", "reason": "no-default-input-device"]
        }
        var result: [String: Any] = ["available": true, "id": id, "scope": "input"]
        var failures: [String] = [], controls: [String: Double] = [:], unsupported: [String] = []
        if let uid = HAL.string(id, kAudioDevicePropertyDeviceUID) { result["uid"] = uid }
        else { failures.append("device UID unavailable") }
        result["name"] = HAL.string(id, kAudioObjectPropertyName) ?? "System input"
        var rateAddress = HAL.address(kAudioDevicePropertyNominalSampleRate)
        var rate: Double = 0, rateSize = UInt32(MemoryLayout<Double>.size)
        let rateStatus = AudioObjectGetPropertyData(id, &rateAddress, 0, nil, &rateSize, &rate)
        if rateStatus == noErr, rate.isFinite, rate > 0 { result["sampleRate"] = rate }
        else { failures.append("sample rate unavailable (\(rateStatus))") }
        var channelCount: UInt32 = 0
        do {
            channelCount = try HAL.buffers(id, scope: kAudioObjectPropertyScopeInput).reduce(0, +)
            result["channels"] = channelCount
        } catch { failures.append("input channel configuration: \(error.localizedDescription)") }
        for channel in UInt32(0)...channelCount {
            for (selector, name) in [(kAudioDevicePropertyVolumeScalar, "scalar"), (kAudioDevicePropertyMute, "mute")] {
                let key = "\(channel).\(name)"
                var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeInput, mElement: channel)
                guard AudioObjectHasProperty(id, &address) else { unsupported.append(key); continue }
                if selector == kAudioDevicePropertyVolumeScalar {
                    var value: Float = 0, size = UInt32(MemoryLayout<Float>.size)
                    let read = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
                    if read == noErr, value.isFinite { controls[key] = Double(value) }
                    else { failures.append("\(key) unavailable (\(read))") }
                } else {
                    var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
                    let read = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
                    if read == noErr { controls[key] = Double(value) }
                    else { failures.append("\(key) unavailable (\(read))") }
                }
            }
        }
        result["controls"] = controls
        result["unsupportedControls"] = unsupported.sorted()
        result["readFailures"] = failures
        result["complete"] = failures.isEmpty
        return result
    }

    private static func inputHardwareUnchanged(_ before: [String: Any], _ after: [String: Any]) -> Bool {
        guard hardwareUnchanged(before, after),
              let aChannels = before["channels"] as? UInt32, let bChannels = after["channels"] as? UInt32, aChannels == bChannels,
              let aUnsupported = before["unsupportedControls"] as? [String],
              let bUnsupported = after["unsupportedControls"] as? [String], aUnsupported == bUnsupported else { return false }
        return true
    }

    // Pure comparison is also exercised without opening or querying any device.
    static func compareInputHardware(before: [String: Any], during: [String: Any], after: [String: Any])
        -> (status: String, verified: Bool, reason: String?, failure: String?) {
        let inputs = [before, during, after]
        if inputs.allSatisfy({ $0["available"] as? Bool == false && $0["reason"] as? String == "no-default-input-device" }) {
            return ("unavailable", false, "No default input device was available; input-control preservation was not evaluated.", nil)
        }
        guard inputs.allSatisfy({ $0["available"] as? Bool == true && $0["complete"] as? Bool == true }) else {
            return ("unavailable", false, "A default input snapshot was unavailable or a supported property could not be read.",
                    "Default input or supported input controls could not be read completely; input setting preservation cannot be verified")
        }
        guard inputHardwareUnchanged(before, during), inputHardwareUnchanged(before, after) else {
            return ("changed", false, "Default input identity, sample rate, channel configuration, or supported input controls changed.",
                    "Default input, sample rate or input volume/mute controls changed; inspect inputHardware snapshots")
        }
        return ("unchanged", true, nil, nil)
    }
}

private final class ResultBox<T> {
    private let lock = NSLock()
    private var value: T?
    func set(_ value: T) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class FixtureSources {
    static let aID = "local.volume-verification.a"
    static let bID = "local.volume-verification.b"
    var outputID: AudioObjectID = 0
    private let lock = NSLock()
    private var pids: [String: pid_t] = [:]
    func setPID(_ pid: pid_t?, for id: String) {
        lock.lock(); pids[id] = pid; lock.unlock()
    }
    func scan() -> [AudioSource] {
        lock.lock(); let current = pids; lock.unlock()
        let all = HAL.ids(HAL.system, kAudioHardwarePropertyProcessObjectList)
        return [Self.aID, Self.bID].map { id in
            let objects = all.filter { HAL.value($0, kAudioProcessPropertyPID, default: pid_t(0)) == current[id] }
            let running = objects.contains {
                HAL.value($0, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0 &&
                HAL.ids($0, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput).contains(outputID)
            }
            return AudioSource(id: id, name: id == Self.aID ? "Test A" : "Test B", bundleURL: nil, processes: objects.sorted(), running: running)
        }
    }
}
