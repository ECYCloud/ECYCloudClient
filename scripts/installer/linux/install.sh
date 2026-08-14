#!/bin/sh
# 没有 deb / rpm 的发行版用这个装，做的事与两者的安装脚本一致：铺文件后由 helper 注册服务。
set -e

target='/opt/ecycloud'
here="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" != 0 ]; then
    echo "需要 root 权限：sudo $0" >&2
    exit 1
fi
if ! command -v systemctl >/dev/null 2>&1; then
    echo "未检测到 systemd，特权后台服务以 systemd 单元形式注册，无法在本系统安装" >&2
    exit 1
fi

# 覆盖安装前必须先停服务，运行中的 helper 与内核会占住自己的可执行文件
if [ -x "$target/ecycloud-helper" ]; then
    "$target/ecycloud-helper" uninstall || true
fi

# tar 只在 root 解包时才还原属主与模式，而 helper 由 systemd 以 root 拉起：
# 属主不收归 root，解包那个账户就能改写特权二进制
chown -R root:root "$here/opt" "$here/usr"
chmod -R u=rwX,go=rX "$here/opt" "$here/usr"

rm -rf "$target"
mkdir -p /opt
cp -a "$here/opt/." /opt/
cp -a "$here/usr/." /usr/
install -m 0755 "$here/uninstall.sh" "$target/uninstall.sh"

# cp -a 连 SELinux 标签一起搬（解包目录多半是 user_home_t），
# systemd 不会以服务身份执行这种标签的二进制
if command -v restorecon >/dev/null 2>&1; then
    restorecon -R /opt/ecycloud /usr/share/applications /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi

"$target/ecycloud-helper" install

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database /usr/share/applications || true
fi

# tar.gz 形态没有包管理器兜底依赖，缺库只会表现为界面起不来，装完就先报出来
missing="$(ldd "$target/ECYCloud" 2>/dev/null | awk '/not found/ {print $1}')"
if [ -n "$missing" ]; then
    echo "以下运行库缺失，请用发行版的包管理器补装 GTK3、libayatana-appindicator 与 libsecret：" >&2
    echo "$missing" >&2
fi

# 系统代理默认开启，schema 缺失会让连接直接失败，而它不是 GTK3 的依赖
if ! gsettings get org.gnome.system.proxy mode >/dev/null 2>&1; then
    echo "缺少 org.gnome.system.proxy schema，请补装 gsettings-desktop-schemas，否则连接时系统代理会报错" >&2
fi

echo "安装完成，可从桌面菜单启动 ECY Cloud，卸载执行 sudo $target/uninstall.sh"
