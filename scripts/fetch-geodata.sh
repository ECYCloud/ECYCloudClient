#!/usr/bin/env bash
# 按 kernel.lock.json 取 geodata 并落到指定目录（桌面端随内核分发，Android 进 APK assets）。
# 用法: fetch-geodata.sh <输出目录>
#
# 内核解析 GEOIP / GEOSITE 规则时会就地读这两个库，缺文件就按 geox-url 同步下载
# （mihomo component/geodata/init.go 的 InitGeoIP / InitGeoSite，每文件 90 秒超时），
# 面板下发的地址指向 GitHub，在目标网络里必然超时，整份配置随之校验失败、内核起不来。
set -euo pipefail

out_dir="${1:?用法: fetch-geodata.sh <输出目录>}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(dirname "$script_dir")"
lock="$script_dir/kernel.lock.json"
cache_dir="$root_dir/build/cache"
mkdir -p "$cache_dir" "$out_dir"

# 上游只有滚动的 latest tag、每天重发，锁不住 sha256（见 kernel.lock.json 的说明）。
# 这里只拦 404 页面与截断下载：体积下限 + MMDB 尾部的 MaxMind 元数据魔数；
# 内容合法性由内核运行时的 mmdb.Verify / geodata.Verify 兜底。
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
