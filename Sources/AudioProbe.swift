import AVFoundation
import Foundation
import Darwin

// A separate, temporary process provides a known signal for the first-run check.
// Start this before AVAudioEngine construction: even initialization/stop may get
// stuck in a HAL RPC, so the main thread cannot own this helper's lifetime.
let launchedBy = getppid()
if launchedBy <= 1 { _exit(0) }
let watchdogFixture = CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--watchdog-fixture"
let requestedDuration = watchdogFixture
    ? (CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 25 : 25)
    : (CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 25 : 25)
let duration = requestedDuration.isFinite ? min(60, max(0.1, requestedDuration)) : 25
let playbackDeadline = ProcessInfo.processInfo.systemUptime + duration
let hardDeadline = Date().timeIntervalSince1970 + duration + 2
let watchdogQueue = DispatchQueue.global(qos: .userInteractive)
let parentWatch = DispatchSource.makeTimerSource(queue: watchdogQueue)
parentWatch.schedule(wallDeadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
parentWatch.setEventHandler {
    if getppid() != launchedBy { _exit(0) }
    if Date().timeIntervalSince1970 >= hardDeadline { _exit(124) }
}
parentWatch.resume()
// A separate one-shot deadline also covers a delayed periodic timer delivery.
watchdogQueue.asyncAfter(wallDeadline: .now() + duration + 2) { _exit(124) }
if watchdogFixture {
    fputs("watchdog-ready\n", stdout)
    fflush(stdout)
    while true { pause() }
}

let requestedAmplitude = CommandLine.arguments.count > 2 ? Float(CommandLine.arguments[2]) ?? 0.0003 : 0.0003
let amplitude: Float = requestedAmplitude.isFinite ? min(0.001, max(0, requestedAmplitude)) : 0.0003
let frequency = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? 997 : 997
let profile = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : "continuous"
let engine = AVAudioEngine()
let format = engine.outputNode.inputFormat(forBus: 0)
var phase: Double = 0
let step = 2 * Double.pi * min(18000, max(20, frequency)) / format.sampleRate
let source = AVAudioSourceNode(format: format) { _, _, frameCount, list -> OSStatus in
    let buffers = UnsafeMutableAudioBufferListPointer(list)
    for frame in 0..<Int(frameCount) {
        let value = Float(sin(phase)) * amplitude
        phase += step
        if phase >= 2 * Double.pi { phase -= 2 * Double.pi }
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for channel in 0..<Int(buffer.mNumberChannels) { data[frame * Int(buffer.mNumberChannels) + channel] = value }
        }
    }
    return noErr
}
engine.attach(source)
engine.connect(source, to: engine.mainMixerNode, format: format)
do {
    try engine.start()
    if profile == "idle-cycle" {
        // Stop real I/O for longer than the mixer's former three-second watchdog.
        // The process stays alive so discovery must tolerate an idle audio client.
        Thread.sleep(forTimeInterval: min(2, max(0, playbackDeadline - ProcessInfo.processInfo.systemUptime)))
        engine.stop()
        Thread.sleep(forTimeInterval: min(5, max(0, playbackDeadline - ProcessInfo.processInfo.systemUptime)))
        if ProcessInfo.processInfo.systemUptime < playbackDeadline { try engine.start() }
    }
    Thread.sleep(forTimeInterval: max(0, playbackDeadline - ProcessInfo.processInfo.systemUptime))
    engine.stop()
    _exit(0)
} catch { fputs("Audio probe failed: \(error)\n", stderr); _exit(1) }
