#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source macOS/compiler-flags.sh
bash macOS/check-strings.sh
bash macOS/check-docs.sh
# 原生脚本把 Core 与应用编成一个模块，SwiftPM 分成两个模块；两边都编译并运行核心测试，避免访问级别或纯逻辑回归。
swift build --scratch-path .work/swiftpm
swift test --scratch-path .work/swiftpm
mkdir -p .work/macos/module-cache
sources=()
for file in macOS/Sources/{Core/,}*.swift; do
    if [[ "$file" != macOS/Sources/main.swift ]]; then
        sources+=("$file")
    fi
done
xcrun swiftc "${swift_flags[@]}" "${debug_flags[@]}" "${sources[@]}" "$PWD"/macOS/Tests/*.swift -o .work/macos/ClipNestTests
.work/macos/ClipNestTests
