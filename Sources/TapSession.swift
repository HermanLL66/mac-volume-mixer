import Foundation
import CoreAudio
import AudioToolbox

final class TapSession {
    private(set) var tap: AudioObjectID = 0
    private(set) var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var transport: OpaquePointer?
    private var outputUnit: AudioUnit?
    private var captureStarted = false
    private var outputStarted = false
    private var outputInitialized = false
    private var callbackLifetimeUncertain = false
    private(set) var processes: [AudioObjectID]
    let output: OutputDevice
    private(set) var processingActive = false
    private let wantsPlayback: Bool
    private var tapDescription: CATapDescription?
    private(set) var physicalInputIOEnabled: UInt32 = UInt32.max
    private(set) var captureSampleRate: Double = 0
    private(set) var renderSampleRate: Double = 0

    // No physical sub-device or physical clock source is part of this aggregate.
    static func captureSpecification(tapUID: String, uid: String) -> [String: Any] {
        [kAudioAggregateDeviceNameKey: "Volume Mixer · Application capture",
         kAudioAggregateDeviceUIDKey: uid, kAudioAggregateDeviceIsPrivateKey: true,
         kAudioAggregateDeviceTapAutoStartKey: false,
         kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]]]
    }

    init(processes: [AudioObjectID], output: OutputDevice, gain: Float, playback: Bool = true) throws {
        self.processes = processes
        self.output = output
        wantsPlayback = playback
        do {
            let description = CATapDescription(processes: processes, deviceUID: output.uid, stream: 0)
            description.name = "Volume Mixer · Per-app volume"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            tapDescription = description
            try HAL.check(AudioTrace.call("createTap") { AudioHardwareCreateProcessTap(description, &tap) }, "Connect application audio")
            let tapFormat = AudioTrace.call("readTapFormat") { HAL.value(tap, kAudioTapPropertyFormat, default: AudioStreamBasicDescription()) }
            guard Self.supported(tapFormat) else { throw AudioFailure(message: "Application audio requires mono or stereo 32-bit float format") }
            let spec = Self.captureSpecification(tapUID: description.uuid.uuidString, uid: "io.github.HaomingLyu613.VolumeMixer.capture.\(UUID().uuidString)")
            try HAL.check(AudioTrace.call("createCaptureAggregate") { AudioHardwareCreateAggregateDevice(spec as CFDictionary, &aggregate) }, "Create application capture channel")
            // Configure only our tap-only aggregate. Never set a physical device's
            // rate, input controls, or an aggregate containing physical hardware.
            var captureRate = tapFormat.mSampleRate, rateAddress = HAL.address(kAudioDevicePropertyNominalSampleRate)
            try HAL.check(AudioTrace.call("setCaptureRate") {
                AudioObjectSetPropertyData(aggregate, &rateAddress, 0, nil, UInt32(MemoryLayout<Double>.size), &captureRate)
            }, "Configure application capture sample rate")
            let inputs = try AudioTrace.call("readCaptureInputBuffers") { try HAL.buffers(aggregate, scope: kAudioObjectPropertyScopeInput) }
            let outputs = try AudioTrace.call("readCaptureOutputBuffers") { try HAL.buffers(aggregate, scope: kAudioObjectPropertyScopeOutput) }
            guard !inputs.isEmpty, inputs.reduce(0, +) == tapFormat.mChannelsPerFrame, outputs.reduce(0, +) == 0 else {
                throw AudioFailure(message: "Capture channel contains unexpected inputs or outputs. Original playback preserved.")
            }
            let streams = AudioTrace.call("readCaptureStreams") { HAL.ids(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput) }
            guard !streams.isEmpty else { throw AudioFailure(message: "Application capture input stream not established") }
            var actualCaptureRate: Double?
            for stream in streams {
                let format = AudioTrace.call("readCaptureStreamFormat") { HAL.value(stream, kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription()) }
                guard Self.supported(format) else { throw AudioFailure(message: "Application capture stream format unsupported") }
                if let previous = actualCaptureRate, abs(previous - format.mSampleRate) > 0.1 { throw AudioFailure(message: "Application capture input streams have different sample rates") }
                actualCaptureRate = format.mSampleRate
            }
            guard let actualCaptureRate else { throw AudioFailure(message: "Could not read application capture sample rate") }
            captureSampleRate = actualCaptureRate

            // AUHAL bus 0 renders playback; input bus 1 is explicitly disabled.
            // No input callback or VoiceProcessingIO unit is ever created.
            var componentDescription = AudioComponentDescription(componentType: kAudioUnitType_Output,
                componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0, componentFlagsMask: 0)
            let found = AudioTrace.call("findOutputOnlyAUHAL") { AudioComponentFindNext(nil, &componentDescription) }
            guard let component = found else { throw AudioFailure(message: "System output audio unit unavailable") }
            try HAL.check(AudioTrace.call("createOutputOnlyAUHAL") { AudioComponentInstanceNew(component, &outputUnit) }, "Create independent playback channel")
            guard let unit = outputUnit else { throw AudioFailure(message: "Independent playback channel not established") }
            var disabled: UInt32 = 0, enabled: UInt32 = 1, device = output.id
            try setUnit(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disabled, "disableAUHALPhysicalInput")
            try setUnit(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled, "enableAUHALOutput")
            try setUnit(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, "setAUHALOutputDevice")
            try assertPhysicalInputDisabled(unit)
            let hardwareFormat: AudioStreamBasicDescription = try getUnit(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0,
                AudioStreamBasicDescription(), "readAUHALHardwareOutputFormat")
            let channels = try AudioTrace.call("readPhysicalOutputChannels") { try HAL.buffers(output.id, scope: kAudioObjectPropertyScopeOutput).reduce(0, +) }
            guard (1...2).contains(channels), hardwareFormat.mSampleRate.isFinite, (8000...384000).contains(hardwareFormat.mSampleRate) else {
                throw AudioFailure(message: "Independent playback currently supports mono or stereo output devices")
            }
            var clientFormat = AudioStreamBasicDescription(mSampleRate: hardwareFormat.mSampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: channels * 4, mFramesPerPacket: 1,
                mBytesPerFrame: channels * 4, mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
            renderSampleRate = clientFormat.mSampleRate
            try setUnit(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &clientFormat, "setAUHALClientOutputFormat")
            var requestedFrames: UInt32 = 4096
            try setUnit(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &requestedFrames, "setAUHALMaximumFrames")
            let maximumFrames: UInt32 = try getUnit(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, UInt32(0), "readAUHALMaximumFrames")
            transport = MixerTransportCreate(gain, tapFormat.mChannelsPerFrame, actualCaptureRate, clientFormat.mSampleRate, channels, maximumFrames)
            guard let transport else { throw AudioFailure(message: "Could not create audio clock bridge buffer") }
            AudioTrace.event("transport", "tap=\(tap) aggregate=\(aggregate) captureRate=\(actualCaptureRate) outputRate=\(clientFormat.mSampleRate) captureChannels=\(tapFormat.mChannelsPerFrame) outputChannels=\(channels) physicalInputIOEnabled=\(physicalInputIOEnabled)")
            try HAL.check(AudioTrace.call("createCaptureIOProc") {
                AudioDeviceCreateIOProcID(aggregate, MixerTransportCaptureIOProc, UnsafeMutableRawPointer(transport), &ioProc)
            }, "Connect application capture callback")
            guard let ioProc else { throw AudioFailure(message: "Application capture callback not established") }
            var callback = AURenderCallbackStruct(inputProc: MixerTransportRender, inputProcRefCon: UnsafeMutableRawPointer(transport))
            try setUnit(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, "setAUHALOutputCallback")
            try HAL.check(AudioTrace.call("initializeOutputOnlyAUHAL") { AudioUnitInitialize(unit) }, "Prepare independent playback")
            outputInitialized = true
            try assertPhysicalInputDisabled(unit)
            captureStarted = true
            try HAL.check(AudioTrace.call("startTapOnlyCapture") { AudioDeviceStart(aggregate, ioProc) }, "Start application capture")
            outputStarted = true
            try HAL.check(AudioTrace.call("startOutputOnlyAUHAL") { AudioOutputUnitStart(unit) }, "Start independent playback")
        } catch { _ = stop(); throw error }
    }

    private func setUnit<T>(_ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
                           _ element: AudioUnitElement, _ value: inout T, _ operation: String) throws {
        let status = withUnsafePointer(to: &value) { pointer in
            AudioTrace.call(operation) { AudioUnitSetProperty(unit, property, scope, element, pointer, UInt32(MemoryLayout<T>.size)) }
        }
        try HAL.check(status, "Configure independent playback channel")
    }
    private func getUnit<T>(_ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
                           _ element: AudioUnitElement, _ fallback: T, _ operation: String) throws -> T {
        var value = fallback, size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioTrace.call(operation) { AudioUnitGetProperty(unit, property, scope, element, pointer, &size) }
        }
        try HAL.check(status, "Read independent playback channel")
        return value
    }
    private static func supported(_ format: AudioStreamBasicDescription) -> Bool {
        let channelsPerBuffer: UInt32 = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 ? format.mChannelsPerFrame : 1
        return format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 32 && format.mFormatFlags & kAudioFormatFlagIsFloat != 0 &&
        format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 && format.mFramesPerPacket == 1 && format.mBytesPerFrame == channelsPerBuffer * 4 &&
        (1...2).contains(format.mChannelsPerFrame) && format.mSampleRate.isFinite && (8000...384000).contains(format.mSampleRate)
    }
    private func assertPhysicalInputDisabled(_ unit: AudioUnit) throws {
        let input: UInt32 = try getUnit(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1), "verifyAUHALPhysicalInputDisabled")
        physicalInputIOEnabled = input
        guard input == 0 else { throw AudioFailure(message: "Playback channel could not disable physical input. Original playback preserved.") }
    }
    func activateProcessing() throws {
        guard wantsPlayback, !processingActive, let transport else { return }
        guard validCallbacks >= 3, hasReceivedSignal else { throw AudioFailure(message: "Application audio is not ready") }
        try setDescription(processes: processes, mute: .mutedWhenTapped)
        MixerTransportSetPlaybackEnabled(transport, true)
        processingActive = true
    }
    func updateProcesses(_ processes: [AudioObjectID]) throws {
        try setDescription(processes: processes, mute: processingActive ? .mutedWhenTapped : .unmuted)
        self.processes = processes
    }
    func suspendProcessing() throws {
        guard processingActive, let transport else { return }
        // Do not tear down capture/AUHAL just because VAD or a paused source is
        // quiet. Restore native routing first; reactivation requires new input.
        try setDescription(processes: processes, mute: .unmuted)
        MixerTransportSetPlaybackEnabled(transport, false)
        processingActive = false
    }
    private func setDescription(processes: [AudioObjectID], mute: CATapMuteBehavior) throws {
        guard tap != 0 else { throw AudioFailure(message: "Application audio connection released") }
        let description = CATapDescription(processes: processes, deviceUID: output.uid, stream: 0)
        if let original = tapDescription { description.uuid = original.uuid; description.name = original.name }
        description.isPrivate = true
        description.muteBehavior = mute
        var address = HAL.address(kAudioTapPropertyDescription)
        var reference = Unmanaged.passUnretained(description).toOpaque()
        try HAL.check(AudioTrace.call("setTapDescription") {
            AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &reference)
        }, "Update application audio connection")
        tapDescription = description
    }
    func setGain(_ gain: Float) { if let transport { MixerTransportSetGain(transport, gain) } }
    func takePeak() -> Float { transport.map(MixerTransportTakePeak) ?? 0 }
    func takeOutputPeak() -> Float { transport.map(MixerTransportTakeOutputPeak) ?? 0 }
    var callbacks: UInt64 { transport.map(MixerTransportCallbackCount) ?? 0 }
    var validCallbacks: UInt64 { transport.map(MixerTransportValidCallbackCount) ?? 0 }
    var hasReceivedSignal: Bool { transport.map(MixerTransportHasReceivedSignal) ?? false }
    var invalidBuffers: UInt64 { transport.map(MixerTransportInvalidCount) ?? 0 }
    var consecutiveInvalidBuffers: UInt64 { transport.map(MixerTransportConsecutiveInvalidCount) ?? 0 }
    var captureCallbacks: UInt64 { transport.map(MixerTransportCaptureCallbackCount) ?? 0 }
    var captureWaitingForInput: Bool { transport.map(MixerTransportWaitingForInput) ?? true }
    var queuedFrames: UInt64 { transport.map(MixerTransportQueuedFrames) ?? 0 }
    var droppedFrames: UInt64 { transport.map(MixerTransportDroppedFrames) ?? 0 }
    var underflowFrames: UInt64 { transport.map(MixerTransportUnderflowFrames) ?? 0 }

    @discardableResult func stop() -> [String] {
        var errors: [String] = []
        if tap != 0, tapDescription?.muteBehavior != .unmuted {
            do { try setDescription(processes: processes, mute: .unmuted) }
            catch { errors.append(error.localizedDescription) }
        }
        if let transport { MixerTransportSetPlaybackEnabled(transport, false) }
        processingActive = false
        if let unit = outputUnit {
            if outputStarted {
                let status = AudioTrace.call("stopOutputOnlyAUHAL") { AudioOutputUnitStop(unit) }
                if status == noErr { outputStarted = false } else { callbackLifetimeUncertain = true; errors.append("Stop independent playback failed (\(status))") }
            }
            if outputInitialized {
                let status = AudioTrace.call("uninitializeOutputOnlyAUHAL") { AudioUnitUninitialize(unit) }
                if status == noErr { outputInitialized = false } else { callbackLifetimeUncertain = true; errors.append("Release playback resources failed (\(status))") }
            }
            let status = AudioTrace.call("disposeOutputOnlyAUHAL") { AudioComponentInstanceDispose(unit) }
            if status == noErr { outputUnit = nil; outputStarted = false; outputInitialized = false }
            else { callbackLifetimeUncertain = true; errors.append("Release independent playback unit failed (\(status))") }
        }
        if aggregate != 0, let ioProc {
            if captureStarted {
                let status = AudioTrace.call("stopTapOnlyCapture") { AudioDeviceStop(aggregate, ioProc) }
                if status == noErr { captureStarted = false } else { callbackLifetimeUncertain = true; errors.append("Stop application capture failed (\(status))") }
            }
            let status = AudioTrace.call("destroyCaptureIOProc") { AudioDeviceDestroyIOProcID(aggregate, ioProc) }
            if status == noErr { self.ioProc = nil; captureStarted = false }
            else { callbackLifetimeUncertain = true; errors.append("Release capture callback failed (\(status))") }
        }
        if aggregate != 0 {
            let status = AudioTrace.call("destroyCaptureAggregate") { AudioHardwareDestroyAggregateDevice(aggregate) }
            if status == noErr { aggregate = 0; ioProc = nil; captureStarted = false }
            else { errors.append("Release application capture device failed (\(status))") }
        }
        if tap != 0 {
            let status = AudioTrace.call("destroyTap") { AudioHardwareDestroyProcessTap(tap) }
            if status == noErr { tap = 0; tapDescription = nil }
            else { errors.append("Release audio interception failed (\(status))") }
        }
        // Retain context if either owner might still invoke a realtime callback.
        // Terminating the isolated worker remains the bounded recovery fallback.
        if ioProc == nil, outputUnit == nil, !callbackLifetimeUncertain, let transport { MixerTransportDestroy(transport); self.transport = nil }
        if callbackLifetimeUncertain { errors.append("Audio channel not fully released: callback cleanup could not be confirmed. Restart the audio worker.") }
        if tap == 0, aggregate == 0, ioProc == nil, outputUnit == nil, !callbackLifetimeUncertain { return [] }
        return errors
    }
    deinit { _ = stop() }
}
