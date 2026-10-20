# Product assets

- `social-preview.png`: 1280 × 640 product cover using the existing teal/sliders identity.
- `download.svg`: linked download button for the current Apple Silicon release.
- `quick-start.png`: illustrated setup steps, not a screenshot of macOS settings.
- `interface-preview.png` and `interface-demo.gif`: the shipping SwiftUI view rendered with sample applications and values. The animation lasts 15 seconds. Every frame labels the sample data. No live audio session or third-party app is depicted.

The actual generated-signal and independent-output measurements are documented separately in [verification status](../VERIFICATION.md).

## Reproduce

On macOS with the project's build tools, run:

```sh
./Tools/render-showcase.sh
python3 Tools/make-launch-assets.py
```

The second command requires Pillow. It encodes the native view frames and generates the deterministic cover/setup graphics. These tools do not start the audio engine or read the user's saved mixer preferences. Intermediate frames are written to the ignored `.build/showcase/` directory.
