import Foundation
import Darwin

struct AudioWorkerRequest: Codable {
    let id: UUID
    let operation: String
    var settings: [String: VolumeSetting]?
    var retry: Bool?
}

struct AudioWorkerReply: Codable {
    let id: UUID
    var error: String?
    var snapshot: EngineSnapshot?
    var levels: [String: Float]?
    var diagnostics: [String: EngineSessionDiagnostics]?
}

// The window process owns this proxy, never a HAL object. Only one request is
// admitted at a time; meter polls do not build a queue behind an audio call.
final class AudioEngine {
    private let queue = DispatchQueue(label: "io.github.HaomingLyu613.VolumeMixer.worker-client")
    private let executable: URL
    private let workerMode: String
    private let requestTimeout: TimeInterval
    private let enableTimeout: TimeInterval
    private let stopTimeout: TimeInterval
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var pending: (id: UUID, done: (Result<AudioWorkerReply, Error>) -> Void)?
    private var waitingRefresh: (settings: [String: VolumeSetting], retry: Bool, done: (EngineSnapshot) -> Void)?
    private var deadline: DispatchWorkItem?
    private var generation = UUID()
    private var blocked = false
    private var stopping = false
    private var counts: [String: Int] = [:]
    private var stopError: String?
    private var snapshot = EngineSnapshot(sources: [], outputName: "Detecting output device…", errors: [:], controlled: [])
    var failureHandler: ((String) -> Void)?

    init(executable: URL = Bundle.main.executableURL!, workerMode: String = "live",
         requestTimeout: TimeInterval = 8, enableTimeout: TimeInterval = 65, stopTimeout: TimeInterval = 0.8) {
        self.executable = executable; self.workerMode = workerMode
        self.requestTimeout = requestTimeout; self.enableTimeout = enableTimeout; self.stopTimeout = stopTimeout
    }

    var workerPID: pid_t? { queue.sync { process?.processIdentifier } }
    var requestStatistics: [String: Int] { queue.sync { counts } }
    var lastStopError: String? { queue.sync { stopError } }

    func enable(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            // An earlier read-only discovery must not hold the Enable button hostage.
            self.endWorker(reason: "New audio verification started")
            self.blocked = false
            self.send("enable", timeout: self.enableTimeout) { result in
                if case .failure(let error) = result, !self.blocked, !self.stopping {
                    self.fail(error.localizedDescription)
                }
                DispatchQueue.main.async { completion(result.map { _ in () }) }
            }
        }
    }

    func refresh(settings: [String: VolumeSetting], retry: Bool = false, completion: @escaping (EngineSnapshot) -> Void) {
        queue.async {
            if retry && self.blocked { self.blocked = false }
            guard !self.blocked, !self.stopping else {
                let value = self.snapshot
                DispatchQueue.main.async { completion(value) }
                return
            }
            guard self.pending == nil else {
                // A meter reply may still be in flight when a drag begins. Keep
                // one latest refresh rather than acknowledging unapplied settings.
                if let previous = self.waitingRefresh {
                    let value = self.snapshot
                    DispatchQueue.main.async { previous.done(value) }
                }
                self.waitingRefresh = (settings, retry, completion)
                return
            }
            self.send("refresh", settings: settings, retry: retry, timeout: self.requestTimeout) { result in
                if case .success(let reply) = result, let value = reply.snapshot {
                    self.snapshot = value
                    if value.errors.values.contains(where: { $0.contains("not fully released") }) {
                        self.fail("Audio channel cleanup failed. Audio worker stopped. Check original playback before retrying.")
                    }
                }
                let value = self.snapshot
                DispatchQueue.main.async { completion(value) }
            }
        }
    }

    func meters(completion: @escaping ([String: Float]) -> Void) {
        queue.async {
            guard self.process != nil, !self.blocked, !self.stopping, self.pending == nil else {
                DispatchQueue.main.async { completion([:]) }; return
            }
            self.send("meters", timeout: self.requestTimeout) { result in
                let value = (try? result.get().levels) ?? [:]
                DispatchQueue.main.async { completion(value) }
            }
        }
    }

    func diagnostics(completion: @escaping ([String: EngineSessionDiagnostics]) -> Void) {
        queue.async {
            guard self.process != nil, !self.blocked, !self.stopping, self.pending == nil else {
                DispatchQueue.main.async { completion([:]) }; return
            }
            self.send("diagnostics", timeout: self.requestTimeout) { result in
                let value = (try? result.get().diagnostics) ?? [:]
                DispatchQueue.main.async { completion(value) }
            }
        }
    }

    func disable(completion: (() -> Void)? = nil) {
        queue.async {
            self.stopping = true
            self.cancelPending("Audio operation canceled")
            guard self.process != nil else {
                self.stopping = false
                DispatchQueue.main.async { completion?() }; return
            }
            // If HAL is already blocked, this request cannot complete. Its deadline
            // kills only our child, without waiting on the blocked HAL thread.
            self.send("disable", timeout: self.stopTimeout) { result in
                if case .failure(let error) = result { self.stopError = error.localizedDescription }
                else { self.stopError = nil }
                self.endWorker(reason: "Audio adjustment stopped")
                self.stopping = false
                self.snapshot.controlled.removeAll()
                DispatchQueue.main.async { completion?() }
            }
        }
    }

    func shutdown() {
        // Closing stdin and terminating the owned child never calls into CoreAudio.
        queue.sync { stopping = true; endWorker(reason: "Application is quitting") }
    }

    private func startWorker() throws {
        guard process == nil else { return }
        let child = Process(), incoming = Pipe(), outgoing = Pipe()
        child.executableURL = executable
        child.arguments = ["--audio-worker", workerMode]
        child.standardInput = incoming; child.standardOutput = outgoing
        let descriptor = incoming.fileHandleForWriting.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("VolumeMixer-audio-worker-\(getpid()).log")
        // A single bounded log for diagnostics, with operation names and status only.
        try? Data().write(to: logURL)
        child.standardError = (try? FileHandle(forWritingTo: logURL)) ?? FileHandle.nullDevice
        let token = UUID(); generation = token
        let readDescriptor = outgoing.fileHandleForReading.fileDescriptor
        _ = fcntl(readDescriptor, F_SETFL, fcntl(readDescriptor, F_GETFL) | O_NONBLOCK)
        outgoing.fileHandleForReading.readabilityHandler = { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.generation == token else { return }
                // A pipe is a stream of short JSON frames. Read available bytes
                // once; waiting to fill a requested byte count deadlocks RPC.
                // Reading on this queue also keeps fd close/reuse serialized.
                var bytes = [UInt8](repeating: 0, count: 16_384)
                let count = bytes.withUnsafeMutableBytes { Darwin.read(readDescriptor, $0.baseAddress!, $0.count) }
                if count < 0 {
                    if errno != EAGAIN && errno != EINTR { self.fail("Audio worker connection interrupted") }
                    return
                }
                if count == 0 {
                    if !self.stopping { self.fail("Audio worker exited. Adjustment stopped. Check original playback before retrying.") }
                    return
                }
                self.buffer.append(contentsOf: bytes.prefix(count))
                guard self.buffer.count <= 2_000_000 else { self.fail("Audio worker returned invalid data"); return }
                while let newline = self.buffer.firstIndex(of: 10) {
                    let line = self.buffer.subdata(in: 0..<newline)
                    self.buffer.removeSubrange(0...newline)
                    guard let reply = try? JSONDecoder().decode(AudioWorkerReply.self, from: line) else {
                        self.fail("Audio worker communication failed"); return
                    }
                    guard self.pending?.id == reply.id else { continue }
                    let callback = self.pending?.done
                    self.pending = nil; self.deadline?.cancel(); self.deadline = nil
                    if let message = reply.error { callback?(.failure(AudioFailure(message: message))) }
                    else { callback?(.success(reply)) }
                    self.drainRefresh()
                }
            }
        }
        try child.run()
        process = child; input = incoming.fileHandleForWriting; output = outgoing.fileHandleForReading
    }

    private func send(_ operation: String, settings: [String: VolumeSetting]? = nil, retry: Bool? = nil,
                      timeout: TimeInterval, done: @escaping (Result<AudioWorkerReply, Error>) -> Void) {
        do {
            try startWorker()
            let request = AudioWorkerRequest(id: UUID(), operation: operation, settings: settings, retry: retry)
            let data = try JSONEncoder().encode(request) + Data([10])
            counts[operation, default: 0] += 1
            pending = (request.id, done)
            let timeoutWork = DispatchWorkItem { [weak self] in
                guard let self, self.pending?.id == request.id else { return }
                self.fail(operation == "enable"
                    ? "Audio verification timed out. Worker stopped. Allow system audio access and retry."
                    : "System audio interface did not respond. Worker stopped. Check original playback before retrying.")
            }
            deadline = timeoutWork
            queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            try input?.write(contentsOf: data)
        } catch {
            if pending != nil { fail(error.localizedDescription) }
            else { fail(error.localizedDescription); done(.failure(error)) }
        }
    }

    private func fail(_ message: String) {
        blocked = true
        snapshot.controlled.removeAll()
        snapshot.errors["output"] = message
        endWorker(reason: message)
        DispatchQueue.main.async { [weak self] in self?.failureHandler?(message) }
    }

    private func cancelPending(_ reason: String) {
        deadline?.cancel(); deadline = nil
        let callback = pending?.done; pending = nil
        callback?(.failure(AudioFailure(message: reason)))
    }

    private func drainRefresh() {
        guard pending == nil, !stopping, let waiting = waitingRefresh else { return }
        waitingRefresh = nil
        refresh(settings: waiting.settings, retry: waiting.retry, completion: waiting.done)
    }

    private func endWorker(reason: String) {
        generation = UUID()
        let child = process
        process = nil
        output?.readabilityHandler = nil
        try? input?.close(); input = nil
        try? output?.close(); output = nil
        buffer.removeAll()
        let waiting = waitingRefresh; waitingRefresh = nil
        // SIGKILL targets a Process we still own and that Foundation has not reaped.
        // It also covers a worker stuck in a Mach RPC during teardown.
        if let child, child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
        cancelPending(reason)
        if let waiting {
            let value = snapshot
            DispatchQueue.main.async { waiting.done(value) }
        }
    }
}

enum AudioWorkerServer {
    static func run(mode: String) -> Never {
        let parent = getppid()
        let engine = mode == "live" ? LocalAudioEngine() : nil
        let outputLock = NSLock()
        func reply(_ value: AudioWorkerReply) {
            guard let data = try? JSONEncoder().encode(value) else { return }
            outputLock.lock(); defer { outputLock.unlock() }
            FileHandle.standardOutput.write(data + Data([10]))
        }
        // If the UI is killed or its pipe closes, terminate even if HAL cleanup is
        // blocked. The worker cannot outlive its owner and keep intercepting sound.
        let parentWatch = DispatchSource.makeTimerSource(queue: .main)
        parentWatch.schedule(deadline: .now() + 0.5, repeating: 0.5)
        parentWatch.setEventHandler { if getppid() != parent { _exit(0) } }
        parentWatch.resume()
        DispatchQueue.global().async {
            while let line = readLine() {
                guard let data = line.data(using: .utf8), let request = try? JSONDecoder().decode(AudioWorkerRequest.self, from: data) else { _exit(2) }
                AudioTrace.event("request", request.operation)
                if mode == "crash" { _exit(3) }
                if mode == "hang-" + request.operation { continue }
                guard let engine else {
                    var value = AudioWorkerReply(id: request.id)
                    if request.operation == "refresh" {
                        value.snapshot = EngineSnapshot(sources: [AudioSource(id: "fixture", name: "Test App", bundleURL: nil, processes: [], running: false)], outputName: "Test Output \(request.settings?["fixture"]?.volume ?? 100)", errors: [:], controlled: [])
                    }
                    if request.operation == "meters" { value.levels = ["fixture": 0.25] }
                    if mode == "slow-refresh", request.operation == "refresh" {
                        let delayed = value
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { reply(delayed) }
                    } else { reply(value) }
                    continue
                }
                switch request.operation {
                case "enable":
                    engine.enable { result in
                        var value = AudioWorkerReply(id: request.id)
                        if case .failure(let error) = result { value.error = error.localizedDescription }
                        reply(value)
                    }
                case "disable":
                    engine.disable { errors in
                        var value = AudioWorkerReply(id: request.id)
                        if !errors.isEmpty { value.error = errors.values.joined(separator: "; ") }
                        reply(value)
                    }
                case "refresh":
                    engine.refresh(settings: request.settings ?? [:], retry: request.retry ?? false) {
                        reply(AudioWorkerReply(id: request.id, snapshot: $0))
                    }
                case "meters": engine.meters { reply(AudioWorkerReply(id: request.id, levels: $0)) }
                case "diagnostics": engine.diagnostics { reply(AudioWorkerReply(id: request.id, diagnostics: $0)) }
                default: reply(AudioWorkerReply(id: request.id, error: "Unknown audio operation"))
                }
            }
            _exit(0)
        }
        RunLoop.main.run()
        _exit(0)
    }
}

enum AudioTrace {
    private static let lock = NSLock()
    private static var bytes = 0
    static func event(_ phase: String, _ operation: String) {
        let line = "\(Date().timeIntervalSince1970) pid=\(getpid()) \(phase) \(operation)\n"
        lock.lock(); defer { lock.unlock() }
        bytes += line.utf8.count
        if bytes > 1_000_000 {
            // stderr is a file in the normal worker; a terminal/pipe simply keeps
            // its stream semantics when seeking is unsupported.
            if (try? FileHandle.standardError.seek(toOffset: 0)) != nil {
                try? FileHandle.standardError.truncate(atOffset: 0)
            }
            bytes = 0
        }
        FileHandle.standardError.write(Data(line.utf8))
    }
    static func call<T>(_ operation: String, _ body: () throws -> T) rethrows -> T {
        event("begin", operation)
        do {
            let value = try body()
            event("end", operation + ((value as? Int32).map { " status=\($0)" } ?? ""))
            return value
        } catch {
            event("failed", operation + " " + error.localizedDescription)
            throw error
        }
    }
}
