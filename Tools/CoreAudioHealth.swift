import Foundation
import CoreAudio
import Darwin

func emit(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}
let began = ProcessInfo.processInfo.systemUptime
DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
    emit(["event": "deadline", "seconds": ProcessInfo.processInfo.systemUptime - began])
    _exit(124)
}
DispatchQueue.global().async {
    if CommandLine.arguments.contains("--taps") {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTapList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        emit(["event": "begin", "operation": "tapList"])
        let sizing = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        if size == 0 {
            emit(["event": "end", "operation": "tapList", "sizeStatus": sizing, "status": sizing, "taps": [UInt32]()])
            exit(sizing == noErr ? 0 : 1)
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        emit(["event": "end", "operation": "tapList", "sizeStatus": sizing, "status": status, "taps": ids])
        exit(status == noErr ? 0 : 1)
    }
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var output: AudioObjectID = 0, size = UInt32(MemoryLayout<AudioObjectID>.size)
    emit(["event": "begin", "operation": "defaultOutput"])
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &output)
    emit(["event": "end", "operation": "defaultOutput", "status": status, "device": output, "seconds": ProcessInfo.processInfo.systemUptime - began])
    exit(status == noErr ? 0 : 1)
}
RunLoop.main.run()
