#!/usr/bin/env bash
# 按 kernel.lock.json 下载并校验 sing-box 官方发布包（macOS / Linux）。
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
url="$(jq -er --arg k "$key" '.singBox.assets[$k].url' "$lock")"
want="$(jq -er --arg k "$key" '.singBox.assets[$k].sha256' "$lock")"
root="$(jq -er --arg k "$key" '.singBox.assets[$k].root' "$lock")"

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

extract_dir="$cache_dir/$root"
rm -rf "$extract_dir"
mkdir -p "$extract_dir"
tar -xzf "$archive" -C "$cache_dir"

install -m 0755 "$extract_dir/sing-box" "$out_dir/sing-box"
install -m 0644 "$extract_dir/LICENSE" "$out_dir/LICENSE.sing-box.txt"

echo "sing-box $(jq -r '.singBox.version' "$lock") 已就绪：$out_dir"
