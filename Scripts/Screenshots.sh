#!/bin/bash
# Simulator-only public favorites for a reproducible visual check; no credentials.
set -euxo pipefail
xcodebuild -project Forge.xcodeproj -scheme Forge -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build-simulator \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "$RUNNER_TEMP/simulator-build.log" | xcbeautify
runtime=$(python3 - <<'PY'
import json, subprocess
# Fail promptly when CoreSimulator discovery stalls on a hosted runner.
result = subprocess.run(['xcrun', 'simctl', 'list', 'runtimes', '-j'],
                        check=True, capture_output=True, text=True, timeout=120)
print(next(r['identifier'] for r in json.loads(result.stdout)['runtimes']
           if r['isAvailable'] and r['name'].startswith('iOS 26')))
PY
)
device=$(xcrun simctl create 'Forge visual check' com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro "$runtime")
trap 'xcrun simctl shutdown "$device" || true' EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
xcrun simctl status_bar "$device" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
xcrun simctl install "$device" build-simulator/Build/Products/Debug-iphonesimulator/Forge.app
data_dir=$(xcrun simctl get_app_container "$device" app.forge.github data)
python3 - "$data_dir" <<'PY'
import pathlib, plistlib, sys
prefs = pathlib.Path(sys.argv[1]) / 'Library/Preferences/app.forge.github.plist'
prefs.parent.mkdir(parents=True, exist_ok=True)
prefs.write_bytes(plistlib.dumps({'repositories': ['github/roadmap', 'swiftlang/swift', 'cli/cli', 'actions/runner']}))
PY
mkdir -p dist/screenshots
xcrun simctl ui "$device" appearance light
xcrun simctl launch "$device" app.forge.github
sleep 12
xcrun simctl io "$device" screenshot dist/screenshots/home-light.png
xcrun simctl ui "$device" appearance dark
sleep 2
xcrun simctl io "$device" screenshot dist/screenshots/home-dark.png
xcrun simctl terminate "$device" app.forge.github
xcrun simctl ui "$device" appearance light
xcrun simctl launch "$device" app.forge.github --forge-preview-url https://github.com/cli/cli/issues/14512
sleep 10
xcrun simctl io "$device" screenshot dist/screenshots/native-issue.png
