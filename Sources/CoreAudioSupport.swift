import AppKit
import CoreAudio

struct AudioFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw AudioFailure(message: "\(operation) failed (\(status))") }
    }
    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default fallback: T,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T {
        var result = fallback, size = UInt32(MemoryLayout<T>.size), property = address(selector, scope)
        let status = withUnsafeMutablePointer(to: &result) { AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0) }
        return status == noErr ? result : fallback
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var result: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size), property = address(selector)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &result) == noErr else { return nil }
        return result?.takeRetainedValue() as String?
    }
    static func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var property = address(selector, scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size) == noErr, size > 0 else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = result.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0.baseAddress!) }
        return status == noErr ? Array(result.prefix(Int(size) / MemoryLayout<AudioObjectID>.size)) : []
    }
    static func buffers(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [UInt32] {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope), size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size), "Read channels")
        guard size >= MemoryLayout<AudioBufferList>.size else { return [] }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        try check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, memory), "Read channels")
        let list = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        return list.map(\.mNumberChannels)
    }
    static func defaultOutput() throws -> OutputDevice {
        let id = value(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))
        guard id != 0, let uid = string(id, kAudioDevicePropertyDeviceUID) else { throw AudioFailure(message: "No audio output device available") }
        return OutputDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? "System Output",
                            sampleRate: value(id, kAudioDevicePropertyNominalSampleRate, default: Double(48000)))
    }
}

struct OutputDevice: Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let sampleRate: Double
}

struct AudioSource: Codable {
    let id: String
    let name: String
    let bundleURL: URL?
    var processes: [AudioObjectID]
    var running: Bool
}

enum SourceDiscovery {
    static func scan() -> [AudioSource] {
        let applications = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var groups: [String: AudioSource] = [:]
        for object in HAL.ids(HAL.system, kAudioHardwarePropertyProcessObjectList) {
            let pid = HAL.value(object, kAudioProcessPropertyPID, default: pid_t(0))
            guard pid != getpid(), pid > 1 else { continue }
            let bundleID = HAL.string(object, kAudioProcessPropertyBundleID) ?? ""
            guard !bundleID.hasPrefix("io.github.HaomingLyu613.VolumeMixer") else { continue }
            let running = HAL.value(object, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
            let app = applications.first { app in
                guard let id = app.bundleIdentifier else { return false }
                return app.processIdentifier == pid || bundleID == id || bundleID.hasPrefix(id + ".")
            }
            var url = app?.bundleURL ?? outerAppURL(pid: pid)
            if url == nil {
                var ancestor = MixerParentPID(pid)
                for _ in 0..<6 where ancestor > 1 {
                    if let parent = applications.first(where: { $0.processIdentifier == ancestor }) { url = parent.bundleURL; break }
                    ancestor = MixerParentPID(ancestor)
                }
            }
            let bundle = url.flatMap(Bundle.init(url:))
            let id = bundle?.bundleIdentifier ?? (bundleID.isEmpty ? "process.\(pid)" : bundleID)
            guard !id.hasPrefix("io.github.HaomingLyu613.VolumeMixer"), !id.hasPrefix("com.apple.audio."), id != "com.apple.audio.coreaudiod" else { continue }
            // Idle background services are not useful mixer rows. Show them if they produce audio.
            guard running || applications.contains(where: { $0.bundleIdentifier == id }) else { continue }
            let name = app?.localizedName ?? (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url?.deletingPathExtension().lastPathComponent ?? (bundleID.isEmpty ? "Audio Process \(pid)" : bundleID)
            if var existing = groups[id] { existing.processes.append(object); existing.running = existing.running || running; groups[id] = existing }
            else { groups[id] = AudioSource(id: id, name: name, bundleURL: url, processes: [object], running: running) }
        }
        return groups.values.map { source in var value = source; value.processes.sort(); return value }.sorted {
            if $0.running != $1.running { return $0.running }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    private static func outerAppURL(pid: pid_t) -> URL? {
        var path = [CChar](repeating: 0, count: 4096)
        guard MixerExecutablePath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let string = String(cString: path)
        guard let end = string.range(of: ".app/") else { return nil }
        return URL(fileURLWithPath: String(string[..<end.lowerBound]) + ".app")
    }
}
