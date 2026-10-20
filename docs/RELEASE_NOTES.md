# Volume Mixer for macOS 0.1.0

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

Grant system audio access when enabling control. The first verification plays a very quiet generated tone. Controls affect local playback, not outgoing microphone gain. Browser tabs share a single app volume.

## Verification and limits

The packaged build is checked with strict local signature verification, DSP sanitizer tests, and mock-worker checks. Real-audio diagnostics have not been rerun under the new standalone bundle identifier. Protected media, exclusive devices, and unusual audio paths may be unsupported. Intel downloads are not included.
