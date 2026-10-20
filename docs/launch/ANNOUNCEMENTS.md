# Product announcement drafts

These are prepared copy, not evidence that a post has been published. Check each community's current rules and use the maintainer's own account. Disclose your relationship to the project. Do not ask for coordinated votes.

## Mac community post

**Title:** I made a free, open-source per-app volume mixer for macOS

Hi! I'm sharing Volume Mixer, a small native Mac app for adjusting individual apps' playback volume.

The use case is simple: lower a browser or background music without changing everything else. It provides 0–100% volume, individual mute, saved settings, search, and menu bar access. Audio is processed locally in memory, with no recording or uploads. The source is MIT licensed.

This is an early release for Apple Silicon and macOS 14.4+. The download is ad hoc signed and not notarized, so macOS may block it; source-build instructions are included. Third-party app and device coverage is still limited. The README animation is an interface preview with sample data; the separate verification page describes the actual generated-signal checks.

I'm looking for feedback on first launch, audio permissions, and app/device compatibility. If you try it, which app, macOS version, and output device worked or failed?

Project and download: https://github.com/HermanLL66/mac-volume-mixer

## Show HN

**Title:** Show HN: A native open-source per-app volume mixer for macOS

**URL:** https://github.com/HermanLL66/mac-volume-mixer

**First comment draft:**

I'm sharing a native macOS utility for independent application playback volume and mute. It uses SwiftUI/AppKit and Core Audio process taps, with audio operations in a separate worker process and a small C real-time processor.

I wanted a small control panel for balancing multiple audio sources. Settings are saved by application identity, and pause/quit release the processing path. Audio stays in memory on the Mac.

It's an early Apple Silicon build targeting macOS 14.4+. The binary is not Developer ID signed or notarized, and broad app/device compatibility is not established. The repository includes source builds, a compatibility table, diagnostic instructions, and explicit evidence limits.

I'd welcome feedback on the installation experience and any reproducible audio/device failures. I can answer questions about the process-tap path, worker deadlines, and cleanup.

## Short social post

Volume Mixer for macOS: free, open-source per-app volume and mute, with saved settings and menu bar access. Audio stays on your Mac. Early Apple Silicon release, macOS 14.4+; not yet notarized. Feedback welcome: https://github.com/HermanLL66/mac-volume-mixer

## Assets and claims

- Cover: `docs/assets/social-preview.png` (1280 × 640).
- Interface animation: `docs/assets/interface-demo.gif` (sample data, explicitly labeled).
- Setup illustration: `docs/assets/quick-start.png`.
- Verified results: `docs/VERIFICATION.md` and `docs/verification/`.
- Do not claim universal app support, measured acoustic loudness, zero latency, notarization, or an independent security audit.

## Publication notes

[Show HN's guidelines](https://news.ycombinator.com/showhn.html) require something people can try, maker participation, and no coordinated upvoting. Read [r/macapps](https://www.reddit.com/r/macapps/) rules in the current posting interface before submission; the public rules page did not expose readable rules during preparation. Do not assume that a particular post format or promotion frequency is permitted.
