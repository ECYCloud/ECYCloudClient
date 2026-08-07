#!/usr/bin/env bash
# 构建 macOS / Linux 特权 helper。
# 用法: build-helper.sh <macos|linux> <x64|arm64>
set -euo pipefail

platform="${1:?用法: build-helper.sh <macos|linux> <x64|arm64>}"
arch="${2:?用法: build-helper.sh <macos|linux> <x64|arm64>}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(dirname "$script_dir")"
source_dir="$root_dir/native/unix/helper"
out_dir="$root_dir/build/deps/$platform-$arch"
mkdir -p "$out_dir"

case "$platform" in
    macos) export GOOS=darwin ;;
    linux) export GOOS=linux ;;
    *) echo "未知平台 $platform" >&2; exit 1 ;;
esac
case "$arch" in
    x64) export GOARCH=amd64 ;;
    arm64) export GOARCH=arm64 ;;
    *) echo "未知架构 $arch" >&2; exit 1 ;;
esac
export CGO_ENABLED=0

cd "$source_dir"
go vet ./...
go build -trimpath -ldflags '-s -w' -o "$out_dir/ecycloud-helper" .

echo "特权服务已构建：$out_dir/ecycloud-helper"
