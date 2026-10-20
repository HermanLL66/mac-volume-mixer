# Compatibility and test coverage

Volume Mixer targets macOS 14.4 or later. The initial downloadable build is for Apple Silicon. This table separates observed results from configurations that still need testing.

| Configuration or behavior | Status | Evidence |
| --- | --- | --- |
| macOS 14.6.1, Apple Silicon, built-in stereo speakers | Generated-signal check passed | [Sanitized result](verification/generated-audio.json) |
| Two real temporary audio processes at 25% and 75% | Passed | Processing-buffer gain ratios matched the requested settings. |
| Mute the first temporary process; retain 75% for the second | Passed | First output peak was zero; the second retained its gain. |
| Preserve the default output device in that check | Passed | Before/after device identity matched. |
| Independently captured replay at 100%, 25%, and mute | Passed | [Same-method native-baseline comparison](verification/independent-output.json); digital, not acoustic measurement. |
| DSP gain, mute, smoothing, buffer handling | Passed | Sanitizer tests; see [verification status](VERIFICATION.md). |
| Worker timeouts, cancellation, crashes, and rapid slider updates | Passed | Mock-worker checks, not real app routing. |
| Chrome, Safari, Spotify, conferencing apps, games | Not yet validated for this standalone edition | Please report actual app version, macOS version, and device. |
| AirPods, Bluetooth, USB, HDMI, and multichannel devices | Not yet validated for this standalone edition | Mono/stereo is the intended scope; unusual formats may be unsupported. |
| Intel Mac | Not validated; no prebuilt download | Source targets the current CPU architecture. |
| Other macOS versions | Not validated locally | Minimum target version does not imply every release has been tested. |

These are digital signal checks, not acoustic measurements. Generated audio processes are not a substitute for third-party app tests. The interface animation uses sample apps and values and is not compatibility evidence.

## Share a test result

Open an [audio bug/test report](https://github.com/HermanLL66/mac-volume-mixer/issues/new?template=audio_bug.yml) with the app version, macOS version, CPU, output device, reproduction, and result. A working result is useful too. Do not include recorded audio, private application content, or unredacted local logs.
