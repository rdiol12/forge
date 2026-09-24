#!/bin/bash
# Live simulator downloads using an ephemeral CI read token.
set -euxo pipefail
xcodebuild -project Forge.xcodeproj -scheme Forge -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build-simulator \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" build 2>&1 | tee "$RUNNER_TEMP/simulator-build.log" | xcbeautify
runtime=$(python3 - <<'PY'
import json, subprocess
# Fail promptly when CoreSimulator discovery stalls on a hosted runner.
result = subprocess.run(['xcrun', 'simctl', 'list', 'runtimes', '-j'],
                        check=True, capture_output=True, text=True, timeout=120)
print(next(r['identifier'] for r in json.loads(result.stdout)['runtimes']
           if r['isAvailable'] and r['name'].startswith('iOS 26')))
PY
)
device=$(xcrun simctl create 'Forge download check' com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro "$runtime")
trap 'if [[ -n "${data_dir:-}" ]]; then rm -f "$data_dir/tmp/download-check-token"; fi; xcrun simctl shutdown "$device" || true' EXIT
xcrun simctl boot "$device"
python3 - "$device" <<'PY'
import subprocess, sys
device = sys.argv[1]
try:
    subprocess.run(['xcrun', 'simctl', 'bootstatus', device, '-b'], check=True, timeout=150)
except subprocess.TimeoutExpired:
    print('Simulator boot stalled; restarting this test device once.', flush=True)
    subprocess.run(['xcrun', 'simctl', 'shutdown', device], check=True, timeout=30)
    subprocess.run(['xcrun', 'simctl', 'boot', device], check=True, timeout=30)
    subprocess.run(['xcrun', 'simctl', 'bootstatus', device, '-b'], check=True, timeout=150)
PY
xcrun simctl install "$device" build-simulator/Build/Products/Debug-iphonesimulator/Forge.app
data_dir=$(xcrun simctl get_app_container "$device" app.forge.github data)
mkdir -p dist
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
python3 - <<'PY'
import json, pathlib
result = json.loads(pathlib.Path('dist/download-check.json').read_text())
print(result)
assert result['status'] == 'passed', 'iPhone download check failed'
PY
xcrun simctl terminate "$device" app.forge.github
