#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p .build/module-cache
SDK_PATH="$(xcrun --show-sdk-path)"
ARCH_NAME="$(uname -m)"

# These tests operate on memory or blocked process fixtures, never audio devices.
xcrun clang -std=c11 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -ISources Tests/AudioDSPTests.c Sources/AudioDSP.c -framework CoreAudio -o .build/AudioDSPTests
.build/AudioDSPTests
xcrun clang -std=c11 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -ISources Tests/AudioTransportTests.c Sources/AudioTransport.c Sources/AudioDSP.c -framework CoreAudio -framework AudioToolbox -o .build/AudioTransportTests
.build/AudioTransportTests

# No AudioProbe engine is created in --watchdog-fixture mode.
xcrun swiftc -O -target "$ARCH_NAME-apple-macosx14.4" -sdk "$SDK_PATH" -module-cache-path "$PWD/.build/module-cache" Sources/AudioProbe.swift -o .build/AudioProbeWatchdogTests -framework AVFoundation
python3 Tests/AudioProbeWatchdogTests.py "$PWD/.build/AudioProbeWatchdogTests"

# Link the production comparison implementation; this entry only compares data.
xcrun clang -std=c11 -O1 -arch "$ARCH_NAME" -mmacosx-version-min=14.4 -isysroot "$SDK_PATH" -ISources -c Sources/AudioDSP.c -o .build/InputSnapshotAudioDSP.o
xcrun clang -std=c11 -O1 -arch "$ARCH_NAME" -mmacosx-version-min=14.4 -isysroot "$SDK_PATH" -ISources -c Sources/AudioTransport.c -o .build/InputSnapshotAudioTransport.o
xcrun swiftc -target "$ARCH_NAME-apple-macosx14.4" -sdk "$SDK_PATH" -module-cache-path "$PWD/.build/module-cache" -import-objc-header Sources/BridgingHeader.h Sources/CoreAudioSupport.swift Sources/TapSession.swift Sources/AudioEngine.swift Sources/AudioWorker.swift Sources/EngineVerification.swift Tests/InputSnapshotTests.swift .build/InputSnapshotAudioDSP.o .build/InputSnapshotAudioTransport.o -o .build/InputSnapshotTests -framework AppKit -framework CoreAudio -framework AudioToolbox
.build/InputSnapshotTests
