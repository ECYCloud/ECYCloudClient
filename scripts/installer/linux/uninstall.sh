#!/bin/sh
# 停服务时会还原系统代理并拆掉 TUN，必须赶在删文件之前
set -e

if [ "$(id -u)" != 0 ]; then
    echo "需要 root 权限：sudo $0" >&2
    exit 1
fi

if [ -x /opt/ecycloud/ecycloud-helper ]; then
    /opt/ecycloud/ecycloud-helper uninstall || true
fi

rm -rf /opt/ecycloud
rm -f /usr/share/applications/com.ecycloud.client.desktop
rm -f /usr/share/icons/hicolor/*/apps/com.ecycloud.client.png

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor || true
fi

echo "已卸载。/var/lib/ECYCloud 与 ecycloud 账户按惯例保留，重装可直接续用。"
