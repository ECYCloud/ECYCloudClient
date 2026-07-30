# ECY Cloud 客户端

基于 sing-box 内核的多端代理客户端。当前支持 Windows 桌面端（Windows 10 1809+ / Windows 11，x64 与 arm64）。

## 安装与更新

安装包在 [Releases](https://github.com/ECYCloud/ECYCloudClient/releases) 按架构取：x64 机器用 `windows-x64.exe`，ARM 机器用 `windows-arm64.exe`。安装需要管理员授权以注册后台服务。

客户端每 24 小时检查一次自身与 sing-box 内核的更新，发现新版会在界面上提示，也可在设置 - 关于里手动检查：客户端更新会下载安装包并校验 SHA-256 后启动安装程序，内核更新由后台服务就地替换。

## 从源码构建

需要 Flutter stable、Go（版本见 `native/windows/service/go.mod`）与 Inno Setup 6.6+，然后：

```powershell
pwsh scripts/build-windows.ps1 -Arch x64 -Installer
```

Flutter 不支持交叉编译 Windows 产物，arm64 包须在 arm64 机器上构建。发布流水线见 `.github/workflows/release.yml`。

## 许可证

GPL-3.0-or-later，见 `LICENSE`。

本项目使用 SagerNet/sing-box（GPL-3.0-or-later）作为代理内核，以未修改的官方发布二进制形式分发。sing-box 附加条款禁止衍生作品使用其名称或暗示关联，本项目的产品名、图标与商店描述均不引用该名称。发布二进制时需同时提供本仓库完整源码与内核构建信息（tag + checksum，见 `scripts/kernel.lock.json`）。
