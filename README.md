# ECY Cloud 客户端

基于 mihomo 内核的多端代理客户端，支持 Windows、macOS、Linux、Android 与 OpenWrt。

| 平台 | 最低版本 | 架构 | 安装包 |
| ---- | ---- | ---- | ---- |
| Windows | 10 1809 | x64 / arm64 | `windows-x64.exe` / `windows-arm64.exe` |
| macOS | 11 | Intel / Apple Silicon（分包） | `macos-x64.pkg` / `macos-arm64.pkg` |
| Linux（deb） | Debian 12+ / Ubuntu 22.04+ 及衍生版 | x64 / arm64 | `linux-x64.deb` / `linux-arm64.deb` |
| Linux（rpm） | Fedora 36+ / openSUSE Leap 15.6+ / RHEL 10+ 系 | x64 / arm64 | `linux-x64.rpm` / `linux-arm64.rpm` |
| Linux（tar.gz） | 其它带 systemd 与 GTK3 的发行版（Arch 等），glibc 2.35+ | x64 / arm64 | `linux-x64.tar.gz` / `linux-arm64.tar.gz` |
| Android | 7.0（API 24）；含 Android TV（同一 APK） | arm64-v8a / armeabi-v7a / x86_64（按 ABI 分包） | `android-arm64.apk` / `android-arm.apk` / `android-x64.apk` |
| OpenWrt | **23.05 / 24.10**（ipk）、**25.12**（apk）；要求 fw4 / nftables | 插件 noarch；内核按机型 | `openwrt-23.05.tar.gz` / `openwrt-24.10.tar.gz` / `openwrt-25.12.tar.gz` |

## 安装与更新

各端安装与完整卸载见 [INSTALL.md](INSTALL.md)。

客户端每 24 小时检查一次自身与 mihomo 内核的更新，发现新版会在界面上提示，也可在设置 - 关于里手动检查：客户端更新会下载安装包并校验 SHA-256 后启动安装程序；内核更新由后台服务就地替换，Android 的内核随应用整包更新，不单独升级。Linux 的 tar.gz 形态没有能接手的安装器，只提示新版本并给出发布页入口，需自行下载后重跑 `install.sh`。

## OpenWrt 插件

包名 `luci-app-ecycloud`。在路由器上登录面板、拉取配置、启动 mihomo、用 TPROXY（默认）或 TUN 做透明代理并选节点。公告、工单、商店等账号业务仍在面板网站处理，插件里没有这些页面。

插件**不自带内核**。每个 OpenWrt 版本分别提供主包与简繁中文翻译包：**23.05 / 24.10** 使用 ipk，**25.12** 使用 apk。23.05 须自行提供兼容且声明提供 `mihomo` 的内核包；24.10 / 25.12 可安装 Nikki 源的 `mihomo-meta`。安装、卸载与内核升级见 [INSTALL.md](INSTALL.md)。

### 自行编译

官方脚本按 `--openwrt` 选择 **23.05.6 / 24.10.5 / 25.12.5** x86/64 SDK，默认 25.12。每次出三个包，打成与 Release 相同的 tar.gz（在 Linux 上执行）：

```bash
./scripts/build-openwrt.sh --version 1.0.1
./scripts/build-openwrt.sh --version 1.0.1 --openwrt 24.10
./scripts/build-openwrt.sh --version 1.0.1 --openwrt 23.05
# 可选：--channel last|pre --panel-url https://站点 --sub-url https://配置下发域
```

产物在 `build/installer/ECYCloud-<版本>-openwrt-<OpenWrt版本>.tar.gz`。未指定 URL 时从 `config/panel.json` 誊抄，缺一就会失败，避免把占位符打进包里。

也可把 `openwrt/luci-app-ecycloud` 挂进对应版本的 SDK / 编译环境后执行 `make package/luci-app-ecycloud/compile`。不同版本共用同一份源码与依赖声明。

## 从源码构建

通用前置：Flutter stable（版本见 `.github/workflows/release.yml`）、Go（版本见各原生模块的 `go.mod`）、`jq`。构建脚本按 `scripts/kernel.lock.json` 下载官方内核发布包并校验 SHA-256，不使用任何非官方内核。

```powershell
# Windows：另需 Inno Setup 7.1+
pwsh scripts/build-windows.ps1 -Arch x64 -Installer
```

```bash
# macOS：另需 Xcode 命令行工具；Intel 与 Apple Silicon 分别出包
./scripts/build-macos.sh --arch arm64 --version 1.0.1 --package

# Linux：另需 GTK3 与 libayatana-appindicator 开发包；打包用 dpkg-deb 与 rpmbuild
# 默认出 deb / rpm / tar.gz 三种，--format deb,rpm,tar 可只出其中几种
./scripts/build-linux.sh --arch x64 --version 1.0.1 --package

# Android：另需 JDK 17、Android SDK + NDK（版本见 app/android/app/build.gradle.kts；首次会现编 libmihomo.aar）
./scripts/build-android.sh --version 1.0.1

# OpenWrt 插件（默认 25.12 apk；--openwrt 24.10 或 23.05 出 ipk）
./scripts/build-openwrt.sh --version 1.0.1
```

Flutter 不支持交叉编译 Windows / Linux 桌面产物，对应 arm64 包须在 arm64 机器上构建；macOS 可在 Apple Silicon 上构建并 thin 出 Intel 包。推送到仓库后 GitHub Actions 会按 `.github/workflows/release.yml` 出各端安装包（Artifacts）；打 `v*` tag 或手动触发才会写入 Releases。

## 许可证

GPL-3.0-or-later，见 `LICENSE`。

本项目使用 MetaCubeX/mihomo（GPL-3.0）作为代理内核，与本项目同为 GPL 系许可，可直接结合分发。桌面端以未修改的官方发布二进制形式随包；Android 端的 `libmihomo.aar` 由 `scripts/build-libmihomo.sh` 把同一 tag 的内核**当依赖 import** 后对 `native/android/mihomo` 这层封装做 `gomobile bind`，内核源码不作任何修改。两端的内核构建信息（tag + checksum）见 `scripts/kernel.lock.json`，发布二进制时需同时提供本仓库完整源码。
