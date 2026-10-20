# Verification status

The initial standalone product targets macOS 14.4 or later. Local packaging checks use macOS 14.6.1, Apple Silicon (`arm64`), and Swift 5.10.

The following local checks passed for version 0.1.0:

- Compilation, packaging, and strict local ad hoc signature verification.
- DSP tests with AddressSanitizer and UndefinedBehaviorSanitizer, including 10,000 callback cycles.
- All seven mock-worker checks: protocol round trips, hung requests, cancellation, blocked cleanup, crashes, launch failure, and rapid slider updates.
- 1,001 slider updates preserved the final 37% setting and coalesced into two scans in this run.
- Extraction of the downloadable ZIP into a fresh temporary directory, followed by strict signature verification and checks of the bundle identifier, version, and app icon.
- Shell syntax and publication file/link checks.

The GitHub workflow repeats the fast checks on a hosted macOS runner. See the repository's Actions tab for hosted results.

## Real audio checks for the standalone bundle

On October 20, 2026, the shipping `0.1.0` standalone bundle was checked on macOS 14.6.1, Apple Silicon, built-in stereo speakers at 48 kHz. No audio files were saved.

| Check | Observed result | Evidence |
| --- | --- | --- |
| Two real temporary audio processes | Processing-buffer gains of 0.25 and 0.75 | [Generated-audio result](verification/generated-audio.json) |
| Independent mute | The first output peak was zero; the second retained approximately 0.75 gain | [Generated-audio result](verification/generated-audio.json) |
| Default output preservation | Before/after device identity matched | [Generated-audio result](verification/generated-audio.json) |
| Independent downstream capture at 100% | Approximately 1.0 relative to the same-method native baseline | [Independent-output result](verification/independent-output.json) |
| Independent downstream capture at 25% | Approximately 0.25 relative to that baseline | [Independent-output result](verification/independent-output.json) |
| Independent downstream capture at mute | Callbacks continued and the captured peak was zero | [Independent-output result](verification/independent-output.json) |
| Output-check cleanup | Control objects released, monitor cleanup succeeded, source capture retained its baseline | [Independent-output result](verification/independent-output.json) |

The public JSON files select relevant results and omit local process/object identifiers and device identifiers. The [testing guide](TESTING.md) contains the commands needed to reproduce these checks. These measurements concern digital audio paths and do not measure acoustic speaker loudness.

Chrome and other third-party app compatibility have not been validated for this standalone edition. The interface animation is rendered from the shipping SwiftUI view with clearly labeled sample data, separately from these audio tests. It is not a screen recording of a real app session.

Compilation and mock tests do not establish compatibility with every application or device. Intel builds, broad OS/device coverage, acoustic measurements, Apple Developer ID signing, and notarization are not part of this initial release.
