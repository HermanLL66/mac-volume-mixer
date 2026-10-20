import AppKit
import CoreAudio

struct VolumeSetting: Codable, Equatable {
    var volume: Double = 100
    var muted: Bool = false
    var name: String = ""
    var gain: Float { muted ? 0 : Float(min(100, max(0, volume)) / 100) }
}

struct EngineSnapshot: Codable {
    var sources: [AudioSource]
    var outputName: String
    var errors: [String: String]
    var controlled: Set<String>
}

struct EngineSessionDiagnostics: Codable {
    let tapID: AudioObjectID
    let aggregateID: AudioObjectID
    var callbacks: UInt64
    var validCallbacks: UInt64
    var invalidBuffers: UInt64
    var consecutiveInvalidBuffers: UInt64
    var processingActive: Bool
    var inputPeak: Float
    var outputPeak: Float
    var processes: [AudioObjectID]
}

final class LocalAudioEngine {
    private struct SessionHealth {
        var lastValid: UInt64 = 0
        var progressAt: TimeInterval
        var activeSince: TimeInterval?
        var invalidSince: TimeInterval?
    }
    private struct RetryState {
        var processes: [AudioObjectID]
        var failures: Int = 0
        var nextAttempt: TimeInterval = 0
    }
    private let queue = DispatchQueue(label: "io.github.HaomingLyu613.VolumeMixer.engine", qos: .userInitiated)
    private let sourceProvider: () -> [AudioSource]
    private let outputProvider: () throws -> OutputDevice
    private var sessions: [String: TapSession] = [:]
    // Keep ownership if HAL could not release a callback or tap. A later stop retries it.
    private var retiredSessions: [String: TapSession] = [:]
    private var errors: [String: String] = [:]
    private var settings: [String: VolumeSetting] = [:]
    private var sources: [AudioSource] = []
    private var output: OutputDevice?
    private var enabled = false
    private var health: [String: SessionHealth] = [:]
    private var retries: [String: RetryState] = [:]

    init(sourceProvider: @escaping () -> [AudioSource] = SourceDiscovery.scan,
         outputProvider: @escaping () throws -> OutputDevice = HAL.defaultOutput) {
        self.sourceProvider = sourceProvider
        self.outputProvider = outputProvider
    }

    func enable(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            do {
                self.retryRetiredSessions()
                guard self.retiredSessions.isEmpty else {
                    throw AudioFailure(message: "A previous audio channel could not be released. Quit the app and retry.")
                }
                try self.verifyCapture()
                self.enabled = true
                self.errors.removeAll()
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                self.enabled = false
                self.stopAll()
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
    func disable(completion: (([String: String]) -> Void)? = nil) {
        queue.async {
            self.enabled = false
            self.errors.removeAll()
            self.stopAll()
            let failures = self.errors
            DispatchQueue.main.async { completion?(failures) }
        }
    }
    func shutdown() { queue.sync { enabled = false; stopAll() } }

    func refresh(settings: [String: VolumeSetting], retry: Bool = false, completion: @escaping (EngineSnapshot) -> Void) {
        queue.async {
            self.settings = settings
            if retry {
                self.errors.removeAll()
                self.retries.removeAll()
                self.retryRetiredSessions()
            }
            self.sources = AudioTrace.call("discoverSources") { self.sourceProvider() }
            do {
                let output = try AudioTrace.call("defaultOutput") { try self.outputProvider() }
                if output != self.output {
                    self.errors.removeAll()
                    self.retries.removeAll()
                    self.stopAll()
                    self.output = output
                }
                if self.enabled { self.reconcile(output: output) }
            } catch {
                self.stopAll()
                self.output = nil
                self.errors["output"] = error.localizedDescription
            }
            let snapshot = EngineSnapshot(sources: self.sources, outputName: self.output?.name ?? "No output device connected",
                                          errors: self.errors, controlled: Set(self.sessions.compactMap { $0.value.processingActive ? $0.key : nil }))
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    func meters(completion: @escaping ([String: Float]) -> Void) {
        queue.async {
            let levels = self.sessions.mapValues { $0.takePeak() }
            DispatchQueue.main.async { completion(levels) }
        }
    }
    // Consumes interval peaks, like meters(). Used by the sustained real-audio check.
    func diagnostics(completion: @escaping ([String: EngineSessionDiagnostics]) -> Void) {
        queue.async {
            let values = self.sessions.mapValues {
                EngineSessionDiagnostics(tapID: $0.tap, aggregateID: $0.aggregate,
                                         callbacks: $0.callbacks, validCallbacks: $0.validCallbacks,
                                         invalidBuffers: $0.invalidBuffers, consecutiveInvalidBuffers: $0.consecutiveInvalidBuffers,
                                         processingActive: $0.processingActive, inputPeak: $0.takePeak(),
                                         outputPeak: $0.takeOutputPeak(), processes: $0.processes)
            }
            DispatchQueue.main.async { completion(values) }
        }
    }
    private func retryRetiredSessions() {
        for id in Array(retiredSessions.keys) {
            guard let session = retiredSessions[id] else { continue }
            let failures = session.stop()
            if failures.isEmpty {
                retiredSessions.removeValue(forKey: id)
                errors.removeValue(forKey: id)
            } else {
                errors[id] = "Audio channel not fully released: " + failures.joined(separator: "; ")
            }
        }
    }
    private func stopSession(_ id: String) {
        health.removeValue(forKey: id)
        guard let session = sessions.removeValue(forKey: id) else { return }
        let failures = session.stop()
        if !failures.isEmpty {
            retiredSessions[id] = session
            errors[id] = "Audio channel not fully released: " + failures.joined(separator: "; ")
        }
    }
    private func stopAll() {
        retryRetiredSessions()
        for id in Array(sessions.keys) { stopSession(id) }
        health.removeAll()
        retries.removeAll()
    }
    private func reconcile(output: OutputDevice) {
        let now = ProcessInfo.processInfo.systemUptime
        // Idle Chrome helpers may have no output device at all. Including them
        // in a macOS 14 process tap can yield zero input even while another helper
        // plays. Wait until a process actually has this output before including it.
        let scoped = sources.map { source -> AudioSource in
            var value = source
            value.processes = Array(Set(source.processes.filter {
                let devices = HAL.ids($0, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
                return devices.contains(output.id)
            })).sorted()
            value.running = source.running && value.processes.contains {
                HAL.value($0, kAudioProcessPropertyIsRunningOutput, default: UInt32.max) != 0
            }
            return value
        }
        let wanted = Set(scoped.filter { (settings[$0.id] ?? VolumeSetting()).gain != 1 && !$0.processes.isEmpty }.map(\.id))
        for id in Array(sessions.keys) where !wanted.contains(id) { stopSession(id) }
        for id in Array(retries.keys) where !wanted.contains(id) {
            retries.removeValue(forKey: id)
            if retiredSessions[id] == nil { errors.removeValue(forKey: id) }
        }
        for source in scoped where wanted.contains(source.id) {
            guard retiredSessions[source.id] == nil else { continue }
            let setting = settings[source.id] ?? VolumeSetting()
            if let previous = retries[source.id], previous.processes != source.processes {
                retries.removeValue(forKey: source.id)
                errors.removeValue(forKey: source.id)
            }
            if sessions[source.id] == nil {
                if let retry = retries[source.id], !source.running || now < retry.nextAttempt { continue }
                do {
                    sessions[source.id] = try TapSession(processes: source.processes, output: output, gain: setting.gain)
                    health[source.id] = SessionHealth(progressAt: now)
                } catch {
                    recordFailure(source, message: error.localizedDescription, now: now)
                    continue
                }
            }
            guard let session = sessions[source.id] else { continue }
            if session.processes != source.processes {
                do {
                    // Chrome replaces helpers during playback. Keep the same output
                    // connection and change tap membership without a direct-audio gap.
                    try session.updateProcesses(source.processes)
                    health[source.id] = SessionHealth(lastValid: session.validCallbacks, progressAt: now)
                } catch {
                    recordFailure(source, message: error.localizedDescription, now: now)
                    continue
                }
            }
            session.setGain(setting.gain)
            var status = health[source.id] ?? SessionHealth(progressAt: now)
            let valid = session.validCallbacks
            let progressed = valid != status.lastValid
            if progressed { status.lastValid = valid; status.progressAt = now; status.invalidSince = nil }
            guard source.running else {
                // Auto-start waits for the source's first audio; pause/resume is also
                // ordinary application behavior, not a broken connection.
                status.activeSince = nil; status.invalidSince = nil; status.progressAt = now
                health[source.id] = status
                continue
            }
            if status.activeSince == nil { status.activeSince = now; status.progressAt = now }
            if !session.processingActive, valid >= 3, session.hasReceivedSignal {
                do {
                    try session.activateProcessing()
                    errors.removeValue(forKey: source.id)
                } catch {
                    recordFailure(source, message: error.localizedDescription, now: now)
                    continue
                }
            }
            // Brief startup/reconfiguration mismatches must not poison a lifetime
            // counter. Require an active source and a sustained lack of valid IO.
            if !progressed, session.consecutiveInvalidBuffers > 8 {
                if status.invalidSince == nil { status.invalidSince = now }
            } else { status.invalidSince = nil }
            let activeFor = now - (status.activeSince ?? now)
            let stalled = activeFor >= 5 && now - status.progressAt >= 5
            let invalid = activeFor >= 5 && status.invalidSince.map { now - $0 >= 1 } == true
            if stalled || invalid {
                let reason = invalid ? "Repeated invalid audio buffers" : "No valid audio received during playback"
                recordFailure(source, message: reason + ". Original playback restored. Retry scheduled; you can also click Retry.", now: now)
                continue
            }
            health[source.id] = status
        }
    }

    private func recordFailure(_ source: AudioSource, message: String, now: TimeInterval) {
        stopSession(source.id)
        guard retiredSessions[source.id] == nil else { return }
        var retry = retries[source.id] ?? RetryState(processes: source.processes)
        retry.failures += 1
        // Three automatic retries for one topology; a changed process set, output
        // device, or explicit retry resets the budget.
        retry.nextAttempt = retry.failures <= 3 ? now + pow(2, Double(retry.failures - 1)) : .infinity
        retries[source.id] = retry
        errors[source.id] = retry.failures <= 3 ? message : message + " Automatic retries failed. Click Retry."
    }

    // Verify an unmuted, very quiet test source before any real app is intercepted.
    // A denied audio permission can otherwise return zero-filled buffers with no OSStatus error.
    private func verifyCapture() throws {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AudioProbe")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw AudioFailure(message: "Audio verification helper missing. Run build.sh again.") }
        let probe = Process()
        probe.executableURL = executable
        probe.arguments = ["25", "0.0003"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try probe.run()
        defer { if probe.isRunning { probe.terminate() } }
        var object: AudioObjectID?
        for _ in 0..<40 {
            object = HAL.ids(HAL.system, kAudioHardwarePropertyProcessObjectList).first {
                HAL.value($0, kAudioProcessPropertyPID, default: pid_t(0)) == probe.processIdentifier
            }
            if object != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let object else { throw AudioFailure(message: "Verification signal not detected. Check the output device and retry.") }
        let session = try TapSession(processes: [object], output: outputProvider(), gain: 0, playback: false)
        var received = false
        for _ in 0..<220 {
            if session.takePeak() > 0.0000001, session.validCallbacks >= 3 { received = true; break }
            guard probe.isRunning else { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let cleanup = session.stop()
        guard cleanup.isEmpty else {
            retiredSessions["permission-check"] = session
            throw AudioFailure(message: "Verification audio channel not fully released: " + cleanup.joined(separator: "; "))
        }
        if received { return }
        throw AudioFailure(message: "No application audio received. Allow Volume Mixer in System Settings > Privacy & Security > Screen & System Audio Recording (Screen Recording on some versions), then retry.")
    }
}
