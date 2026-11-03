#!/bin/zsh
# The App Store screenshots: runs ScreenshotTests on each simulator and exports the pictures
# to appstore/screenshots/<device>/. Usage: scripts/screenshots.sh [device name …]
set -e
cd "${0:A:h}/.."
devices=("$@")
(( $# )) || devices=("iPhone 17 Pro Max" "iPad Pro 13-inch (M5)")
work=$(mktemp -d)
for device in $devices; do
  xcrun simctl boot "$device" 2>/dev/null || true
  xcrun simctl bootstatus "$device" >/dev/null
  # A fresh start, in dark mode, so no earlier choices show.
  xcrun simctl uninstall "$device" com.dwaynesinclair.overpass
  xcrun simctl ui "$device" appearance dark
  # The status bar Apple uses in its own pictures.
  xcrun simctl status_bar "$device" override --time 9:41 --dataNetwork wifi --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
  result="$work/${device// /-}.xcresult"
  xcodebuild test -project Overpass.xcodeproj -scheme OverpassUITests \
    -destination "platform=iOS Simulator,name=$device" -only-testing:OverpassUITests/ScreenshotTests \
    -resultBundlePath "$result" -quiet || true
  out="appstore/screenshots/${device// /-}"
  rm -rf "$out" && mkdir -p "$out"
  xcrun xcresulttool export attachments --path "$result" --output-path "$work/raw"
  # The manifest maps each exported file to the name the test gave it.
  python3 -I - "$work/raw" "$out" <<'PY'
import json, shutil, sys, os
raw, out = sys.argv[1:]
for test in json.load(open(os.path.join(raw, "manifest.json"))):
    for item in test["attachments"]:
        name = item.get("suggestedHumanReadableName", item["exportedFileName"])
        name = name.split("_0_")[0].rsplit(".", 1)[0]
        # Only the pictures the test named; a failure adds its own attachments.
        if not name[:1].isdigit():
            continue
        shutil.copy(os.path.join(raw, item["exportedFileName"]), os.path.join(out, name + ".png"))
PY
  # The iPad's are taken in landscape and saved upright with a turn tag; App Store Connect
  # wants the pixels turned (2752 × 2064) and no tag.
  [[ $device == iPad* ]] && for f in "$out"/*.png; do sips -r 270 "$f" >/dev/null; done
  python3 -I scripts/strip-png-metadata.py "$out"/*.png
  rm -rf "$work/raw"
  echo "$out: $(ls "$out" | wc -l | tr -d ' ') pictures"
done
