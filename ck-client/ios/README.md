# CK Client for iOS

SwiftUI app + Packet Tunnel (Network Extension) on top of the shared Go core `ckcore` (`../ckcore`): SSH tunnel + BadVPN UDPGW + user-space TCP/IP stack. Design and mock-ups: [DESIGN.md](DESIGN.md).

> **Status: code complete but never compiled or run on an iPhone.** It was written on Linux, where there is no Swift toolchain, Xcode or device. The Go core is tested (below); the Swift layer is not. Expect to fix a few compile errors and to tune memory on the first run.

## What was verified
* `go test ./ckcore` – an end-to-end test puts a second user-space stack ("the phone") in front of the engine and checks TCP through an in-process SSH server, UDP through a fake UDPGW (framing identical to the Windows app), a UDP flow left idle while TCP keeps working (the Windows stall bug), host-key pinning, ping, and all link/subscription import formats.
* `gobind -lang=objc ./ckcore` generates the Objective-C API; the Swift code uses exactly those names (`CkcoreNewEngine`, `CkcoreEngine.start()`, `CkcorePacketSinkProtocol`, ...).
* `GOOS=darwin GOARCH=arm64 go vet ./ckcore` passes.

## Needs (cannot be avoided)
* A **Mac with Xcode 15+**, Go 1.24+ (`brew install go xcodegen`).
* A **paid Apple Developer account**; in the developer portal enable *Network Extensions* for both App IDs and create the App Group. A free account cannot run a VPN extension.
* A real **iPhone** (iOS 16+): Packet Tunnel extensions do not run in the Simulator.

## Build
```bash
cd ck-client/ios
./scripts/build-core.sh          # -> build/Ckcore.xcframework (gomobile)
# edit the five "<--" values in project.yml (team id, bundle id, app group, keychain group)
xcodegen generate                # -> CKClient.xcodeproj
open CKClient.xcodeproj          # select your iPhone, Run
```
Then: Profiles → **+ → Import from panel** (paste an account link or subscription URL from the CK.VPN panel, or scan its QR) → Home → **Connect** → accept the VPN permission prompt.

## Layout
| Path | What |
|---|---|
| `Shared/` | models, Keychain, App Group file (used by app **and** extension) |
| `PacketTunnel/` | `NEPacketTunnelProvider`: starts the Go engine, sets routes/DNS, moves packets |
| `App/` | SwiftUI UI, import (clipboard / QR / `ckclient://import?link=`), VPN manager |
| `App/fa.lproj` | Persian strings (English is the development language) |

## First-run checklist (what to test on the phone)
1. Connect → status "Connected", ping shows, Log shows `SSH connected`, `udpgw reachable`, `tunnel up`.
2. Safari: exit IP is the server's; open a site that needs DNS.
3. UDP: a DNS lookup works (`udpgw` on) and an online game / voice call; turn UDPGW off and confirm DNS still works (TCP fallback).
4. **Memory:** watch the extension in Xcode (Debug navigator) while streaming video and opening many tabs. If it nears the limit, lower `CkcoreSetMemoryLimitMB`, reduce the buffer sizes in `ckcore/engine.go`, or switch to the native-Swift core described in DESIGN.md.
5. Airplane-mode toggle / Wi-Fi ↔ cellular: the link must show "Reconnecting..." and recover.
6. Kill switch on: stop the SSH server → no traffic leaks.
7. Wrong password → clear error on Home; changed server key → refused with a message.

## Known gaps
* No proxy mode (not possible on iOS), no widgets/Control Center toggle, no iPad layout.
* The profile list shows no per-profile latency; QR import needs camera permission.
* Not localized beyond English/Persian. No unit tests on the Swift side yet.
