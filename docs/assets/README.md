# Product assets

- `interface-preview.png`: experimental 0.2.0 native SwiftUI interface rendered with sample applications and values. The image explicitly says **DESIGN PREVIEW · SAMPLE DATA**. It is layout evidence, not live audio or app compatibility evidence.
- `interface-demo.gif`: historical 0.1.0 SwiftUI animation with labeled sample data. It depicts the previous interface and 0–100% controls, not the experimental revision.
- `social-preview.png`: product cover using the earlier teal/sliders identity.
- `download.svg`: linked download button for the experimental 0.2.0 Apple Silicon pre-release.
- `quick-start.png`: illustrated setup steps from the earlier edition, not a screenshot of macOS settings.

No personal application content or real call is depicted. Audio measurements and version boundaries are documented separately in [verification status](../VERIFICATION.md).

## Historical asset tools

`Tools/render-showcase.sh` and `Tools/make-launch-assets.py` were used for the earlier showcase animation and deterministic cover/setup graphics. The Python tool requires Pillow. Do not treat regeneration of those visuals as an audio check, or label their old interface as the source for the current pre-release.
