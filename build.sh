#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p .build/module-cache
BUILD_STAGE="$(mktemp -d /private/tmp/volume-mixer-build.XXXXXX)"
trap '/bin/rm -rf "$BUILD_STAGE"' EXIT
APP="$BUILD_STAGE/Volume Mixer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
SDK_PATH="$(xcrun --show-sdk-path)"
ARCH_NAME="$(uname -m)"
xcrun clang -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter -arch "$ARCH_NAME" -mmacosx-version-min=14.4 -isysroot "$SDK_PATH" -c Sources/AudioDSP.c -o .build/AudioDSP.o
xcrun swiftc -O -target "$ARCH_NAME-apple-macosx14.4" -sdk "$SDK_PATH" -module-cache-path "$PWD/.build/module-cache" Sources/AudioProbe.swift -o "$APP/Contents/Helpers/AudioProbe" -framework AVFoundation
xcrun swiftc -O -target "$ARCH_NAME-apple-macosx14.4" -sdk "$SDK_PATH" -module-cache-path "$PWD/.build/module-cache" -import-objc-header Sources/BridgingHeader.h Sources/CoreAudioSupport.swift Sources/TapSession.swift Sources/AudioEngine.swift Sources/AudioWorker.swift Sources/TapInventory.swift Sources/WorkerVerification.swift Sources/ChromeVerification.swift Sources/AudioVerification.swift Sources/EngineVerification.swift Sources/OutputVerification.swift Sources/MixerModel.swift Sources/MixerView.swift Sources/main.swift .build/AudioDSP.o -o "$APP/Contents/MacOS/VolumeMixer" -framework AppKit -framework SwiftUI -framework CoreAudio
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
xattr -rd com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -rd com.apple.ResourceFork "$APP" 2>/dev/null || true
codesign --force --sign - "$APP/Contents/Helpers/AudioProbe"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p dist
ditto -c -k --keepParent --norsrc --noextattr "$APP" "$PWD/dist/Volume Mixer.zip"
ditto --norsrc --noextattr "$APP" "$PWD/dist/Volume Mixer.app"
# Sync providers can attach Finder metadata while the bundle is copied.
# Retry cleanup briefly; never report a bundle with a failed signature as built.
for attempt in 1 2 3; do
    xattr -cr "$PWD/dist/Volume Mixer.app"
    if codesign --verify --deep --strict "$PWD/dist/Volume Mixer.app"; then
        print "Built: $PWD/dist/Volume Mixer.app"
        exit 0
    fi
done
print -u2 "Bundle verification failed after metadata cleanup. Build from a folder outside cloud sync and retry."
exit 1
