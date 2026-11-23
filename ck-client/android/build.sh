#!/bin/bash
# Builds CK-Client.apk (universal: arm64-v8a, armeabi-v7a, x86_64) without Gradle / Android Studio.
# Needs: Go 1.24+, JDK 11+, and the Android build tools  aapt, dx, zipalign, apksigner
#   Debian/Ubuntu:  apt install aapt apksigner zipalign dalvik-exchange
# The framework classes/resources come from the "android-all" jar (Maven Central), downloaded once to ~/.cache/ckclient.
# Signing key: $CK_KEYSTORE (default android/signing/ck.jks, generated on first build - KEEP IT: updates must use the same key).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
BT=/usr/lib/android-sdk/build-tools/debian
for t in aapt dx zipalign apksigner; do
  command -v "$t" >/dev/null 2>&1 || { [ -x "$BT/$t" ] && export PATH="$BT:$PATH"; }
  command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t (apt install aapt apksigner zipalign dalvik-exchange)"; exit 1; }
done
ALL_VER=13-robolectric-9030017
ANDROID_JAR="${ANDROID_JAR:-$HOME/.cache/ckclient/android-all-$ALL_VER.jar}"
if [ ! -f "$ANDROID_JAR" ]; then
  mkdir -p "$(dirname "$ANDROID_JAR")"
  echo "downloading android-all ($ALL_VER, ~170 MB, once)..."
  curl -fL -o "$ANDROID_JAR" "https://repo.maven.apache.org/maven2/org/robolectric/android-all/$ALL_VER/android-all-$ALL_VER.jar"
fi

VERSION_CODE="${VERSION_CODE:-2}"; VERSION_NAME="${VERSION_NAME:-1.0.1}"
B="$ROOT/build"; rm -rf "$B"; mkdir -p "$B/gen" "$B/classes" "$B/lib/arm64-v8a" "$B/lib/armeabi-v7a" "$B/lib/x86_64"

echo "== engine (Go)"
( cd "$ROOT/.." && go test -count=1 ./ckcore )
build_engine() { # abi goos goarch [goarm]
  ( cd "$ROOT/.." && GOOS=$2 GOARCH=$3 GOARM=${4:-} CGO_ENABLED=0 \
      go build -trimpath -ldflags="-s -w" -o "$B/lib/$1/libckengine.so" ./cmd/ckengine )
}
build_engine arm64-v8a   android arm64
build_engine armeabi-v7a linux   arm 7      # static linux binary: android/arm needs cgo+NDK, linux/arm does not
build_engine x86_64      linux   amd64

echo "== resources"
aapt package -f -M AndroidManifest.xml -S res -I "$ANDROID_JAR" -J "$B/gen" -F "$B/res.apk" \
  --min-sdk-version 21 --target-sdk-version 30 --version-code "$VERSION_CODE" --version-name "$VERSION_NAME" --auto-add-overlay

echo "== java"
find src "$B/gen" -name '*.java' > "$B/sources.txt"
javac -nowarn --release 8 -classpath "$ANDROID_JAR" -d "$B/classes" @"$B/sources.txt"

echo "== dex"
dx --dex --min-sdk-version=21 --output="$B/classes.dex" "$B/classes"

echo "== package"
cp "$B/res.apk" "$B/unsigned.apk"
( cd "$B" && aapt add unsigned.apk classes.dex >/dev/null \
  && aapt add unsigned.apk lib/arm64-v8a/libckengine.so lib/armeabi-v7a/libckengine.so lib/x86_64/libckengine.so >/dev/null )
zipalign -f -p 4 "$B/unsigned.apk" "$B/aligned.apk"

echo "== sign"
KS="${CK_KEYSTORE:-$ROOT/signing/ck.jks}"
PASS="${CK_KEYPASS:-}"
if [ ! -f "$KS" ]; then
  mkdir -p "$(dirname "$KS")"
  PASS="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
  keytool -genkeypair -keystore "$KS" -alias ckclient -keyalg RSA -keysize 3072 -validity 36500 \
    -storepass "$PASS" -keypass "$PASS" -dname "CN=CK Client, O=CK Producer" >/dev/null 2>&1
  echo "$PASS" > "$(dirname "$KS")/ck.pass"; chmod 600 "$KS" "$(dirname "$KS")/ck.pass"
  echo "created a new signing key: $KS  (keep it safe: later updates must be signed with the same key)"
fi
[ -n "$PASS" ] || PASS="$(cat "$(dirname "$KS")/ck.pass")"
mkdir -p "$ROOT/../dist"
OUT="$ROOT/../dist/CK-Client.apk"
apksigner sign --ks "$KS" --ks-key-alias ckclient --ks-pass "pass:$PASS" --key-pass "pass:$PASS" \
  --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true --out "$OUT" "$B/aligned.apk"
apksigner verify --verbose "$OUT" | head -6
echo "built: $OUT ($(du -h "$OUT" | cut -f1))"
