#!/usr/bin/env bash
# 按 kernel.lock.json 下载并校验 mihomo 官方发布包（macOS / Linux）。
# 用法: fetch-kernel.sh <macos|linux> <x64|arm64>
set -euo pipefail

platform="${1:?用法: fetch-kernel.sh <macos|linux> <x64|arm64>}"
arch="${2:?用法: fetch-kernel.sh <macos|linux> <x64|arm64>}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(dirname "$script_dir")"
lock="$script_dir/kernel.lock.json"
cache_dir="$root_dir/build/cache"
out_dir="$root_dir/build/deps/$platform-$arch"
mkdir -p "$cache_dir" "$out_dir"

key="$platform-$arch"
url="$(jq -er --arg k "$key" '.mihomo.assets[$k].url' "$lock")"
want="$(jq -er --arg k "$key" '.mihomo.assets[$k].sha256' "$lock")"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

archive="$cache_dir/$(basename "$url")"
if [[ ! -f "$archive" ]]; then
    echo "下载 $url"
    curl -fsSL -o "$archive" "$url"
fi

got="$(sha256_of "$archive")"
if [[ "$got" != "$want" ]]; then
    rm -f "$archive"
    echo "校验失败：$url" >&2
    echo "  期望 $want" >&2
    echo "  实际 $got" >&2
    exit 1
fi
echo "校验通过 $(basename "$archive")"

# 官方 Unix 产物是单个 gzip 压缩的可执行文件，不是 tar 包
gzip -dc "$archive" > "$out_dir/mihomo"
chmod 0755 "$out_dir/mihomo"

# 发布包内不含 LICENSE，内核许可证与本项目同为逐字 GPL-3.0，直接复用仓库根的副本
install -m 0644 "$root_dir/LICENSE" "$out_dir/LICENSE.mihomo.txt"

"$script_dir/fetch-geodata.sh" "$out_dir"

echo "mihomo $(jq -r '.mihomo.version' "$lock") 已就绪：$out_dir"
