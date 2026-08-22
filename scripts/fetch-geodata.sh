#!/usr/bin/env bash
# 按 kernel.lock.json 取 geodata 并落到指定目录。
# 用法: fetch-geodata.sh <输出目录>
# 缺文件时内核按 geox-url 同步下载（每文件 90 秒），面板地址在目标网络不可达。
set -euo pipefail

out_dir="${1:?用法: fetch-geodata.sh <输出目录>}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(dirname "$script_dir")"
lock="$script_dir/kernel.lock.json"
cache_dir="$root_dir/build/cache"
mkdir -p "$cache_dir" "$out_dir"

# 上游滚动 latest、锁不住 sha256；只拦 404 与截断（体积下限 + MaxMind 魔数）
for name in mmdb geosite; do
    url="$(jq -er --arg n "$name" '.geodata.assets[$n].url' "$lock")"
    target="$(jq -er --arg n "$name" '.geodata.assets[$n].target' "$lock")"
    min="$(jq -er --arg n "$name" '.geodata.assets[$n].minBytes' "$lock")"
    file="$cache_dir/$target"

    if [[ ! -f "$file" ]]; then
        echo "下载 $url"
        curl -fsSL -o "$file" "$url"
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
