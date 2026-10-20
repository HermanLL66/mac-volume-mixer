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

The real-audio, sustained-engine, independent-output, and Chrome diagnostics are included in [TESTING.md](TESTING.md). They require a suitable output device and system audio permission. They have not been rerun under this standalone product's new bundle identifier.

Compilation and mock tests do not establish compatibility with every application or device. Intel builds, broad OS/device coverage, acoustic measurements, Apple Developer ID signing, and notarization are not part of this initial release.
