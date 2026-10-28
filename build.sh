#!/bin/bash
# Builds build/SmoothDisplay.app as a universal (arm64 + x86_64) binary.
#
#   ./build.sh            development build
#   ./build.sh --install  also copies it to /Applications and starts it
#
# Signing: SIGN_IDENTITY if set, otherwise the first "Apple Development" certificate (a stable signature
# keeps the Accessibility permission across rebuilds), otherwise ad-hoc. RELEASE=1 adds the hardened
# runtime and a secure timestamp, which notarization requires; scripts/release.sh sets both.
set -euo pipefail
cd "$(dirname "$0")"

out=build
app="$out/SmoothDisplay.app"
rm -rf "$app" "$out/obj"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$out/obj"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" Sources/*.swift -o "$out/obj/SmoothDisplay-$arch"
done
lipo -create -output "$app/Contents/MacOS/SmoothDisplay" "$out/obj/SmoothDisplay-arm64" "$out/obj/SmoothDisplay-x86_64"

cp Info.plist "$app/Contents/Info.plist"
for lproj in Resources/*.lproj; do
  cp -R "$lproj" "$app/Contents/Resources/"
done

# Icon, drawn by a script so it can be changed without design tools.
if [ -f scripts/make-icon.swift ]; then
  swift scripts/make-icon.swift "$out/obj/icon.png"
  iconset="$out/obj/AppIcon.iconset"
  mkdir -p "$iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$out/obj/icon.png" --out "$iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$out/obj/icon.png" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns -o "$app/Contents/Resources/AppIcon.icns" "$iconset"
fi

# By SHA-1, so two certificates with the same name (old and renewed) are not "ambiguous".
identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/ { print $2; exit }' || true)}"
options=()
[ "${RELEASE:-0}" = 1 ] && options=(--options runtime --timestamp)
codesign --force --sign "${identity:--}" ${options[@]+"${options[@]}"} "$app"
echo "Built $app (signed with: ${identity:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x SmoothDisplay || true
  rm -rf /Applications/SmoothDisplay.app
  ditto "$app" /Applications/SmoothDisplay.app
  open /Applications/SmoothDisplay.app
  echo "Installed /Applications/SmoothDisplay.app"
fi
