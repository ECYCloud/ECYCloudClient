# ECY Cloud 客户端

基于 sing-box 内核的多端代理客户端，支持 Windows、macOS、Linux 与 Android。

| 平台 | 最低版本 | 架构 | 安装包 |
| ---- | ---- | ---- | ---- |
| Windows | 10 1809 | x64 / arm64 | `windows-x64.exe` / `windows-arm64.exe` |
| macOS | 11 | Intel + Apple Silicon 通用 | `macos.pkg` |
| Linux | 使用 systemd 与 GTK3 的发行版（Debian 12+ / Ubuntu 22.04+ 及衍生版） | x64 / arm64 | `linux-x64.deb` / `linux-arm64.deb` |
| Android | 7.0（API 24） | arm64-v8a / armeabi-v7a / x86_64（按 ABI 分包） | `android-arm64.apk` / `android-arm.apk` / `android-x64.apk` |

## 安装与更新

安装包在 [Releases](https://github.com/ECYCloud/ECYCloudClient/releases) 按上表取。桌面三端安装时需要一次管理员授权，用于注册常驻的后台服务；此后日常使用不再要求提权。Android 首次连接时会弹出系统的 VPN 授权。

客户端每 24 小时检查一次自身与 sing-box 内核的更新，发现新版会在界面上提示，也可在设置 - 关于里手动检查：客户端更新会下载安装包并校验 SHA-256 后启动安装程序；内核更新由后台服务就地替换，Android 的内核随应用整包更新，不单独升级。

### 卸载

- Windows：从「应用和功能」卸载，可选是否一并删除应用数据。
- macOS：先 `sudo "/Library/Application Support/ECYCloud/bin/ecycloud-helper" uninstall`，再删除 `/Applications/ECYCloud.app` 与 `/Library/Application Support/ECYCloud`。
- Linux：`sudo apt remove ecycloud`。
- Android：按常规卸载应用。

后台服务在注销时会停止内核并还原系统代理，请勿跳过这一步直接删文件。

## 从源码构建

通用前置：Flutter stable、Go（版本见 `native/*/go.mod`）、`jq`。构建脚本按 `scripts/kernel.lock.json` 下载官方内核发布包并校验 SHA-256，不使用任何非官方内核。

```powershell
# Windows：另需 Inno Setup 6.6+
pwsh scripts/build-windows.ps1 -Arch x64 -Installer
```

```bash
# macOS：另需 Xcode 命令行工具
./scripts/build-macos.sh --version 1.0.1 --package

# Linux：另需 GTK3 与 libayatana-appindicator 开发包、dpkg-deb
./scripts/build-linux.sh --arch x64 --version 1.0.1 --package

# Android：另需 JDK 17、Android SDK + NDK（首次会现编 libbox.aar，耗时较长）
./scripts/build-android.sh --version 1.0.1
```

Flutter 不支持交叉编译桌面产物，arm64 包须在 arm64 机器上构建；macOS 包是通用二进制，随包的内核与 helper 由脚本用 `lipo` 合成。发布流水线见 `.github/workflows/release.yml`。

## 许可证

GPL-3.0-or-later，见 `LICENSE`。

本项目使用 SagerNet/sing-box（GPL-3.0-or-later）作为代理内核。桌面端以未修改的官方发布二进制形式分发；Android 端的 `libbox.aar` 由 `scripts/build-libbox.sh` 用同一 tag 的官方源码与官方 Makefile 目标构建，不含任何修改。sing-box 附加条款禁止衍生作品使用其名称或暗示关联，本项目的产品名、图标与商店描述均不引用该名称。发布二进制时需同时提供本仓库完整源码与内核构建信息（tag + checksum，见 `scripts/kernel.lock.json`）。
