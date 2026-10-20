import Foundation

// Pure metadata comparisons: no device lookup, audio client, or recording.
@main
enum InputSnapshotTests {
    static func main() {
        let baseline: [String: Any] = [
            "available": true, "complete": true, "uid": "fixture-input", "sampleRate": Double(48000),
            "channels": UInt32(2), "controls": ["0.scalar": 0.42, "0.mute": 0.0],
            "unsupportedControls": ["1.mute", "1.scalar", "2.mute", "2.scalar"]
        ]
        func compare(_ during: [String: Any], _ after: [String: Any]? = nil) -> (status: String, verified: Bool, reason: String?, failure: String?) {
            EngineVerification.compareInputHardware(before: baseline, during: during, after: after ?? baseline)
        }
        assert(compare(baseline).verified)
        for (key, value) in [("uid", "other-input" as Any), ("sampleRate", Double(44100) as Any), ("channels", UInt32(1) as Any)] {
            var changed = baseline; changed[key] = value
            assert(compare(changed).status == "changed" && !compare(changed).verified)
            assert(compare(baseline, changed).status == "changed")
        }
        for controls in [["0.scalar": 0.3, "0.mute": 0.0], ["0.scalar": 0.42, "0.mute": 1.0], ["0.scalar": 0.42]] {
            var changed = baseline; changed["controls"] = controls
            assert(compare(changed).status == "changed")
        }
        var incomplete = baseline; incomplete["complete"] = false
        assert(compare(incomplete).status == "unavailable" && compare(incomplete).failure != nil)
        let absent: [String: Any] = ["available": false, "complete": true, "reason": "no-default-input-device"]
        let skipped = EngineVerification.compareInputHardware(before: absent, during: absent, after: absent)
        assert(skipped.status == "unavailable" && !skipped.verified && skipped.failure == nil)
        assert(compare(absent).failure != nil)
        let failedQuery: [String: Any] = ["available": false, "complete": false, "reason": "default-input-query-failed"]
        let unreadable = EngineVerification.compareInputHardware(before: failedQuery, during: failedQuery, after: failedQuery)
        assert(unreadable.status == "unavailable" && !unreadable.verified && unreadable.failure != nil)
        print("PASS: input snapshots detect UID/rate/channel/gain/mute changes; unavailable and failed reads never claim preservation; no devices opened")
    }
}
