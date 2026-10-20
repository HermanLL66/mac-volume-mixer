# Product announcement drafts

These are prepared copy, not evidence that a post has been published. Check each community's current rules and use the maintainer's own account. Disclose your relationship to the project. Do not ask for coordinated votes.

## Mac community post

**Title:** I made a free, open-source per-app volume mixer for macOS

Hi! I'm sharing Volume Mixer, a small native Mac app for adjusting individual apps' playback volume.

The use case is simple: lower a browser or background music without changing everything else. It provides 0–100% volume, individual mute, saved settings, search, and menu bar access. Audio is processed locally in memory, with no recording or uploads. The source is MIT licensed.

This is an early release for Apple Silicon and macOS 14.4+. The download is ad hoc signed and not notarized, so macOS may block it; source-build instructions are included. Third-party app and device coverage is still limited. The README animation is an interface preview with sample data; the separate verification page describes the actual generated-signal checks.

I'm looking for feedback on first launch, audio permissions, and app/device compatibility. If you try it, which app, macOS version, and output device worked or failed?

Project and download: https://github.com/HermanLL66/mac-volume-mixer

## r/macapps monthly App Pile comment

Use this version only after meeting the community's participation requirements. It is a draft, not a published comment.

**[OS] Volume Mixer: free per-app volume and mute for macOS**

I'm the maker of Volume Mixer.

**Problem:** Lower a browser or background music without changing the volume of everything else. Volume Mixer provides individual 0–100% volume, mute, saved settings, search, and menu bar access. Audio is processed locally in memory, with no recording or uploads.

**Comparison:** SoundSource is an established paid alternative. Volume Mixer's advantage is that all features and the full MIT-licensed source are free to use and modify. SoundSource offers per-app output routing and audio effects, which Volume Mixer does not provide. This early release has limited app/device coverage, so I cannot claim comparable reliability.

**Pricing:** $0 for all features, with no subscription or account. Source, download, installation guide, and compatibility notes: https://github.com/HermanLL66/mac-volume-mixer

Apple Silicon download, macOS 14.4+. The binary is ad hoc signed and not notarized; source-build instructions are available. The README animation uses sample data and is labeled as an interface preview. Actual generated-signal verification results are documented separately.

Feedback on first launch, audio permissions, and your app/output-device combination would help.

Suggested attachment: `docs/assets/interface-preview.png`. Caption: "Interface preview with sample apps and values; not a live capture."

Comparison source checked on 2026-10-20: [SoundSource's official feature page](https://www.rogueamoeba.com/soundsource/).

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

[Show HN's guidelines](https://news.ycombinator.com/showhn.html) require something people can try, maker participation, and no coordinated upvoting.

The logged-in [r/macapps posting interface](https://www.reddit.com/r/macapps/submit/) was checked on 2026-10-20. Its rules require 10 local community karma before self-promotion and limit promotion to once per developer per 30 days, including removed posts. New projects that do not meet the trust/transparency criteria belong in the monthly App Pile. The [October App Pile](https://www.reddit.com/r/macapps/comments/1wuoav5/megathread_the_app_pile_october_2026/) requires Problem, Comparison, and Pricing, an explicit competitor, and a project/site link rather than a direct ZIP/DMG link. Use an `[OS]` prefix for open source. Read the current rules again before submission; they can change.

Do not post promotional comments before meeting the participation requirements, manufacture participation to farm karma, or repost removed submissions to evade moderation. No Reddit submission has been published as part of this preparation.
