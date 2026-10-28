#!/bin/bash
# Maintainers: builds a release DMG that opens on any Mac without Gatekeeper warnings.
# Signs with the team's "Developer ID Application" certificate, notarizes and staples both the app
# and the DMG. Needs, once per Mac:
#   - the Developer ID Application certificate with its private key in the login keychain;
#   - a notarytool keychain profile: xcrun notarytool store-credentials <name> --apple-id <id> --team-id <team>
# TEAM_ID and NOTARY_PROFILE override the defaults below. Output: build/SmoothDisplay-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

team=${TEAM_ID:-4598574GA4}
profile=${NOTARY_PROFILE:?set NOTARY_PROFILE to the name of your notarytool keychain profile}
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
out=build
app="$out/SmoothDisplay.app"
dmg="$out/SmoothDisplay-$version.dmg"

# SHA-1 of the identity avoids "ambiguous" errors when an old and a renewed certificate share a name.
identity=$(security find-identity -v -p codesigning |
  awk -v team="($team)\"" 'index($0, "\"Developer ID Application:") && index($0, team) { print $2; exit }')
[ -n "$identity" ] || { echo "error: no Developer ID Application certificate for team $team" >&2; exit 1; }
if ! err=$(xcrun notarytool history --keychain-profile "$profile" 2>&1 >/dev/null); then
  echo "error: notarytool profile '$profile' unusable: $err" >&2
  exit 1
fi

python3 scripts/strings.py
SIGN_IDENTITY="$identity" RELEASE=1 ./build.sh

json_field() { python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1" 2>/dev/null || true; }

# Decides on Apple's reported status, not the exit code, so a rejection still prints its log.
notarize() {
  local result id status
  result=$(xcrun notarytool submit "$1" --keychain-profile "$profile" --wait --timeout 30m --output-format json 2>&1) || true
  id=$(printf '%s' "$result" | json_field id)
  status=$(printf '%s' "$result" | json_field status)
  echo "notarization of $(basename "$1"): ${status:-failed} ${id:+($id)}"
  if [ "$status" != "Accepted" ]; then
    printf '%s\n' "$result" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true
    exit 1
  fi
}

# The ticket can take a moment to propagate after "Accepted".
staple() {
  for attempt in 1 2 3 4 5; do
    if xcrun stapler staple "$1"; then
      xcrun stapler validate "$1"
      return
    fi
    echo "staple retry $attempt" >&2
    sleep 20
  done
  return 1
}

# Staple the app too, so a copy dragged out of the DMG passes Gatekeeper even offline.
ditto -c -k --keepParent "$app" "$out/SmoothDisplay-notarize.zip"
notarize "$out/SmoothDisplay-notarize.zip"
staple "$app"
rm -f "$out/SmoothDisplay-notarize.zip"

stage="$out/dmg"
rm -rf "$stage" "$dmg"
mkdir -p "$stage"
ditto "$app" "$stage/SmoothDisplay.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "SmoothDisplay $version" -srcfolder "$stage" -ov -format UDZO "$dmg"
codesign --force --sign "$identity" --timestamp -i agency.rivo.SmoothDisplay.dmg "$dmg"
notarize "$dmg"
staple "$dmg"
rm -rf "$stage"

spctl -a -vv -t exec "$app"
spctl -a -vv -t open --context context:primary-signature "$dmg"
shasum -a 256 "$dmg" | tee "$dmg.sha256"
echo "Release ready: $dmg"
