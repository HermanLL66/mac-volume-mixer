# Release notes

## 0.2.0 — experimental source candidate, no published binary

- Refined SwiftUI interface with warm ivory/graphite surfaces, playing/all-app filters, continuous controls, and one global issue notice.
- 0–200% amplitude settings, with 100% unity at 75% slider travel and a 30 ms gain ramp.
- Linked stereo peak limiting for boost. 200% requests 2× amplitude before limiting; perceived loudness is not guaranteed.
- Revised audio path: tap-only aggregate capture and a separate output-only AUHAL renderer with physical input I/O disabled.
- Approximately 20 ms added buffer target, in addition to device and scheduling latency.
- No microphone capture or gain setting. Hardware input checks are read-only and do not prove unchanged conferencing echo cancellation or far-end voice levels.

Local development-bundle measurements of the shared backend are recorded separately; real audio for the English bundle remains pending. Real calls, Bluetooth, broader devices, and OS coverage are not validated. The new interface image uses labeled sample data. The download remains 0.1.0; do not describe these changes as present in that ZIP.

## 0.1.0 — downloadable historical release

Initial standalone release of the native macOS per-app volume controller.

## Included

- Independent app volume from 0% to 100% and individual mute.
- Audio-source discovery, search, and saved preferences.
- Menu bar access, pause, reset, and explicit cleanup on quit.
- Local in-memory audio processing with no recording or upload.
- Source code, build scripts, DSP tests, and audio diagnostics.

## Download

`Volume-Mixer-0.1.0-macOS-arm64.zip` contains **Volume Mixer.app** for Apple Silicon and requires macOS 14.4 or later. Extract the ZIP and move the app to Applications. `SHA256SUMS.txt` provides the download checksum.

This is an early, ad hoc signed build without Apple Developer ID signing or notarization. macOS may prevent a downloaded copy from opening. The repository includes instructions to build locally.

Grant system audio access when enabling control. The first verification plays a very quiet generated tone. The controls target local playback. The release does not intentionally set microphone gain, but far-end call behavior was not established by its tests. Browser tabs share a single app volume.

## Verification and limits

The packaged build is checked with strict local signature verification, DSP sanitizer tests, and mock-worker checks. The standalone binary has also passed generated-signal and independent downstream digital-output checks on macOS 14.6.1 with Apple Silicon and built-in stereo speakers. This does not establish broad third-party app compatibility or acoustic loudness. Protected media, exclusive devices, and unusual audio paths may be unsupported. Intel downloads are not included.
