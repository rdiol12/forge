#!/bin/bash
# Simulator layout checks and a live download using an ephemeral CI read token.
set -euxo pipefail
xcodebuild -project Forge.xcodeproj -scheme Forge -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build-simulator \
  CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" build 2>&1 | tee "$RUNNER_TEMP/simulator-build.log" | xcbeautify
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
trap 'if [[ -n "${data_dir:-}" ]]; then rm -f "$data_dir/tmp/download-check-token"; fi; xcrun simctl shutdown "$device" || true' EXIT
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
set +x
umask 077
printf '%s' "${GH_TOKEN:?A temporary read token is required for the download check}" > "$data_dir/tmp/download-check-token"
set -x
xcrun simctl launch "$device" app.forge.github --forge-check-downloads
python3 - "$data_dir/Documents/download-check.json" <<'PY'
import pathlib, shutil, sys, time
source = pathlib.Path(sys.argv[1])
for _ in range(210):
    if source.exists():
        shutil.copyfile(source, 'dist/download-check.json')
        break
    time.sleep(1)
else:
    raise SystemExit('iPhone download check timed out')
PY
xcrun simctl io "$device" screenshot dist/screenshots/download-check.png
python3 - <<'PY'
import json, pathlib
result = json.loads(pathlib.Path('dist/download-check.json').read_text())
print(result)
assert result['status'] == 'passed', 'iPhone download check failed'
PY
xcrun simctl terminate "$device" app.forge.github
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
for preview in 'native-repository https://github.com/actions/setup-node' 'native-profile https://github.com/octocat' 'native-following https://github.com/octocat?tab=following' 'native-repositories https://github.com/octocat?tab=repositories' 'native-actions https://github.com/actions/setup-node/actions'; do
  read -r name url <<< "$preview"
  xcrun simctl terminate "$device" app.forge.github
  xcrun simctl launch "$device" app.forge.github --forge-preview-url "$url"
  sleep 8
  xcrun simctl io "$device" screenshot "dist/screenshots/$name.png"
done
mkdir -p "$data_dir/Documents"
cp Sources/ForgeCore/Models.swift "$data_dir/Documents/Preview.swift"
xcrun simctl terminate "$device" app.forge.github
xcrun simctl launch "$device" app.forge.github --forge-preview-code "$data_dir/Documents/Preview.swift"
sleep 3
xcrun simctl io "$device" screenshot dist/screenshots/code-light.png
xcrun simctl ui "$device" appearance dark
sleep 2
xcrun simctl io "$device" screenshot dist/screenshots/code-dark.png
xcrun simctl terminate "$device" app.forge.github
xcrun simctl ui "$device" appearance light
xcrun simctl launch "$device" app.forge.github --forge-preview-readme
sleep 8
xcrun simctl io "$device" screenshot dist/screenshots/readme-light.png
xcrun simctl ui "$device" appearance dark
sleep 2
xcrun simctl io "$device" screenshot dist/screenshots/readme-dark.png
