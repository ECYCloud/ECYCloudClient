# ECY Cloud 客户端

基于 mihomo 内核的多端代理客户端，支持 Windows、macOS、Linux、Android 与 OpenWrt。

| 平台 | 最低版本 | 架构 | 安装包 |
| ---- | ---- | ---- | ---- |
| Windows | 10 1809 | x64 / arm64 | `windows-x64.exe` / `windows-arm64.exe` |
| macOS | 13 | Intel / Apple Silicon（分包） | `macos-x64.pkg` / `macos-arm64.pkg` |
| Linux（deb） | Debian 12+ / Ubuntu 22.04+ 及衍生版 | x64 / arm64 | `linux-x64.deb` / `linux-arm64.deb` |
| Linux（rpm） | Fedora 36+ / openSUSE Leap 15.6+ / RHEL 10+ 系 | x64 / arm64 | `linux-x64.rpm` / `linux-arm64.rpm` |
| Linux（tar.gz） | 其它带 systemd 与 GTK3 的发行版（Arch 等），glibc 2.35+ | x64 / arm64 | `linux-x64.tar.gz` / `linux-arm64.tar.gz` |
| Linux（AppImage） | 同 tar.gz，另需 polkit（`pkexec`）；首次运行授权安装到 `/opt/ecycloud` | x64 / arm64 | `linux-x64.AppImage` / `linux-arm64.AppImage` |
| Android | 7.0（API 24）；含 Android TV（同一 APK） | arm64-v8a / armeabi-v7a / x86_64（按 ABI 分包） | `android-arm64.apk` / `android-arm.apk` / `android-x64.apk` |
| OpenWrt | **23.05 / 24.10**（ipk）、**25.12**（apk）；要求 fw4 / nftables | 插件 noarch；内核按机型 | `openwrt-23.05.tar.gz` / `openwrt-24.10.tar.gz` / `openwrt-25.12.tar.gz` |

## 安装与更新

各端安装与完整卸载见 [INSTALL.md](INSTALL.md)。

客户端每小时及每次连接成功时检查自身与 mihomo 内核的更新，发现新版会在界面上提示，也可在设置 - 关于里手动检查：客户端更新会下载安装包并校验 SHA-256 后启动安装程序；内核更新由后台服务就地替换，Android 的内核随应用整包更新，不单独升级。Linux 的 tar.gz 与 AppImage 形态没有能接手的安装器，只提示新版本并给出发布页入口，需自行下载后重跑 `install.sh` 或新的 AppImage。

## OpenWrt 插件

包名 `luci-app-ecycloud`。在路由器上登录面板、拉取配置、启动 mihomo、用 TPROXY（默认）或 TUN 做透明代理并选节点。公告、工单、商店等账号业务仍在面板网站处理，插件里没有这些页面。

插件**不自带内核**。每个 OpenWrt 版本分别提供主包与简繁中文翻译包：**23.05 / 24.10** 使用 ipk，**25.12** 使用 apk。23.05 须自行提供兼容且声明提供 `mihomo` 的内核包；24.10 / 25.12 可安装 Nikki 源的 `mihomo-meta`。安装、卸载与内核升级见 [INSTALL.md](INSTALL.md)。

## 许可证

GPL-3.0-or-later，见 `LICENSE`。

本项目使用 MetaCubeX/mihomo（GPL-3.0）作为代理内核，内核源码不作任何修改，所用版本见 `scripts/kernel.lock.json`。