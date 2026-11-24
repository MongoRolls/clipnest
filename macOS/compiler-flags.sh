sdk_version=$(xcrun --sdk macosx --show-sdk-version)
if [[ ${sdk_version%%.*} -lt 26 ]]; then
    echo "构建 ClipNest 需要 macOS 26 或更新的 SDK，当前版本为 $sdk_version。部署目标为 macOS 13。" >&2
    exit 1
fi
swift_flags=(-swift-version 5 -package-name ClipNest -warnings-as-errors -sdk "$(xcrun --sdk macosx --show-sdk-path)" -module-cache-path .work/macos/module-cache)
release_flags=(-Osize -whole-module-optimization)
debug_flags=(-Onone -g)
