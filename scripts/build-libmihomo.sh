#!/usr/bin/env bash
# 构建 Android 侧的 libmihomo.aar。
# 用法: build-libmihomo.sh
# 依赖：Go、JDK 17、Android SDK（含 NDK），ANDROID_HOME 与 ANDROID_NDK_HOME 需已就绪。
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(dirname "$script_dir")"
lock="$script_dir/kernel.lock.json"
mod_dir="$root_dir/native/android/mihomo"
libs_dir="$root_dir/app/android/app/libs"

tag="$(jq -er '.mihomo.tag' "$lock")"

cd "$mod_dir"

# 内核版本必须与桌面端锁的是同一个 tag，否则两端跑在不同内核上，问题无从复现
locked="$(go list -m -f '{{.Version}}' github.com/metacubex/mihomo)"
if [[ "$locked" != "$tag" ]]; then
    echo "go.mod 锁的内核是 $locked，kernel.lock.json 是 $tag，先对齐再构建" >&2
    exit 1
fi

# gomobile / gobind 用 go.mod 里锁的那个版本，不取 @latest，避免每次构建结果不同
export GOBIN="$root_dir/build/gobin"
mkdir -p "$GOBIN"
go install golang.org/x/mobile/cmd/gomobile golang.org/x/mobile/cmd/gobind
export PATH="$GOBIN:$PATH"

# ABI 对齐 build-android.sh；androidapi 对齐 minSdk。
# 必须带 with_gvisor（否则 mixed 栈只编进 stub）和 cmfa（否则走 packages.xml 解析 uid，
# ReCreateTun 吞掉失败、流量进黑洞）。ldflags 与官方 Makefile 一样注入版本号。
mkdir -p "$libs_dir"
gomobile bind \
    -target=android/arm64,android/arm,android/amd64 \
    -androidapi 24 \
    -javapkg com.ecycloud \
    -tags with_gvisor,cmfa \
    -trimpath \
    -ldflags "-s -w -X github.com/metacubex/mihomo/constant.Version=$tag" \
    -o "$libs_dir/libmihomo.aar" \
    .

# 这里能直接取到内核源码，许可证就从源码带出，不靠「与本项目同为 GPL-3.0」的假设
install -m 0644 "$(go list -m -f '{{.Dir}}' github.com/metacubex/mihomo)/LICENSE" \
    "$libs_dir/LICENSE.mihomo.txt"

echo "libmihomo.aar（mihomo $tag）已就绪：$libs_dir/libmihomo.aar"
