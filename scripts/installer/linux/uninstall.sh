#!/bin/sh
# 停服务、拆 TUN，再删程序文件。终端下会询问是否删除数据。
set -e

purge=''
for arg in "$@"; do
    case "$arg" in
        --purge|-p) purge=1 ;;
        --keep-data) purge=0 ;;
        *) echo "未知参数：$arg（可用 --purge 删除数据，--keep-data 保留）" >&2; exit 1 ;;
    esac
done

if [ "$(id -u)" != 0 ]; then
    echo "需要 root 权限：sudo $0" >&2
    exit 1
fi

if [ -z "$purge" ]; then
    if [ -t 0 ]; then
        printf '是否同时删除登录与配置？[y/N] '
        read -r ans || ans=
        case "$ans" in
            y|Y|yes|YES) purge=1 ;;
            *) purge=0 ;;
        esac
    else
        purge=0
    fi
fi

here="$(cd "$(dirname "$0")" && pwd)"

if [ -x /opt/ecycloud/ecycloud-helper ]; then
    /opt/ecycloud/ecycloud-helper uninstall || true
fi

if [ "$purge" = 1 ]; then
    if [ -x "$here/purge-data.sh" ]; then
        "$here/purge-data.sh"
    elif [ -x /opt/ecycloud/purge-data.sh ]; then
        /opt/ecycloud/purge-data.sh
    fi
fi

rm -rf /opt/ecycloud
rm -f /usr/share/applications/com.ecycloud.client.desktop
rm -f /usr/share/icons/hicolor/*/apps/com.ecycloud.client.png

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database /usr/share/applications || true
fi

if [ "$purge" = 1 ]; then
    echo "已卸载，并删除了全部数据。"
else
    echo "已卸载。登录与配置已保留。"
fi
