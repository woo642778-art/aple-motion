#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Native iOS framework packaging requires macOS and the iOS SDK.' >&2
  exit 2
fi
mkdir -p build/reports build/slices build/universal
exec > >(tee build/reports/framework-build.log) 2>&1

build_slice() {
  local sdk_name="$1" arch="$2" suffix="$3" platform="$4"
  local sdk target module_target base
  sdk="$(xcrun --sdk "$sdk_name" --show-sdk-path)"
  target="${arch}-apple-ios15.0${suffix}"
  module_target="${arch}-apple-ios${suffix}"
  base="$ROOT/build/slices/${sdk_name}-${arch}"
  mkdir -p "$base"
  for module in ApleTimingCore ApleTimingUI; do
    local fw="$base/${module}.framework"
    mkdir -p "$fw/Modules/${module}.swiftmodule"
    local sources=()
    while IFS= read -r source; do sources+=("$source"); done < <(find "Sources/$module" -name '*.swift' -type f | sort)
    if [[ ${#sources[@]} -eq 0 ]]; then echo "No source files for $module" >&2; exit 3; fi
    # macOS /bin/bash 3.2 treats an empty array as unset under set -u.
    # Foundation is required for every module, so keep this array nonempty.
    local extra=(-framework Foundation)
    if [[ "$module" == ApleTimingUI ]]; then
      extra+=(-F "$base" -framework ApleTimingCore -framework UIKit -framework CoreGraphics)
    fi
    echo "Building $module for $target"
    xcrun swiftc -swift-version 5 -O -emit-library -emit-module -enable-library-evolution \
      -module-name "$module" -target "$target" -sdk "$sdk" \
      -emit-module-path "$fw/Modules/${module}.swiftmodule/${module_target}.swiftmodule" \
      -emit-module-interface-path "$fw/Modules/${module}.swiftmodule/${module_target}.swiftinterface" \
      -Xlinker -install_name -Xlinker "@rpath/${module}.framework/${module}" \
      "${extra[@]}" "${sources[@]}" -o "$fw/$module"
    python3 - "$fw/Info.plist" "$module" "$platform" <<'PY'
import plistlib, sys
path, module, platform = sys.argv[1:]
with open(path, 'wb') as output:
    plistlib.dump({'CFBundleIdentifier': 'app.aplemotion.' + module.lower(),
                  'CFBundleName': module, 'CFBundleExecutable': module,
                  'CFBundlePackageType': 'FMWK', 'CFBundleShortVersionString': '0.1.0',
                  'CFBundleVersion': '1', 'MinimumOSVersion': '15.0',
                  'CFBundleSupportedPlatforms': [platform]}, output)
PY
    xcrun lipo -info "$fw/$module"
    xcrun otool -L "$fw/$module"
  done
}

build_slice iphoneos arm64 '' iPhoneOS
build_slice iphonesimulator arm64 '-simulator' iPhoneSimulator
build_slice iphonesimulator x86_64 '-simulator' iPhoneSimulator

for module in ApleTimingCore ApleTimingUI; do
  universal="$ROOT/build/universal/iphonesimulator/${module}.framework"
  rm -rf "$universal"
  mkdir -p "$(dirname "$universal")"
  cp -R "build/slices/iphonesimulator-arm64/${module}.framework" "$universal"
  cp -R "build/slices/iphonesimulator-x86_64/${module}.framework/Modules/." "$universal/Modules/"
  xcrun lipo -create "build/slices/iphonesimulator-arm64/${module}.framework/$module" \
    "build/slices/iphonesimulator-x86_64/${module}.framework/$module" -output "$universal/$module"
  rm -rf "build/${module}.xcframework"
  xcodebuild -create-xcframework \
    -framework "$ROOT/build/slices/iphoneos-arm64/${module}.framework" \
    -framework "$universal" -output "$ROOT/build/${module}.xcframework"
done

python3 - <<'PY'
import json, pathlib, subprocess
root = pathlib.Path('build')
artifacts = []
for module in ('ApleTimingCore', 'ApleTimingUI'):
    path = root / (module + '.xcframework')
    if not (path / 'Info.plist').is_file():
        raise RuntimeError('Missing framework manifest: ' + str(path))
    artifacts.append(str(path))
report = {'artifacts': artifacts, 'device_architectures': ['arm64'],
          'simulator_architectures': ['arm64', 'x86_64'], 'minimum_ios': '15.0',
          'commit': subprocess.check_output(['git','rev-parse','HEAD'], text=True).strip(),
          'signed': False, 'aple_host_integrated': False, 'physical_device_tested': False,
          'ipa_created': False}
(root / 'reports' / 'framework-build.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
PY
