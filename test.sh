#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p .build
xcrun clang -std=c11 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -ISources Tests/AudioDSPTests.c Sources/AudioDSP.c -framework CoreAudio -o .build/AudioDSPTests
.build/AudioDSPTests
