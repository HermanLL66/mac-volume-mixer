import Foundation
import CoreAudio

final class TapSession {
    private(set) var tap: AudioObjectID = 0
    private(set) var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var state: OpaquePointer?
    private(set) var processes: [AudioObjectID]
    let output: OutputDevice
    private(set) var processingActive = false
    private let wantsPlayback: Bool
    private var tapDescription: CATapDescription?
    private var started = false

    init(processes: [AudioObjectID], output: OutputDevice, gain: Float, playback: Bool = true) throws {
        self.processes = processes
        self.output = output
        self.wantsPlayback = playback
        do {
            let description = CATapDescription(processes: processes, deviceUID: output.uid, stream: 0)
            description.name = "Volume Mixer · Per-app volume"
            description.isPrivate = true
            // Keep original audio playing until valid input has actually arrived.
            description.muteBehavior = .unmuted
            tapDescription = description
            try HAL.check(AudioTrace.call("createTap") { AudioHardwareCreateProcessTap(description, &tap) }, "Connect application audio")
            let format = HAL.value(tap, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32, (1...2).contains(format.mChannelsPerFrame) else {
                throw AudioFailure(message: "Output format unsupported. Use built-in speakers or stereo headphones.")
            }
            let spec: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Volume Mixer (Private)",
                kAudioAggregateDeviceUIDKey: "io.github.HaomingLyu613.VolumeMixer.\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: output.uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                // Start IO immediately. Waiting for an initial tap event can
                // leave an already-playing Chrome stream without callbacks.
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
            ]
            try HAL.check(AudioTrace.call("createAggregate") { AudioHardwareCreateAggregateDevice(spec as CFDictionary, &aggregate) }, "Create audio channel")
            var sampleRate = output.sampleRate, sampleAddress = HAL.address(kAudioDevicePropertyNominalSampleRate)
            try HAL.check(AudioObjectSetPropertyData(aggregate, &sampleAddress, 0, nil, UInt32(MemoryLayout<Double>.size), &sampleRate), "Synchronize output sample rate")
            let inputBuffers = try HAL.buffers(aggregate, scope: kAudioObjectPropertyScopeInput)
            let outputBuffers = try HAL.buffers(aggregate, scope: kAudioObjectPropertyScopeOutput)
            let tapBufferCount: UInt32 = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? format.mChannelsPerFrame : 1
            guard inputBuffers.count >= Int(tapBufferCount), outputBuffers.reduce(0, +) > 0, outputBuffers.reduce(0, +) <= 2 else {
                throw AudioFailure(message: "Device unsupported. Use mono or stereo output.")
            }
            for stream in HAL.ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput) {
                let streamFormat = HAL.value(stream, kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription())
                guard streamFormat.mBitsPerChannel == 32, streamFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
                    throw AudioFailure(message: "Output device requires 32-bit float audio")
                }
            }
            state = MixerDSPCreate(gain, UInt32(inputBuffers.count) - tapBufferCount, tapBufferCount, false)
            guard let state else { throw AudioFailure(message: "Could not create audio processor") }
            try HAL.check(AudioTrace.call("createIOProc") { AudioDeviceCreateIOProcID(aggregate, MixerIOProc, UnsafeMutableRawPointer(state), &ioProc) }, "Connect output")
            guard let ioProc else { throw AudioFailure(message: "Audio output connection not established") }
            // Disable the hardware's input streams: we only process the appended audio tap.
            try HAL.check(MixerUseTapInputOnly(aggregate, ioProc), "Select application audio input")
            try HAL.check(AudioTrace.call("startIO") { AudioDeviceStart(aggregate, ioProc) }, "Start per-app volume")
            started = true
        } catch { _ = stop(); throw error }
    }

    func activateProcessing() throws {
        guard wantsPlayback, !processingActive, let state else { return }
        guard validCallbacks >= 3, hasReceivedSignal else { throw AudioFailure(message: "Application audio is not ready") }
        try setDescription(processes: processes, mute: .mutedWhenTapped)
        MixerDSPSetPlaybackEnabled(state, true)
        processingActive = true
    }
    func updateProcesses(_ processes: [AudioObjectID]) throws {
        try setDescription(processes: processes, mute: processingActive ? .mutedWhenTapped : .unmuted)
        self.processes = processes
    }
    private func setDescription(processes: [AudioObjectID], mute: CATapMuteBehavior) throws {
        guard tap != 0 else { throw AudioFailure(message: "Application audio connection released") }
        let description = CATapDescription(processes: processes, deviceUID: output.uid, stream: 0)
        if let original = tapDescription { description.uuid = original.uuid; description.name = original.name }
        description.isPrivate = true
        description.muteBehavior = mute
        var address = HAL.address(kAudioTapPropertyDescription)
        var reference = Unmanaged.passUnretained(description).toOpaque()
        try HAL.check(AudioTrace.call("setTapDescription") { AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &reference) }, "Update application audio connection")
        tapDescription = description
    }
    func setGain(_ gain: Float) { if let state { MixerDSPSetGain(state, gain) } }
    func takePeak() -> Float { state.map(MixerDSPTakePeak) ?? 0 }
    func takeOutputPeak() -> Float { state.map(MixerDSPTakeOutputPeak) ?? 0 }
    var callbacks: UInt64 { state.map(MixerDSPCallbackCount) ?? 0 }
    var invalidBuffers: UInt64 { state.map(MixerDSPInvalidCount) ?? 0 }
    var validCallbacks: UInt64 { state.map(MixerDSPValidCallbackCount) ?? 0 }
    var hasReceivedSignal: Bool { state.map(MixerDSPHasReceivedSignal) ?? false }
    var consecutiveInvalidBuffers: UInt64 { state.map(MixerDSPConsecutiveInvalidCount) ?? 0 }
    @discardableResult func stop() -> [String] {
        var errors: [String] = []
        if let state { MixerDSPSetPlaybackEnabled(state, false) }
        processingActive = false
        // Release the original signal first, even if a later device teardown fails.
        if tap != 0, tapDescription?.muteBehavior != .unmuted {
            do { try setDescription(processes: processes, mute: .unmuted) }
            catch { errors.append(error.localizedDescription) }
        }
        if aggregate != 0, let ioProc {
            if started {
                let status = AudioTrace.call("stopIO") { AudioDeviceStop(aggregate, ioProc) }
                if status == noErr { started = false } else { errors.append("Stop audio channel failed (\(status))") }
            }
            let status = AudioTrace.call("destroyIOProc") { AudioDeviceDestroyIOProcID(aggregate, ioProc) }
            if status == noErr { self.ioProc = nil; started = false }
            else { errors.append("Release audio callback failed (\(status))") }
        }
        if aggregate != 0 {
            let status = AudioTrace.call("destroyAggregate") { AudioHardwareDestroyAggregateDevice(aggregate) }
            if status == noErr { aggregate = 0; ioProc = nil; started = false }
            else { errors.append("Release audio device failed (\(status))") }
        }
        if tap != 0 {
            let status = AudioTrace.call("destroyTap") { AudioHardwareDestroyProcessTap(tap) }
            if status == noErr { tap = 0; tapDescription = nil }
            else { errors.append("Release audio interception failed (\(status))") }
        }
        // Never free memory still reachable from an OS audio callback.
        if ioProc == nil, let state { MixerDSPDestroy(state); self.state = nil }
        // A fallback destroy can succeed after an earlier stop/unmute failed.
        // Once both OS objects are gone, teardown is complete and retry is safe.
        if aggregate == 0, tap == 0, ioProc == nil { return [] }
        return errors
    }
    deinit { _ = stop() }
}
