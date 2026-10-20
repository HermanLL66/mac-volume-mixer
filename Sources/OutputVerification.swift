import Foundation
import CoreAudio

// Optional downstream check. The observed samples come back through a separate
// HAL tap of this process, rather than from the producer's output buffer meter.
// A system that cannot capture its own process produces "verified": false.
enum OutputVerification {
    static func run(reportURL: URL) {
        // Invoke from a worker queue; AppKit's normal main run loop stays free.
        perform(reportURL: reportURL)
    }

    private static func perform(reportURL: URL) {
        let began = ProcessInfo.processInfo.systemUptime
        let cleanup = OutputCleanupLog()
        let originalTaps = Set(HAL.ids(HAL.system, kAudioHardwarePropertyTapList))
        var report: [String: Any] = [
            "verified": false, "audioSaved": false, "systemVolumeModified": false,
            "acousticSpeakerLoudnessVerified": false,
            "measurement": "Independent unmuted HAL process-mixdown capture of mixer replay, compared with native helper playback captured by the same process-mixdown method before control. This is not an acoustic speaker measurement.",
            "gainStageNote": "A muted source tap can expose a different gain stage from native unmuted playback. Raw control-input ratios are retained as diagnostics; user-relative gain uses the same-method native baseline. No gain compensation is applied."
        ]
        var child: Process?
        var control: TapSession?
        var sourceCapture: OutputCaptureMonitor?
        var replayCapture: OutputCaptureMonitor?
        var checks: [String] = []
        do {
            let output = try HAL.defaultOutput()
            report["outputUID"] = output.uid
            report["sampleRate"] = output.sampleRate
            let probe = Process()
            probe.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AudioProbe")
            probe.arguments = ["18", "0.0004", "997", "continuous"]
            probe.standardOutput = FileHandle.nullDevice
            probe.standardError = FileHandle.nullDevice
            try probe.run()
            child = probe
            let helperObjects = try waitForProcesses(pid: probe.processIdentifier, timeout: 2)
            report["helperProcessObjects"] = helperObjects
            let baselineMonitor = try OutputCaptureMonitor(processes: helperObjects, label: "helper", cleanup: cleanup)
            sourceCapture = baselineMonitor
            _ = try awaitSignal(baselineMonitor, timeout: 2, reason: "Independent tap-only capture of the helper returned no valid signal")
            let nativePeaks = try stablePeaks(baselineMonitor)
            let originalPeak = (nativePeaks[0] + nativePeaks[1]) * 0.5
            report["originalHelperMixdownBaselineSamples"] = nativePeaks
            report["originalHelperMixdownPeak"] = originalPeak
            guard abs(nativePeaks[0] / nativePeaks[1] - 1) < 0.03 else {
                throw AudioFailure(message: "Two independent native-playback captures were unstable; no reliable gain baseline was established")
            }
            report["nativeBaselineStable"] = true
            checks.append("Independent unmuted source tap captured two stable native-playback baseline intervals")

            let session = try TapSession(processes: helperObjects, output: output, gain: 1)
            control = session
            let readyDeadline = ProcessInfo.processInfo.systemUptime + 2
            var inputPeak: Float = 0
            while ProcessInfo.processInfo.systemUptime < readyDeadline {
                inputPeak = max(inputPeak, session.takePeak())
                if session.validCallbacks >= 3, inputPeak > 0.0000001 { break }
                Thread.sleep(forTimeInterval: 0.03)
            }
            guard session.validCallbacks >= 3, inputPeak > 0.0000001 else {
                throw AudioFailure(message: "Processing channel was not ready; native playback was retained and output verification is incomplete")
            }
            report["preparedInputPeak"] = inputPeak
            try session.activateProcessing()
            let ownObjects = try waitForProcesses(pid: getpid(), timeout: 1)
            report["replayProcessObjects"] = ownObjects
            // Process-wide mixdown includes replay to the private aggregate. A
            // physical-device-scoped tap can otherwise miss that render path.
            let downstream = try OutputCaptureMonitor(processes: ownObjects, label: "replay", cleanup: cleanup)
            replayCapture = downstream
            _ = try awaitSignal(downstream, timeout: 2,
                                reason: "HAL did not return this process replay signal (self-process or tap-only capture may be unsupported); actual output gain cannot be verified")

            func measure(_ gain: Float) throws -> [String: Any] {
                session.setGain(gain)
                Thread.sleep(forTimeInterval: 0.18)
                _ = session.takePeak(); _ = session.takeOutputPeak()
                _ = downstream.takePeak(); _ = baselineMonitor.takePeak()
                let beforeCount = downstream.callbacks
                Thread.sleep(forTimeInterval: 0.4)
                let source = session.takePeak()
                let emitted = session.takeOutputPeak()
                let observed = downstream.takePeak()
                let independentSource = baselineMonitor.takePeak()
                let received = downstream.callbacks - beforeCount
                guard source > 0.0000001 else { throw AudioFailure(message: "Helper signal stopped during verification") }
                guard received > 0 else {
                    throw AudioFailure(message: "No downstream capture callbacks at gain \(gain); missing data cannot establish verified mute")
                }
                return ["requestedGain": gain, "tapInputPeak": source, "producerOutputPeak": emitted,
                        "downstreamPeak": observed, "sourceMixdownPeak": independentSource,
                        "downstreamToInputRatio": observed / source,
                        "downstreamToOriginalMixdownRatio": observed / originalPeak,
                        "activeSourceMixdownToNativeBaselineRatio": independentSource / originalPeak,
                        "downstreamCallbacks": received]
            }
            let unity = try measure(1)
            let quarter = try measure(0.25)
            let muted = try measure(0)
            report["gainOne"] = unity
            report["gainQuarter"] = quarter
            report["gainZero"] = muted
            guard let unityRatio = unity["downstreamToOriginalMixdownRatio"] as? Float, abs(unityRatio - 1) < 0.075 else {
                throw AudioFailure(message: "Downstream HAL signal at 100% did not match the same-method native baseline; inspect gainOne")
            }
            guard let quarterRatio = quarter["downstreamToOriginalMixdownRatio"] as? Float, abs(quarterRatio - 0.25) < 0.025 else {
                throw AudioFailure(message: "Downstream HAL signal did not reach 25% of the native baseline")
            }
            guard let mutedPeak = muted["downstreamPeak"] as? Float, mutedPeak < originalPeak * 0.001 else {
                throw AudioFailure(message: "Muted downstream HAL signal exceeded the permitted noise threshold")
            }
            checks += ["Downstream HAL signal matches the same-method native-playback baseline at 100%", "Downstream HAL signal is 25% of the native baseline at quarter gain", "Downstream HAL capture continues and returns silence at zero gain"]

            let controlErrors = session.stop()
            report["controlStopErrors"] = controlErrors
            report["controlObjectsReleased"] = session.tap == 0 && session.aggregate == 0
            guard controlErrors.isEmpty, session.tap == 0, session.aggregate == 0 else {
                throw AudioFailure(message: "Control tap was not fully released; original playback restoration cannot be confirmed")
            }
            // Allow any buffers from the muted source's former gain stage to
            // drain before comparing two new native-playback capture intervals.
            Thread.sleep(forTimeInterval: 0.2)
            _ = downstream.takePeak()
            let restoredPeaks = try stablePeaks(baselineMonitor)
            let restoredPeak = (restoredPeaks[0] + restoredPeaks[1]) * 0.5
            report["helperMixdownPeakAfterRestore"] = restoredPeak
            report["helperMixdownRestoredSamples"] = restoredPeaks
            report["replayPeakAfterRestore"] = downstream.takePeak()
            let restored = restoredPeaks.allSatisfy { abs($0 / originalPeak - 1) < 0.075 } && abs(restoredPeaks[0] / restoredPeaks[1] - 1) < 0.03
            report["sourceCaptureAfterRestoreMatchesBaseline"] = restored
            guard restored else {
                throw AudioFailure(message: "Independent helper signal did not return to its baseline after releasing control")
            }
            report["restorationEvidence"] = "Control tap successfully unmuted/destroyed; independent helper capture retains its original level. This does not acoustically measure native playback."
            checks.append("Control objects released and helper source capture retains its baseline")
            report["verified"] = true
        } catch { report["reason"] = error.localizedDescription }

        if let control {
            let errors = control.stop()
            report["finalControlStopErrors"] = errors
            if !errors.isEmpty || control.tap != 0 || control.aggregate != 0 {
                report["verified"] = false
                report["reason"] = "Control-channel cleanup failed: " + errors.joined(separator: "; ")
            }
        }
        replayCapture?.stop()
        sourceCapture?.stop()
        if let child, child.isRunning {
            child.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while child.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        report["cleanupOperations"] = cleanup.operations
        let remainingTaps = Set(HAL.ids(HAL.system, kAudioHardwarePropertyTapList)).subtracting(originalTaps)
        report["remainingNewTapObjects"] = remainingTaps.sorted()
        if !remainingTaps.isEmpty {
            report["verified"] = false
            report["reason"] = "New tap objects remained after verification; cleanup is incomplete"
        }
        if cleanup.hasUnreleasedObjects {
            report["verified"] = false
            report["reason"] = "Independent capture channel was not fully released"
        }
        report["checks"] = checks
        report["durationSeconds"] = ProcessInfo.processInfo.systemUptime - began
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: reportURL, options: .atomic)
        } catch { fputs("Cannot write output verification report: \(error)\n", stderr) }
    }

    private static func waitForProcesses(pid: pid_t, timeout: TimeInterval) throws -> [AudioObjectID] {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            let objects = HAL.ids(HAL.system, kAudioHardwarePropertyProcessObjectList).filter {
                HAL.value($0, kAudioProcessPropertyPID, default: pid_t(0)) == pid
            }
            if !objects.isEmpty { return objects.sorted() }
            Thread.sleep(forTimeInterval: 0.03)
        }
        throw AudioFailure(message: "Could not discover verification audio process \(pid)")
    }

    private static func awaitSignal(_ monitor: OutputCaptureMonitor, timeout: TimeInterval, reason: String) throws -> Float {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            let peak = monitor.takePeak()
            if monitor.callbacks >= 3, peak > 0.0000001 { return peak }
            Thread.sleep(forTimeInterval: 0.03)
        }
        throw AudioFailure(message: reason)
    }

    private static func stablePeaks(_ monitor: OutputCaptureMonitor) throws -> [Float] {
        var peaks: [Float] = []
        for _ in 0..<2 {
            _ = monitor.takePeak()
            let beforeCount = monitor.callbacks
            Thread.sleep(forTimeInterval: 0.3)
            let peak = monitor.takePeak()
            guard monitor.callbacks > beforeCount, peak > 0.0000001 else {
                throw AudioFailure(message: "Native baseline capture stopped; missing or silent samples cannot serve as a reference")
            }
            peaks.append(peak)
        }
        return peaks
    }
}

final class OutputCleanupLog {
    var operations: [[String: Any]] = []
    var unreleased: Set<String> = []
    var hasUnreleasedObjects: Bool { !unreleased.isEmpty }
    func record(_ label: String, _ operation: String, _ status: OSStatus) {
        operations.append(["monitor": label, "operation": operation, "status": status])
    }
}

// Input-only aggregates have no physical device and cannot render or change any
// hardware volume. Their only task here is to meter an unmuted process tap.
final class OutputCaptureMonitor {
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var state: OpaquePointer?
    private var started = false
    private let label: String
    private let cleanup: OutputCleanupLog

    init(processes: [AudioObjectID], label: String, cleanup: OutputCleanupLog) throws {
        self.label = label
        self.cleanup = cleanup
        do {
            let description = CATapDescription(stereoMixdownOfProcesses: processes)
            description.name = "Volume Mixer · Output verification · \(label)"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try HAL.check(AudioHardwareCreateProcessTap(description, &tap), "Create independent output-monitor tap")
            let format = HAL.value(tap, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
            guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
                throw AudioFailure(message: "Independent output capture did not provide Float32 PCM")
            }
            let spec: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Volume Mixer · Read-only output verification",
                kAudioAggregateDeviceUIDKey: "local.volume-output-verification.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
            ]
            try HAL.check(AudioHardwareCreateAggregateDevice(spec as CFDictionary, &aggregate), "Create read-only tap aggregate")
            let inputs = try HAL.buffers(aggregate, scope: kAudioObjectPropertyScopeInput)
            guard !inputs.isEmpty, inputs.reduce(0, +) > 0, inputs.reduce(0, +) <= 2 else {
                throw AudioFailure(message: "Read-only tap aggregate provided no usable stereo input")
            }
            state = MixerDSPCreate(0, 0, UInt32(inputs.count), false)
            guard let state else { throw AudioFailure(message: "Could not allocate read-only output meter") }
            try HAL.check(AudioDeviceCreateIOProcID(aggregate, MixerIOProc, UnsafeMutableRawPointer(state), &ioProc), "Create read-only output-monitor callback")
            guard let ioProc else { throw AudioFailure(message: "Read-only output-monitor callback was missing") }
            try HAL.check(AudioDeviceStart(aggregate, ioProc), "Start read-only output monitor")
            started = true
        } catch { stop(); throw error }
    }

    func takePeak() -> Float { state.map(MixerDSPTakePeak) ?? 0 }
    var callbacks: UInt64 { state.map(MixerDSPCallbackCount) ?? 0 }

    func stop() {
        if aggregate != 0, let ioProc {
            if started {
                let status = AudioDeviceStop(aggregate, ioProc)
                cleanup.record(label, "AudioDeviceStop", status)
                if status == noErr { started = false }
            }
            let status = AudioDeviceDestroyIOProcID(aggregate, ioProc)
            cleanup.record(label, "AudioDeviceDestroyIOProcID", status)
            if status == noErr { self.ioProc = nil; started = false }
        }
        if aggregate != 0 {
            let status = AudioHardwareDestroyAggregateDevice(aggregate)
            cleanup.record(label, "AudioHardwareDestroyAggregateDevice", status)
            if status == noErr { aggregate = 0; ioProc = nil; started = false }
        }
        if tap != 0 {
            let status = AudioHardwareDestroyProcessTap(tap)
            cleanup.record(label, "AudioHardwareDestroyProcessTap", status)
            if status == noErr { tap = 0 }
        }
        if ioProc == nil, let state { MixerDSPDestroy(state); self.state = nil }
        if tap == 0, aggregate == 0, ioProc == nil { cleanup.unreleased.remove(label) }
        else { cleanup.unreleased.insert(label) }
    }
    deinit { stop() }
}
