#!/usr/bin/env bash
# 按 kernel.lock.json 取 geodata 并落到指定目录。
# 用法: fetch-geodata.sh <输出目录>
# 缺文件时内核按 geox-url 同步下载（每文件 90 秒），面板地址在目标网络不可达。
set -euo pipefail

out_dir="${1:?用法: fetch-geodata.sh <输出目录>}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(dirname "$script_dir")"
lock="$script_dir/kernel.lock.json"
cache_dir="${ECYCLOUD_BUILD_DIR:-$root_dir/build}/cache"
mkdir -p "$cache_dir" "$out_dir"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# 上游滚动 latest、锁不住 sha256：按同一发布附带的 .sha256sum 核对，另拦体积异常与非 MaxMind 文件
for name in mmdb geosite; do
    url="$(jq -er --arg n "$name" '.geodata.assets[$n].url' "$lock")"
    target="$(jq -er --arg n "$name" '.geodata.assets[$n].target' "$lock")"
    min="$(jq -er --arg n "$name" '.geodata.assets[$n].minBytes' "$lock")"
    file="$cache_dir/$target"

    echo "下载 $url"
    curl -fsSL -o "$file" "$url"

    want="$(curl -fsSL "$url.sha256sum" | cut -d' ' -f1)"
    got="$(sha256_of "$file")"
    if [[ "$got" != "$want" ]]; then
        rm -f "$file"
        echo "geodata 与上游校验值不符：$url（上游每天重建 latest 发布，赶上重建时稍后重试）" >&2
        echo "  期望 $want" >&2
        echo "  实际 $got" >&2
        exit 1
    fi
    size="$(wc -c < "$file" | tr -d ' ')"
    if [[ "$size" -lt "$min" ]]; then
        rm -f "$file"
        echo "geodata 体积异常：${url}（实际 ${size} 字节，下限 ${min}）" >&2
        exit 1
    fi
    # MaxMind DB 规范把元数据段放在文件末 128 KiB 内，以 "MaxMind.com" 起头
    if [[ "$target" == *.metadb ]] && ! tail -c 131072 "$file" | grep -aq 'MaxMind.com'; then
        rm -f "$file"
        echo "不是有效的 MaxMind 数据库：${url}" >&2
        exit 1
    fi

    install -m 0644 "$file" "$out_dir/$target"
    echo "校验通过 ${target}（${size} 字节）"
done
