# Testing and diagnostics


Quit other instances of Volume Mixer before running an app-based diagnostic. Create the output directory first. Diagnostics save JSON reports; inspect `passed`, error/reason fields, and cleanup results instead of relying only on process exit status.

### Fast checks without real audio

```sh
./test.sh
mkdir -p output
"./dist/Volume Mixer.app/Contents/MacOS/VolumeMixer" --verify-worker "$PWD/output/worker-verification.json"
python3 -m json.tool output/worker-verification.json
```

The DSP tests use AddressSanitizer and UndefinedBehaviorSanitizer for gain, mute, smoothing, invalid samples, buffer bounds, and input isolation. The worker check uses mock processes for protocol round trips, timeouts, cancellation, cleanup hangs, crashes, launch failure, and rapid slider changes. These checks do not prove actual audio routing.

### Optional checks using real audio

These checks create quiet temporary audio signals and may request system audio access. Run one at a time and wait for the app to finish and exit before starting another.

The audio check exercises independent gain and mute through real processing buffers:

```sh
open -n "dist/Volume Mixer.app" --args --verify-audio "$PWD/output/audio-verification.json"
```

After that check exits, the engine check covers idle/resume, process restart and replacement, gain changes, cleanup, and hardware-state snapshots:

```sh
open -n "dist/Volume Mixer.app" --args --verify-engine "$PWD/output/engine-verification.json"
```

After the engine check exits, the output check compares an independent capture of replayed audio with a native baseline obtained by the same method:

```sh
open -n "dist/Volume Mixer.app" --args --verify-output "$PWD/output/output-verification.json"
```

### Optional Chrome integration example

This specific integration test is retained as one concrete third-party app check. It is not a claim that all browsers have been tested.

Open `Tests/BrowserAudio.html` in Chrome and click **Start test tone**. Keep it playing, with no other Chrome media active. Then run:

```sh
open -n "dist/Volume Mixer.app" --args --verify-chrome "$PWD/output/chrome-verification.json"
```

The check temporarily applies 50%, 25%, and mute to Chrome, compares independently captured digital output with its original baseline, then checks restoration and cleanup. Stop the fixture afterward.

### Inspect discovery

```sh
"./dist/Volume Mixer.app/Contents/MacOS/VolumeMixer" --list-audio
```

Discovery output may identify apps running on your machine. Review and redact it before posting publicly. Private taps may only be visible to their creator, so another process's empty tap list cannot prove cleanup.
