#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source macOS/compiler-flags.sh
icon_source=macOS/Resources/ClipNestIcon.png
icon_set_dir=.work/macos/ClipNest.iconset
app_resources=artifacts/macos/ClipNest.app/Contents/Resources
if [[ ! -f "$icon_source" ]]; then
    echo "缺少应用图标：$icon_source" >&2
    exit 1
fi
mkdir -p .work/macos/module-cache artifacts/macos/ClipNest.app/Contents/MacOS "$icon_set_dir" "$app_resources"
for arch in arm64 x86_64; do
    xcrun swiftc "${swift_flags[@]}" "${release_flags[@]}" -target "$arch-apple-macos13.0" -Xlinker -dead_strip macOS/Sources/{Core/,}*.swift -o ".work/macos/ClipNest-$arch"
    xcrun strip -S -x ".work/macos/ClipNest-$arch"
done
xcrun lipo -create .work/macos/ClipNest-arm64 .work/macos/ClipNest-x86_64 -output artifacts/macos/ClipNest.app/Contents/MacOS/ClipNest
cp macOS/Info.plist artifacts/macos/ClipNest.app/Contents/Info.plist
cp -R macOS/Resources/*.lproj "$app_resources/"
for icon_size in 16 32 128 256 512; do
    sips -z "$icon_size" "$icon_size" "$icon_source" --out "$icon_set_dir/icon_${icon_size}x${icon_size}.png" >/dev/null
    icon_retina_size=$((icon_size * 2))
    sips -z "$icon_retina_size" "$icon_retina_size" "$icon_source" --out "$icon_set_dir/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_set_dir" -o "$app_resources/ClipNest.icns"
identifier=$(plutil -extract CFBundleIdentifier raw artifacts/macos/ClipNest.app/Contents/Info.plist)
codesign --force --sign "${CODESIGN_IDENTITY:--}" --identifier "$identifier" artifacts/macos/ClipNest.app
codesign --verify --strict --verbose=2 artifacts/macos/ClipNest.app
ditto -c -k --keepParent artifacts/macos/ClipNest.app artifacts/macos/ClipNest-macOS-universal.zip
file artifacts/macos/ClipNest.app/Contents/MacOS/ClipNest
