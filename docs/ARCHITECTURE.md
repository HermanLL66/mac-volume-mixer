# Architecture

Volume Mixer is a native macOS application. The interface and audio integration run in separate processes so an unresponsive audio operation can be bounded without freezing the controls.

| Component | Responsibility |
| --- | --- |
| `Sources/main.swift` | App lifecycle, window, menu bar entry, diagnostic entry points |
| `Sources/MixerView.swift` | Volume rows, mute, search, connection and error states |
| `Sources/MixerModel.swift` | Preferences, visible state, coalesced slider updates |
| `Sources/AudioWorker.swift` | Worker client/server, JSON pipes, deadlines, cancellation, process termination |
| `Sources/CoreAudioSupport.swift` | Core Audio helpers and audio-source discovery |
| `Sources/AudioEngine.swift` | Session reconciliation, device changes, signal verification, health and retry state |
| `Sources/TapSession.swift` | Process taps, private aggregate devices, callbacks, cleanup ownership |
| `Sources/AudioDSP.c` | Floating-point sample gain, smooth transitions, buffer validation, atomic controls |
| `Sources/*Verification.swift`, `Tests/` | Checks at distinct integration levels |

The UI's `AudioEngine` client is declared in `AudioWorker.swift`; the audio-owning `LocalAudioEngine` is declared in `AudioEngine.swift`.

## Audio path

For an adjusted application, a private Core Audio process tap supplies audio to a private aggregate device. A C callback applies the requested gain and plays through the current default output. A short gain ramp reduces clicks when the slider changes. The app does not replace the system's default output device.

Before taking over a signal, the processing channel must receive valid, nonzero audio. Permission verification uses a quiet generated signal. At 100%, or when control is paused, the app releases the processing path so native playback can continue.

The worker tracks resources that could not be released and reports cleanup errors. The client imposes deadlines on worker operations and can stop its own worker after an unanswered operation. It does not restart system audio services.

Audio is processed in local memory. The app contains no audio file recording or upload path.

## Platform reference

[Apple: Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).
