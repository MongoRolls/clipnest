#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

installed=/Applications/ClipNest.app
built=artifacts/macos/ClipNest.app
install_dir=.work/macos/installs
mkdir -p "$install_dir"
exec 9>>"$install_dir/install.lock"
/usr/bin/lockf -t 0 9 || { echo '另一次本机安装正在进行，无法取得安装锁。' >&2; exit 1; }
session=$(mktemp -d "$install_dir/install-XXXXXXXX")
candidate="$session/new/ClipNest.app"
previous="$session/previous/ClipNest.app"
mkdir "$session/new" "$session/previous"
identifier=$(plutil -extract CFBundleIdentifier raw macOS/Info.plist)

# 按证书指纹选择签名身份，避免同名的新旧证书影响钥匙串和系统权限。
requirement=''
if [[ -e "$installed" || -L "$installed" ]]; then
    if [[ -L "$installed" || $(plutil -extract CFBundleIdentifier raw "$installed/Contents/Info.plist") != "$identifier" ]]; then
        echo "安装位置已有其他应用或符号链接：$installed" >&2
        exit 1
    fi
    codesign --verify --strict --all-architectures "$installed"
    signature=$(codesign -d --verbose=2 "$installed" 2>&1)
    if [[ "$signature" == *'Signature=adhoc'* ]]; then
        export CODESIGN_IDENTITY=-
    else
        codesign -d --extract-certificates="$session/cert-" "$installed"
        identity=$(shasum -a 1 "$session/cert-0" | awk '{ print toupper($1) }')
        export CODESIGN_IDENTITY="$identity"
        requirement=$(codesign -d -r- "$installed" 2>&1 | sed -n 's/^designated => //p')
        [[ -n "$requirement" ]] || { echo '无法取得已安装应用的签名要求。' >&2; exit 1; }
    fi
fi

bash macOS/build.sh
ditto "$built" "$candidate"
if [[ -n "$requirement" ]]; then
    codesign --verify --strict --all-architectures -R "=$requirement" "$candidate"
else
    codesign --verify --strict --all-architectures "$candidate"
fi

# 只操作安装目录中的实例，让应用有机会完成正在进行的保存。
app_state() {
    /usr/bin/osascript -l JavaScript - "$identifier" "$installed" "$1" <<'JXA'
ObjC.import('AppKit')
function run([identifier, path, action]) {
    const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(identifier)
    for (let i = 0; i < apps.count; i++) {
        const app = apps.objectAtIndex(i)
        if (ObjC.unwrap(app.bundleURL.path) !== path || app.terminated) continue
        if (action === 'quit' && !app.terminate && !app.terminated)
            throw Error('ClipNest 拒绝了正常退出请求')
        return app.finishedLaunching ? 'ready' : 'starting'
    }
    return 'stopped'
}
JXA
}

wait_for_state() {
    local target=$1 state attempt
    for ((attempt=0; attempt<60; attempt++)); do
        state=$(app_state status) || return 1
        [[ "$state" != "$target" ]] || return 0
        sleep 0.2
    done
    echo "等待 ClipNest 状态 $target 超时，当前状态为 $state。" >&2
    return 1
}

was_running=$(app_state status)
if [[ "$was_running" != stopped ]]; then
    app_state quit >/dev/null
    wait_for_state stopped
fi

old_saved=0
install_started=0
restore_on_failure() {
    local result=$?
    trap - EXIT
    if (( result != 0 )); then
        echo "本机安装未完成，工作目录：$session" >&2
        if (( install_started )) && [[ -e "$installed" ]]; then
            app_state quit >/dev/null && wait_for_state stopped || exit "$result"
            mv "$installed" "$session/failed.app" || exit "$result"
        fi
        if (( old_saved )); then mv "$previous" "$installed" || exit "$result"; fi
        if [[ "$was_running" != stopped && -d "$installed" ]]; then open -g "$installed"; fi
    fi
    exit "$result"
}
trap restore_on_failure EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -d "$installed" ]]; then
    mv "$installed" "$previous"
    old_saved=1
fi
install_started=1
mv "$candidate" "$installed"
open -g "$installed"
wait_for_state ready
trap - EXIT INT TERM
echo "已启动：$installed"
if (( old_saved )); then echo "上一个版本：$PWD/$previous"; fi
