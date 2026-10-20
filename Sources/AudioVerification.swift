import Foundation
import CoreAudio

enum AudioVerification {
    static func run(reportURL: URL) {
        var report: [String: Any] = ["passed": false, "checks": [String](), "audioSaved": false]
        let before = HAL.value(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))
        var children: [Process] = []
        var sessions: [TapSession] = []
        do {
            let output = try HAL.defaultOutput()
            report["output"] = output.name
            report["sampleRate"] = output.sampleRate
            for amplitude in ["0.0004", "0.0007"] {
                let child = Process()
                child.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AudioProbe")
                child.arguments = ["45", amplitude]
                child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
                try child.run(); children.append(child)
            }
            var objects: [AudioObjectID] = []
            for _ in 0..<60 {
                let processes = HAL.ids(HAL.system, kAudioHardwarePropertyProcessObjectList)
                objects = children.compactMap { child in processes.first { HAL.value($0, kAudioProcessPropertyPID, default: pid_t(0)) == child.processIdentifier } }
                if objects.count == 2 { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard objects.count == 2 else { throw AudioFailure(message: "Could not discover both test audio processes") }
            let monitor = try TapSession(processes: [objects[0]], output: output, gain: 0, playback: false)
            sessions.append(monitor)
            var authorized = false
            for _ in 0..<250 {
                if monitor.takePeak() > 0.0000001 { authorized = true; break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard authorized else { throw AudioFailure(message: "System audio verification failed: captured test signal was zero; no real application was intercepted") }
            monitor.stop(); sessions.removeAll()
            let a = try TapSession(processes: [objects[0]], output: output, gain: 0.25)
            sessions.append(a)
            let b = try TapSession(processes: [objects[1]], output: output, gain: 0.75)
            sessions.append(b)
            for _ in 0..<50 {
                if a.validCallbacks >= 3, b.validCallbacks >= 3 { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            try a.activateProcessing()
            try b.activateProcessing()
            Thread.sleep(forTimeInterval: 0.5)
            _ = a.takePeak(); _ = a.takeOutputPeak(); _ = b.takePeak(); _ = b.takeOutputPeak()
            Thread.sleep(forTimeInterval: 0.25)
            let aInput = a.takePeak(), aOutput = a.takeOutputPeak(), bInput = b.takePeak(), bOutput = b.takeOutputPeak()
            guard aInput > 0.0000001, bInput > 0.0000001 else { throw AudioFailure(message: "Independent processing channels received no test signal") }
            let aRatio = aOutput / aInput, bRatio = bOutput / bInput
            report["appAEmittedGain"] = aRatio; report["appBEmittedGain"] = bRatio
            guard abs(aRatio - 0.25) < 0.01, abs(bRatio - 0.75) < 0.01 else { throw AudioFailure(message: "Emitted buffer gain does not match the requested setting") }
            a.setGain(0)
            Thread.sleep(forTimeInterval: 0.2)
            _ = a.takeOutputPeak(); _ = b.takeOutputPeak(); _ = b.takePeak()
            Thread.sleep(forTimeInterval: 0.2)
            let mutedPeak = a.takeOutputPeak(), stillPlayingPeak = b.takeOutputPeak(), stillPlayingInput = b.takePeak()
            report["mutedAOutputPeak"] = mutedPeak
            report["appBGainWhileAMuted"] = stillPlayingInput > 0 ? stillPlayingPeak / stillPlayingInput : -1
            guard mutedPeak == 0, stillPlayingInput > 0, abs(stillPlayingPeak / stillPlayingInput - 0.75) < 0.01 else {
                throw AudioFailure(message: "Muting one process affected another test process")
            }
            report["callbacksA"] = a.callbacks; report["callbacksB"] = b.callbacks
            guard a.invalidBuffers == 0, b.invalidBuffers == 0 else { throw AudioFailure(message: "Invalid real-time audio buffer layout") }
            sessions.forEach { $0.stop() }; sessions.removeAll()
            let after = HAL.value(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))
            guard before == after else { throw AudioFailure(message: "System default output device changed") }
            report["checks"] = ["Nonzero audio captured with system permission", "Two actual audio processes routed independently", "App A emits 25% while B emits 75%", "Muting A leaves B at 75%", "No malformed audio buffers", "Taps destroyed and default output preserved"]
            report["passed"] = true
        } catch { report["error"] = error.localizedDescription }
        sessions.forEach { $0.stop() }
        children.filter(\.isRunning).forEach { $0.terminate() }
        report["defaultOutputPreserved"] = before == HAL.value(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: reportURL, options: .atomic)
        } catch { fputs("Cannot write verification report: \(error)\n", stderr) }
    }
}
