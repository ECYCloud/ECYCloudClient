# 载荷是构建好的二进制，交给 rpm 再跑一遍 strip 与 debuginfo 提取只会破坏 Flutter 产物
%global __os_install_post %{nil}
%global debug_package %{nil}

Name:           ecycloud
Version:        %{app_version}
Release:        1
Summary:        ECY Cloud
License:        GPL-3.0-or-later
URL:            https://github.com/ECYCloud/ECYCloudClient
# 各发行版的 GTK 与托盘包名不一致，按 SONAME 声明才能同时满足 Fedora 系与 openSUSE
AutoReqProv:    no
Requires:       libgtk-3.so.0()(64bit)
Requires:       libayatana-appindicator3.so.1()(64bit)
Requires:       (iproute or iproute2)
# 系统代理默认开启，读写的 org.gnome.system.proxy 由它提供，GTK3 并不带
Requires:       gsettings-desktop-schemas

%description
基于 sing-box 内核的 ECY Cloud 客户端，含特权后台服务。

%install
cp -a %{payload}/. %{buildroot}/

%files
/opt/ecycloud
/usr/share/applications/com.ecycloud.client.desktop
/usr/share/icons/hicolor/*/apps/com.ecycloud.client.png

%post
/opt/ecycloud/ecycloud-helper install
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor || true
fi

%preun
# 升级时 $1 为 1，此刻新包的安装脚本已经跑过，不判断就会把刚注册好的服务停掉
if [ "$1" = 0 ] && [ -x /opt/ecycloud/ecycloud-helper ]; then
    /opt/ecycloud/ecycloud-helper uninstall || true
fi
