import AVFoundation
import Foundation

// A separate, temporary process provides a known signal for the first-run check.
let duration = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 25 : 25
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
    let deadline = ProcessInfo.processInfo.systemUptime + min(60, max(0.1, duration))
    try engine.start()
    if profile == "idle-cycle" {
        // Stop real I/O for longer than the mixer's former three-second watchdog.
        // The process stays alive so discovery must tolerate an idle audio client.
        Thread.sleep(forTimeInterval: min(2, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
        engine.stop()
        Thread.sleep(forTimeInterval: min(5, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
        if ProcessInfo.processInfo.systemUptime < deadline { try engine.start() }
    }
    Thread.sleep(forTimeInterval: max(0, deadline - ProcessInfo.processInfo.systemUptime))
    engine.stop()
} catch { fputs("Audio probe failed: \(error)\n", stderr); exit(1) }
