#!/usr/bin/env bash
# 构建 Android 侧的 libbox.aar。
# 官方不发布该产物，只能按 kernel.lock.json 锁定的 tag 取源码、用官方 Makefile 目标构建，不改一行内核代码。
# 依赖：Go、JDK 17、Android SDK（含 NDK），ANDROID_HOME 与 ANDROID_NDK_HOME 需已就绪。
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(dirname "$script_dir")"
lock="$script_dir/kernel.lock.json"
src_dir="$root_dir/build/kernel-src/sing-box"
libs_dir="$root_dir/app/android/app/libs"

tag="$(jq -er '.singBox.tag' "$lock")"

if [[ ! -d "$src_dir/.git" ]]; then
    rm -rf "$src_dir"
    mkdir -p "$(dirname "$src_dir")"
    git clone --depth 1 --branch "$tag" https://github.com/SagerNet/sing-box.git "$src_dir"
else
    git -C "$src_dir" fetch --depth 1 origin "refs/tags/$tag:refs/tags/$tag" --force
    git -C "$src_dir" checkout --force "$tag"
    git -C "$src_dir" clean -fdx
fi

cd "$src_dir"
make lib_install
make lib_android

mkdir -p "$libs_dir"
# minSdk 24 用不到 libbox-legacy.aar（API 21），只取主产物
install -m 0644 libbox.aar "$libs_dir/libbox.aar"
install -m 0644 LICENSE "$libs_dir/LICENSE.libbox.txt"

echo "libbox.aar（sing-box $tag）已就绪：$libs_dir/libbox.aar"
