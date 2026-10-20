import Foundation
import CoreAudio
import Darwin

struct TapInventoryEntry: Codable {
    let object: AudioObjectID
    let uid: String
    let name: String
}

enum TapInventory {
    static func current() throws -> [TapInventoryEntry] {
        try HAL.ids(HAL.system, kAudioHardwarePropertyTapList).map { object in
            guard let uid = HAL.string(object, kAudioTapPropertyUID) else {
                throw AudioFailure(message: "Could not read audio tap identifier")
            }
            return TapInventoryEntry(object: object, uid: uid, name: HAL.string(object, kAudioObjectPropertyName) ?? "")
        }
    }

}
