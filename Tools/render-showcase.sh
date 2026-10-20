#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p .build/showcase .build/module-cache
sdk_path="$(xcrun --show-sdk-path)"
architecture="$(uname -m)"
xcrun clang -std=c11 -O2 -arch "$architecture" -mmacosx-version-min=14.4 -isysroot "$sdk_path" -c Sources/AudioDSP.c -o .build/showcase/AudioDSP.o
source_files=(Sources/*.swift)
source_files=(${source_files:#Sources/main.swift})
source_files=(${source_files:#Sources/AudioProbe.swift})
xcrun swiftc -O -target "$architecture-apple-macosx14.4" -sdk "$sdk_path" -module-cache-path "$PWD/.build/module-cache" -import-objc-header Sources/BridgingHeader.h "${source_files[@]}" Tools/RenderShowcase.swift .build/showcase/AudioDSP.o -o .build/showcase/RenderShowcase -framework AppKit -framework SwiftUI -framework CoreAudio
.build/showcase/RenderShowcase "$PWD/.build/showcase/frames"
