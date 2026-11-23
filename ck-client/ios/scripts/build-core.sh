#!/bin/bash
# Builds the shared Go core into ios/build/Ckcore.xcframework (needs macOS, Xcode command line tools, Go).
set -euo pipefail
cd "$(dirname "$0")/../.."          # ck-client/
command -v go >/dev/null || { echo "Go is required: brew install go"; exit 1; }
go test -count=1 ./ckcore
mkdir -p ios/build
go run golang.org/x/mobile/cmd/gomobile init
go run golang.org/x/mobile/cmd/gomobile bind -target ios,iossimulator -iosversion 16.0 \
  -trimpath -ldflags="-s -w" -o ios/build/Ckcore.xcframework ./ckcore
echo "built: $(pwd)/ios/build/Ckcore.xcframework"
