#!/bin/bash
# Cross-compiles CK Client for Windows x64 (works on Linux/macOS/Windows with Go installed).
set -e
cd "$(dirname "$0")"
go test -count=1 .
# icon + manifest (Administrator, visual styles) -> resource object picked up by the linker
go run github.com/akavel/rsrc -arch amd64 -manifest assets/ck.manifest -ico assets/ck.ico -o rsrc_windows_amd64.syso
mkdir -p dist
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-H=windowsgui -s -w" -o dist/ck-client.exe .
if command -v makensis >/dev/null; then
  makensis -V1 installer/ck-client.nsi && echo "installer: $(pwd)/dist/CK-Client-Setup.exe"
else
  echo "(makensis not found - skipping the installer; install NSIS to build it)"
fi
echo "built: $(pwd)/dist/ck-client.exe"
echo "Copy wintun.dll (amd64, from https://www.wintun.net) next to it for VPN mode."
