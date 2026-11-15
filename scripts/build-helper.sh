#!/usr/bin/env bash
# 构建 macOS / Linux 特权 helper。
# 用法: build-helper.sh <macos|linux> <x64|arm64>
set -euo pipefail

platform="${1:?用法: build-helper.sh <macos|linux> <x64|arm64>}"
arch="${2:?用法: build-helper.sh <macos|linux> <x64|arm64>}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(dirname "$script_dir")"
source_dir="$root_dir/native/unix/helper"
out_dir="${ECYCLOUD_BUILD_DIR:-$root_dir/build}/deps/$platform-$arch"
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
# macOS 按审计令牌核对调用方代码签名要链接 Security 框架，只能走 cgo；
# 最低系统须与 Go 工具链自身一致（Go 1.27 为 13.0），否则 clang 会按本机 SDK 版本写入最低系统
if [[ "$platform" == macos ]]; then
    export CGO_ENABLED=1
    export CC="xcrun clang -arch $([[ "$GOARCH" == amd64 ]] && echo x86_64 || echo arm64)"
    export CGO_CFLAGS="-mmacosx-version-min=13.0"
    export CGO_LDFLAGS="-mmacosx-version-min=13.0"
else
    export CGO_ENABLED=0
fi

cd "$source_dir"
go vet ./...
go build -trimpath -ldflags '-s -w' -o "$out_dir/ecycloud-helper" .

echo "特权服务已构建：$out_dir/ecycloud-helper"
