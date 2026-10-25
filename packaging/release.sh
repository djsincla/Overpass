#!/bin/zsh
# Builds, signs, notarises and publishes a Mac release of Overpass.
#
#   packaging/release.sh             build, notarise, tag, and create a draft GitHub release
#   packaging/release.sh --publish   the same, but publish the release straight away
#   packaging/release.sh --dry-run   build and sign the disk image only: no notarising, tag or release
#
# Before running it:
#   1. Bump MARKETING_VERSION (and CURRENT_PROJECT_VERSION) in project.yml, and commit.
#   2. Write the release notes in packaging/release-notes/<version>.md, and commit.
#   3. Store notarisation credentials once per Mac (an app-specific password from account.apple.com):
#        xcrun notarytool store-credentials overpass-notary --apple-id <apple id> --team-id HG979YFABK
#
# It refuses to reuse a version that already has a tag, so nothing is ever force-pushed. The
# output goes to build/release/<version>.

set -euo pipefail

TEAM_ID="HG979YFABK"
SIGNING_IDENTITY="Developer ID Application: Dwayne Sinclair (${TEAM_ID})"
NOTARY_PROFILE="${NOTARY_PROFILE:-overpass-notary}"
REPO="djsincla/Overpass"

mode="draft"
case "${1:-}" in
  --publish) mode="publish" ;;
  --dry-run) mode="dry-run" ;;
  "") ;;
  *) echo "Usage: $0 [--publish | --dry-run]" >&2; exit 2 ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

step() { print -P "\n%F{cyan}==> $1%f"; }
fail() { print -P "%F{red}error:%f $1" >&2; exit 1; }

version="$(awk '/^ *MARKETING_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' project.yml)"
build="$(awk '/^ *CURRENT_PROJECT_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' project.yml)"
[[ -n "$version" && -n "$build" ]] || fail "couldn't read MARKETING_VERSION and CURRENT_PROJECT_VERSION from project.yml"
tag="v${version}"
notes="packaging/release-notes/${version}.md"
out="build/release/${version}"
dmg="${out}/Overpass-${version}.dmg"

step "Overpass ${version} (${build}), ${mode}"

# Checks that are cheap to make before twenty minutes of building.
if [[ "$mode" != "dry-run" ]]; then
  [[ -z "$(git status --porcelain)" ]] || fail "the working tree has uncommitted changes; commit them so the release matches its tag"
  [[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || fail "releases are made from main"
  git fetch -q origin main --tags
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main isn't the same as origin/main; push or pull first"
  if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null || git ls-remote --exit-code origin "refs/tags/${tag}" >/dev/null 2>&1; then
    fail "${tag} already exists; bump MARKETING_VERSION in project.yml for a new release"
  fi
  [[ -f "$notes" ]] || fail "no release notes: write ${notes} first"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "no notarytool credentials under '${NOTARY_PROFILE}'; see the top of this script"
  gh auth status >/dev/null 2>&1 || fail "gh isn't logged in"
fi
security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY" || fail "no '${SIGNING_IDENTITY}' certificate in the keychain"

step "Tests"
swift test 2>&1 | tail -1

step "Archive"
rm -rf "$out" && mkdir -p "$out"
xcodegen -q
xcodebuild -project Overpass.xcodeproj -scheme Overpass -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "${out}/Overpass.xcarchive" \
  -allowProvisioningUpdates archive -quiet

step "Export with Developer ID"
cat > "${out}/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>destination</key><string>export</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "${out}/Overpass.xcarchive" -exportPath "${out}/export" \
  -exportOptionsPlist "${out}/ExportOptions.plist" -allowProvisioningUpdates -quiet
app="${out}/export/Overpass.app"
codesign --verify --deep --strict "$app" || fail "the exported app's signature doesn't verify"
# (Captured first: grep -q closing the pipe early would trip pipefail.)
signature="$(codesign -dv "$app" 2>&1)"
[[ "$signature" == *"flags=0x10000(runtime)"* ]] || fail "the hardened runtime is off; notarisation would reject it"
built="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${app}/Contents/Info.plist")"
[[ "$built" == "$version" ]] || fail "the app says ${built}, project.yml says ${version}"

step "Disk image"
staging="${out}/dmg"
mkdir -p "$staging"
cp -R "$app" "$staging/"
ln -s /Applications "${staging}/Applications"
hdiutil create -quiet -volname "Overpass ${version}" -srcfolder "$staging" -fs HFS+ -format UDZO "$dmg"
codesign --sign "$SIGNING_IDENTITY" --timestamp "$dmg"
rm -rf "$staging"

if [[ "$mode" == "dry-run" ]]; then
  step "Dry run finished"
  echo "Signed but not notarised: ${dmg}"
  exit 0
fi

step "Notarise (this takes a few minutes)"
xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait | tee "${out}/notarytool.log"
grep -q "status: Accepted" "${out}/notarytool.log" \
  || fail "Apple didn't accept it; run 'xcrun notarytool log <id> --keychain-profile ${NOTARY_PROFILE}' for the reasons"
xcrun stapler staple "$dmg"

step "Check it the way Gatekeeper will"
spctl -a -t open --context context:primary-signature "$dmg"
mount="$(hdiutil attach -nobrowse -readonly "$dmg" | tail -1 | awk -F'\t' '{print $NF}')"
spctl -a -t exec "${mount}/Overpass.app" || { hdiutil detach -quiet "$mount"; fail "Gatekeeper rejects the app"; }
hdiutil detach -quiet "$mount"
sha="$(shasum -a 256 "$dmg" | cut -d' ' -f1)"
echo "SHA-256 ${sha}"

step "Tag ${tag} and create the GitHub release"
git tag -a "$tag" -m "Overpass ${version}"
git push -q origin "$tag"
draft=(--draft)
[[ "$mode" == "publish" ]] && draft=(--latest)
# Also as Overpass.dmg, so releases/latest/download/Overpass.dmg always fetches the newest one
# (the website and README link to that).
cp "$dmg" "${out}/Overpass.dmg"
gh release create "$tag" "$dmg" "${out}/Overpass.dmg" -R "$REPO" "${draft[@]}" --title "Overpass ${version}" --notes-file "$notes"

step "Done"
if [[ "$mode" == "publish" ]]; then
  echo "Published: https://github.com/${REPO}/releases/tag/${tag}"
else
  echo "Draft created; publish it with: gh release edit ${tag} -R ${REPO} --draft=false --latest"
fi
