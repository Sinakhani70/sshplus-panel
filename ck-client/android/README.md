# CK Client for Android

Native Android app (plain Java, no libraries) + the shared Go engine. Works with the CK.VPN panel: SSH + BadVPN UDPGW, SSH over TLS/SNI, full-device VPN through Android's `VpnService`.

**APK (universal, Android 5.0+ / API 21, arm64-v8a · armeabi-v7a · x86_64):** `../dist/CK-Client.apk`

## How it works
```
VpnService (Java) ── TUN ──► loopback socket ──► ckengine (Go, runs as lib*.so child process)
                                                   SSH direct-tcpip + UDPGW + user-space TCP/IP stack ─► server
```
* The Go engine is `../cmd/ckengine` built for each ABI and shipped as `lib/<abi>/libckengine.so` (Android only lets apps execute files from the native-library dir). No NDK / gomobile needed.
* The app excludes itself from the VPN (`addDisallowedApplication`), so the engine's SSH connection never loops. The server name is resolved before the VPN starts.
* Import: clipboard, a pasted link, tapping an `ssh://` link, "Share" to CK Client, `ckclient://import?link=`, or a subscription URL (`https://HOST:2053/s/<token>`). Parsing is done by the engine (`ckengine parse`) so all apps accept the same formats.
* Passwords are encrypted with an Android Keystore key (API 23+).

## Install
1. Download `CK-Client.apk` on the phone and open it. Allow "install unknown apps" for the browser/file manager when asked.
2. If Play Protect says "unknown app", choose *Install anyway* (the app is not on Google Play and is signed with its own key).
3. Open CK Client → **Import** (after copying an account link in the panel) → **Connect** → accept the VPN prompt.

## Build (Linux/macOS, no Android Studio)
```bash
apt install aapt apksigner zipalign dalvik-exchange default-jdk-headless golang   # or equivalents
./build.sh        # -> ../dist/CK-Client.apk
```
The first build downloads the `android-all` framework jar (~170 MB, Maven Central) and creates a signing key in `signing/` (git-ignored). **Keep that key**: an APK signed with another key cannot update an installed one. Set `CK_KEYSTORE` / `CK_KEYPASS` to use your own.

## Status
Built and structurally verified (manifest, resources, v1+v2+v3 signature, alignment, engine tests) but **never run on a phone or emulator** — there is no Android device here. First-run checklist:
1. Connect → status "Connected", ping shows, Log: `SSH connected`, `udpgw reachable`, `tunnel up`.
2. Browser: exit IP is the server's; a site that needs DNS loads.
3. UDP: DNS works with UDPGW on; a game / call; UDPGW off → DNS still works (TCP fallback).
4. Switch Wi-Fi ↔ mobile data: status "Reconnecting..." and recovery.
5. Wrong password → clear error; changed server key → refused.
6. On 32-bit phones (armeabi-v7a) and x86 emulators the engine is a static *linux* Go binary (android/arm and android/amd64 need cgo): if it fails to start the Log shows "Engine did not start".

## Limits
No QR scanner yet (paste/share/open links instead); no kill-switch of its own (use Android's *Always-on VPN* + *Block connections without VPN* in system settings); Google Play would require a newer target SDK than the sideload build uses (30).
