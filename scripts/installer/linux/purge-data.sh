#!/bin/sh
# 清除本机全部 ECY Cloud 数据与系统账户。
# 手工：sudo ./purge-data.sh
# deb 的 postrm 是本文件的副本；dpkg 传入 purge 时才执行。
set -e

if [ -n "${1:-}" ]; then
    case "$1" in
        purge) ;;
        remove|upgrade|failed-upgrade|abort-install|abort-upgrade|disappear)
            exit 0
            ;;
    esac
fi

if [ "$(id -u)" != 0 ]; then
    echo "需要 root 权限：sudo $0" >&2
    exit 1
fi

rm -rf /var/lib/ECYCloud /var/run/ecycloud

if command -v ip >/dev/null 2>&1; then
    ip link del ECYCloud 2>/dev/null || true
fi

clear_user_tree() {
    home="$1"
    login="$2"
    [ -d "$home" ] || return 0
    rm -rf "$home/.config/ECYCloud"
    rm -f "$home/.config/autostart/com.ecycloud.client.desktop"
    uid="$(id -u "$login" 2>/dev/null)" || return 0
    if [ -n "$uid" ] && [ -S "/run/user/$uid/bus" ] && command -v secret-tool >/dev/null 2>&1; then
        bus="unix:path=/run/user/$uid/bus"
        su -s /bin/sh "$login" -c \
            "DBUS_SESSION_BUS_ADDRESS='$bus' secret-tool clear account remembered_password" \
            >/dev/null 2>&1 || true
        su -s /bin/sh "$login" -c \
            "DBUS_SESSION_BUS_ADDRESS='$bus' secret-tool clear account token" \
            >/dev/null 2>&1 || true
    fi
}

clear_user_tree /root root
for home in /home/*; do
    [ -d "$home" ] || continue
    login="$(basename "$home")"
    case "$login" in
        lost+found) continue ;;
    esac
    clear_user_tree "$home" "$login"
done

if id ecycloud >/dev/null 2>&1; then
    userdel ecycloud 2>/dev/null || true
fi
if getent group ecycloud >/dev/null 2>&1; then
    groupdel ecycloud 2>/dev/null || true
fi

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
fi
