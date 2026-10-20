# Verification status by version

## Experimental 0.2.0 pre-release

The source introduces a different capture/render path, gain range, ramp, limiter, and interface. Earlier passing results do not validate these changes. The 0.2.0 binary is published as an experimental pre-release; English-bundle real-audio validation remains pending.

| Check | Current status | What it can establish |
| --- | --- | --- |
| English native SwiftUI preview at normal and minimum window sizes | Visually reviewed with labeled sample data | Layout, readability, and one global error notice; no audio compatibility evidence |
| English source build and fast checks | Passed locally | Compilation, strict ad hoc signature check, DSP/transport sanitizers, helper watchdog, input-metadata comparisons, and mock-worker lifecycle |
| Shared-backend local real-audio measurements | Passed in development bundle; English-bundle run pending | See the separate sanitized record below; distinct bundle identities are not interchangeable |
| Read-only hardware input-state comparison | Unchanged in development-bundle test; English-bundle run pending | Selected input properties only; not microphone audio or far-end voice behavior |
| Real conferencing call and human listening | Not validated | Needed to check local sound, remote voice level, and conferencing processing |
| Bluetooth and broader device coverage | Not validated | Requires actual device-specific sessions |

The [current preview](assets/interface-preview.png) says **SAMPLE DATA**. It is a render of the view, not an audio demonstration. A successful hardware-state comparison would not prove that conferencing echo cancellation or automatic gain control is unaffected. See [testing](TESTING.md) for the pre-release checklist.

## Shared-backend development measurements

On October 20, 2026, the local development bundle 1.1.0 was checked on macOS 14.6.1, Apple Silicon, built-in stereo output at 48 kHz. It uses the revised backend shared by this pre-release. This is **not** a real-audio result for the English 0.2.0 bundle: its distinct identity requires its own permission and integration check. The [sanitized record](verification/revised-backend-local.json) omits local paths, process/object IDs, and device identifiers.

- A 20.24-second engine exercise passed two independent sources, more than four seconds of actual idle/resume, process restart and in-place replacement, independent mute, and cleanup.
- Default input and output identity, sample rate, and supported volume/mute controls remained unchanged; each observed output AUHAL had physical input I/O disabled. No microphone audio was recorded.
- Chrome independently captured replay matched its native baseline at 50%, 25%, 150%, 200%, and mute for a quiet signal. A further 60.89 seconds at 50% maintained the connection; disable restored the native baseline and acknowledged cleanup before the worker exited.
- FIFO underflow counters increased during this run. These checks establish digital gain and bounded connection behavior, not glitch-free playback or acoustic quality.
- Both English source trees built and passed strict ad hoc signature verification, DSP/transport sanitizer tests, blocked-helper and parent-exit checks, metadata comparison tests, and mock-worker protocol/lifecycle checks locally.

Far-end voice level, conferencing AEC/AGC, Bluetooth, and longer human listening sessions remain unvalidated. A helper-discovery startup race was found during repeat launch and the bounded startup allowance was increased from two to eight seconds before the successful sustained run. This failed experiment is retained in the interpretation rather than silently presented as an all-passing history.

## Historical 0.1.0 verification

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

Chrome and other third-party app compatibility have not been validated for this standalone edition. The historical interface animation is rendered from the 0.1.0 SwiftUI view with clearly labeled sample data, separately from these audio tests. It is not a screen recording of a real app session.

Compilation and mock tests do not establish compatibility with every application or device. Intel builds, broad OS/device coverage, acoustic measurements, Apple Developer ID signing, and notarization are not part of this initial release.
