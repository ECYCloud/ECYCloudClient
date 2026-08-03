#!/usr/bin/env bash
# 构建 Android 客户端：libbox.aar + 按 ABI 分包的 Flutter APK。
# 用法: build-android.sh [--version 1.0.1] [--build-number 1] [--panel-url https://面板域名] [--skip-libbox]
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(dirname "$script_dir")"
app_dir="$root_dir/app"
version='1.0.1'
build_number='1'
panel_url=''
skip_libbox=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) version="$2"; shift 2 ;;
        --build-number) build_number="$2"; shift 2 ;;
        --panel-url) panel_url="$2"; shift 2 ;;
        --skip-libbox) skip_libbox=1; shift ;;
        *) echo "未知参数 $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$panel_url" ]]; then
    panel_url="$(jq -er '.panelUrl' "$root_dir/config/panel.json")"
fi
if [[ ! "$panel_url" =~ ^https?:// ]]; then
    echo "面板地址不是合法的 http(s) 地址：$panel_url" >&2
    exit 1
fi

# 构建 libbox 要 JDK 17 + NDK，耗时以十分钟计；反复出包时可复用上一次的产物
if [[ "$skip_libbox" -eq 1 ]]; then
    if [[ ! -f "$app_dir/android/app/libs/libbox.aar" ]]; then
        echo "缺少 app/android/app/libs/libbox.aar，不能跳过 libbox 构建" >&2
        exit 1
    fi
else
    "$script_dir/build-libbox.sh"
fi

cd "$app_dir"
# 必须用 --split-per-abi：仅 --target-platform 不会裁掉 libbox.aar 里其它 ABI 的 .so
flutter build apk --release --split-per-abi \
    --build-name "$version" --build-number "$build_number" \
    --dart-define="ECYCLOUD_PANEL_URL=$panel_url" \
    --dart-define="ECYCLOUD_VERSION=$version"

out_dir="$root_dir/build/installer"
mkdir -p "$out_dir"
apk_dir="$app_dir/build/app/outputs/flutter-apk"
# Flutter ABI 目录名 → 发布后缀（与 AppUpdate.assetSuffix 对齐；不用关联数组以兼容 macOS bash 3）
for entry in 'arm64-v8a:arm64' 'armeabi-v7a:arm' 'x86_64:x64'; do
    abi="${entry%%:*}"
    suffix="${entry##*:}"
    src="$apk_dir/app-$abi-release.apk"
    if [[ ! -f "$src" ]]; then
        echo "未找到 Flutter 产物：$src" >&2
        exit 1
    fi
    dest="$out_dir/ECYCloud-$version-android-$suffix.apk"
    install -m 0644 "$src" "$dest"
    echo "安装包已生成：$dest"
done
