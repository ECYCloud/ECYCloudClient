# ECY Cloud 客户端

基于 mihomo 内核的多端代理客户端，支持 Windows、macOS、Linux 与 Android。

| 平台 | 最低版本 | 架构 | 安装包 |
| ---- | ---- | ---- | ---- |
| Windows | 10 1809 | x64 / arm64 | `windows-x64.exe` / `windows-arm64.exe` |
| macOS | 11 | Intel / Apple Silicon（分包） | `macos-x64.pkg` / `macos-arm64.pkg` |
| Linux（deb） | Debian 12+ / Ubuntu 22.04+ 及衍生版 | x64 / arm64 | `linux-x64.deb` / `linux-arm64.deb` |
| Linux（rpm） | Fedora 36+ / openSUSE Leap 15.6+ / RHEL 10+ 系 | x64 / arm64 | `linux-x64.rpm` / `linux-arm64.rpm` |
| Linux（tar.gz） | 其它带 systemd 与 GTK3 的发行版（Arch 等），glibc 2.35+ | x64 / arm64 | `linux-x64.tar.gz` / `linux-arm64.tar.gz` |
| Android | 7.0（API 24） | arm64-v8a / armeabi-v7a / x86_64（按 ABI 分包） | `android-arm64.apk` / `android-arm.apk` / `android-x64.apk` |

## 安装与更新

安装包在 [Releases](https://github.com/ECYCloud/ECYCloudClient/releases) 按上表取。桌面三端安装时需要一次管理员授权，用于注册常驻的后台服务；此后日常使用不再要求提权。Android 首次连接时会弹出系统的 VPN 授权。

Linux 的 deb 与 rpm 交给包管理器即可；tar.gz 面向没有这两者的发行版，解包后执行 `sudo ./install.sh`，脚本会铺文件并注册同一套服务。

客户端每 24 小时检查一次自身与 mihomo 内核的更新，发现新版会在界面上提示，也可在设置 - 关于里手动检查：客户端更新会下载安装包并校验 SHA-256 后启动安装程序；内核更新由后台服务就地替换，Android 的内核随应用整包更新，不单独升级。Linux 的 tar.gz 形态没有能接手的安装器，只提示新版本并给出发布页入口，需自行下载后重跑 `install.sh`。

### 卸载

- Windows：从「应用和功能」卸载，可选是否一并删除应用数据。
- macOS：先 `sudo "/Library/Application Support/ECYCloud/bin/ecycloud-helper" uninstall`，再删除 `/Applications/ECYCloud.app` 与 `/Library/Application Support/ECYCloud`。
- Linux：deb 用 `sudo apt remove ecycloud`，rpm 用 `sudo dnf remove ecycloud`（openSUSE 用 `sudo zypper remove ecycloud`），tar.gz 用 `sudo /opt/ecycloud/uninstall.sh`。
- Android：按常规卸载应用。

后台服务在注销时会停止内核并还原系统代理，请勿跳过这一步直接删文件。

## 从源码构建

通用前置：Flutter stable、Go（版本见 `native/*/go.mod`）、`jq`。构建脚本按 `scripts/kernel.lock.json` 下载官方内核发布包并校验 SHA-256，不使用任何非官方内核。

```powershell
# Windows：另需 Inno Setup 6.6+
pwsh scripts/build-windows.ps1 -Arch x64 -Installer
```

```bash
# macOS：另需 Xcode 命令行工具；Intel 与 Apple Silicon 分别出包
./scripts/build-macos.sh --arch arm64 --version 1.0.1 --package

# Linux：另需 GTK3 与 libayatana-appindicator 开发包；打包用 dpkg-deb 与 rpmbuild
# 默认出 deb / rpm / tar.gz 三种，--format deb,rpm,tar 可只出其中几种
./scripts/build-linux.sh --arch x64 --version 1.0.1 --package

# Android：另需 JDK 17、Android SDK + NDK（首次会现编 libmihomo.aar，耗时较长）
./scripts/build-android.sh --version 1.0.1
```

Flutter 不支持交叉编译 Windows / Linux 桌面产物，对应 arm64 包须在 arm64 机器上构建；macOS 可在 Apple Silicon 上构建并 thin 出 Intel 包。发布流水线见 `.github/workflows/release.yml`。

## 许可证

GPL-3.0-or-later，见 `LICENSE`。

本项目使用 MetaCubeX/mihomo（GPL-3.0）作为代理内核，与本项目同为 GPL 系许可，可直接结合分发。桌面端以未修改的官方发布二进制形式随包；Android 端的 `libmihomo.aar` 由 `scripts/build-libmihomo.sh` 把同一 tag 的内核**当依赖 import** 后对 `native/android/mihomo` 这层封装做 `gomobile bind`，内核源码不作任何修改。两端的内核构建信息（tag + checksum）见 `scripts/kernel.lock.json`，发布二进制时需同时提供本仓库完整源码。
