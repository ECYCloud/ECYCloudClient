# 安装与卸载

安装包在 [Releases](https://github.com/ECYCloud/ECYCloudClient/releases)。将下文 `<版本>` 换成页面上的版本号。`x86_64` 用 `linux-x64` / `windows-x64` 等，`aarch64` 用对应的 `arm64` 包。

桌面端安装时需要一次管理员授权，用于注册后台服务；之后日常使用不再提权。Android 首次连接时会弹出系统的 VPN 授权。

## 安装

### Windows

运行 `ECYCloud-<版本>-windows-x64.exe`（或 `windows-arm64`），按向导完成。

### macOS

打开 `ECYCloud-<版本>-macos-arm64.pkg`（Intel 用 `macos-x64`），按向导完成。

### Linux

Debian / Ubuntu 及衍生版：

```sh
sudo apt install ./ECYCloud-<版本>-linux-x64.deb
```

Fedora / RHEL 系：

```sh
sudo dnf install ./ECYCloud-<版本>-linux-x64.rpm
```

openSUSE：

```sh
sudo zypper install ./ECYCloud-<版本>-linux-x64.rpm
```

其它带 systemd 与 GTK3 的发行版：

```sh
tar -xzf ECYCloud-<版本>-linux-x64.tar.gz
cd ECYCloud-<版本>-linux-x64
sudo ./install.sh
```

从应用程序菜单启动 **ECY Cloud**，使用面板账号登录。

### Android

安装对应 ABI 的 APK：`android-arm64`（主流真机）、`android-arm`（旧 32 位）、`android-x64`（模拟器）。Android TV 与手机同一份 APK。

### OpenWrt

按系统版本下载：**25.12 使用 apk，24.10 / 23.05 使用 ipk**。插件不自带内核，须先安装兼容且声明提供 `mihomo` 的内核包（24.10 / 25.12 可用 `mihomo-meta`，不要装 `nikki`）。以下命令全程在路由器 SSH 执行。

#### OpenWrt 25.12（apk）

```sh
wget -O /etc/apk/keys/nikki.pem https://nikkinikki.pages.dev/public-key.pem
arch="$(. /etc/openwrt_release; echo "$DISTRIB_ARCH")"
mkdir -p /etc/apk/repositories.d
echo "https://nikkinikki.pages.dev/openwrt-25.12/${arch}/nikki/packages.adb" >> /etc/apk/repositories.d/customfeeds.list
apk update
apk add mihomo-meta
```

```sh
cd /tmp
wget -O ecycloud.tgz \
  https://github.com/ECYCloud/ECYCloudClient/releases/download/v<版本>/ECYCloud-<版本>-openwrt-25.12.tar.gz
tar -C /tmp -xzf ecycloud.tgz
apk add --allow-untrusted /tmp/luci-app-ecycloud-*.apk /tmp/luci-i18n-ecycloud-zh-cn-*.apk
```

LuCI → **服务 → ECY Cloud**，使用面板账号登录。`--allow-untrusted` 不能省：发布包由 CI 一次性密钥签名。只要英文界面可只装 `luci-app-ecycloud`。

#### OpenWrt 24.10（ipk）

适用于使用 `opkg`、fw4 / nftables 的 OpenWrt 24.10。先确认路由器能访问软件源和 GitHub，系统时间正确，`/overlay` 与 `/tmp` 有可用空间。官方依赖源须与本机固件版本、架构匹配；出现 `kmod-*` 内核版本不匹配时，应修正固件或软件源，不能用 `--force-depends` 强装。

先添加内核软件源并安装内核（重复执行会替换同名源）：

```sh
(
set -e
wget -O /tmp/nikki-key.pub https://nikkinikki.pages.dev/key-build.pub
opkg-key add /tmp/nikki-key.pub
rm -f /tmp/nikki-key.pub
arch="$(. /etc/openwrt_release; echo "$DISTRIB_ARCH")"
sed -i '/^[[:space:]]*src\/gz[[:space:]][[:space:]]*nikki[[:space:]]/d' /etc/opkg/customfeeds.conf
echo "src/gz nikki https://nikkinikki.pages.dev/openwrt-24.10/${arch}/nikki" >> /etc/opkg/customfeeds.conf
opkg update
opkg install mihomo-meta
)
```

确认上一步成功，再安装插件。每次使用独立临时目录，避免升级时混入旧 ipk。仅需英文时可省略翻译包，繁体中文将 `zh-cn` 换成 `zh-tw`。测试版须将下载地址中的 `v<版本>` 改为 `v<版本>-pre`，文件名中的 `<版本>` 仍为纯版本号。

```sh
(
set -e
cd "$(mktemp -d /tmp/ecycloud-install.XXXXXX)"
wget -O ecycloud.tgz \
  'https://github.com/ECYCloud/ECYCloudClient/releases/download/v<版本>/ECYCloud-<版本>-openwrt-24.10.tar.gz'
tar -xzf ecycloud.tgz
opkg install ./luci-app-ecycloud_*.ipk ./luci-i18n-ecycloud-zh-cn_*.ipk
)
```

安装后重新登录 LuCI，在 **服务 → ECY Cloud** 使用面板账号登录，点击「连接」，确认状态为「已连接」。如果菜单或页面仍是旧内容，按 **Ctrl+F5** 强制刷新。安装与启动失败时先查看 `opkg` 的错误输出及 `logread -e ecycloud`。

插件升级时重新执行上面的插件下载、解压与安装步骤，将主包和所选翻译包一并更新；已修改的 `/etc/config/ecycloud` 与 `/etc/ecycloud/` 中的账号、配置缓存会保留。`opkg install` 会在升级过程中重启插件服务，代理连接会短暂中断；完成后刷新 LuCI 并确认连接状态。

#### OpenWrt 23.05（ipk）

下载 `ECYCloud-<版本>-openwrt-23.05.tar.gz`，解压与安装命令同上。**Nikki 源不提供 23.05 分支，不能使用 24.10 的内核源**；须先从适配本机固件与架构的软件源安装声明提供 `mihomo` 的兼容内核包，再运行 `opkg update` 与上述插件安装命令。插件依赖 fw4 / nftables、ucode 与 `rpcd-mod-ucode`，不支持 22.03 及更早版本。

#### 内核升级

25.12 在路由器 SSH 执行（须已按上文加过 Nikki 源）：

```sh
apk update
apk upgrade mihomo-meta
```

24.10 使用 `opkg update && opkg upgrade mihomo-meta`；23.05 按所选内核源的说明升级。只能升到软件源当前提供的版本。设置页内核检查读的是 Nikki 源的 `mihomo-meta`，不是 GitHub 上的 Mihomo 正式版；23.05 会提示该源不支持本机版本。不要装 `nikki`。

## 卸载

卸载前先退出客户端，以便还原系统代理。不要跳过后台服务注销直接删文件。

**默认只卸程序，保留登录与配置。** 要连数据一起删，用各节里的「同时删除数据」。

### Windows

「应用和功能」中卸载 ECY Cloud。默认保留 `%APPDATA%\ECYCloud` 与 `%ProgramData%\ECYCloud`。要删除数据，在向导里勾选删除应用数据。

### macOS

```sh
sudo "/Library/Application Support/ECYCloud/bin/ecycloud-helper" uninstall
sudo rm -rf "/Applications/ECYCloud.app"
```

同时删除数据：

```sh
sudo rm -rf "/Library/Application Support/ECYCloud"
rm -f ~/Library/LaunchAgents/com.ecycloud.client.plist
rm -rf ~/Library/Application\ Support/ECYCloud
```

### Linux

```sh
sudo /opt/ecycloud/uninstall.sh
```

终端会询问「是否同时删除登录与配置？」，直接回车为否（保留数据）。非交互环境默认保留；脚本可用 `--purge` 或 `--keep-data` 跳过询问。

也可用包管理器（不会弹出该询问）：`sudo apt remove ecycloud` 保留数据，`sudo apt purge ecycloud` 删除数据。Fedora / RHEL 用 `dnf remove`，openSUSE 用 `zypper remove`（默认都保留数据；要删数据须先 `sudo /opt/ecycloud/purge-data.sh`）。

### Android

按系统方式卸载应用。应用数据随包删除。

### OpenWrt

以下命令在路由器 SSH 中执行。默认只卸插件，保留 `/etc/ecycloud/` 中的账号与配置缓存；24.10 / 23.05 的 `opkg` 保留已修改的 `/etc/config/ecycloud`，未修改的默认配置会随包删除。

先停止服务并禁用开机启动，确认成功后再卸包。24.10 / 23.05 必须先卸翻译包，再卸主包（未安装的翻译包会被跳过）：

```sh
(
set -e
/etc/init.d/ecycloud stop
/etc/init.d/ecycloud disable
if command -v apk >/dev/null 2>&1; then
  apk del luci-app-ecycloud luci-i18n-ecycloud-zh-cn luci-i18n-ecycloud-zh-tw
else
  opkg remove luci-i18n-ecycloud-zh-cn luci-i18n-ecycloud-zh-tw luci-app-ecycloud
fi
)
```

24.10 / 23.05 可用 `opkg list-installed | grep -E '^luci-(app|i18n)-ecycloud'` 检查，卸载成功后应无输出。LuCI 中的旧菜单用 **Ctrl+F5** 刷新。

**仅当卸包前未能正常停止服务时**，先执行下面的残留清理，再决定是否删除数据。此步骤按插件的网络记录恢复 DNS，并清除其防火墙文件、策略路由和 TUN 网卡：

```sh
ubus call service delete '{"name":"ecycloud"}' 2>/dev/null
dnsmasq_file="$(jsonfilter -i /var/run/ecycloud/network.json -e '@.dnsmasq' 2>/dev/null)"
case "$dnsmasq_file" in
  /*/ecycloud.conf) rm -f "$dnsmasq_file" ;;
esac
rm -f /tmp/dnsmasq.*.d/ecycloud.conf
rm -f /usr/share/nftables.d/ruleset-post/ecycloud.nft \
  /usr/share/nftables.d/chain-pre/input/ecycloud.nft \
  /usr/share/nftables.d/chain-pre/forward/ecycloud.nft \
  /usr/share/nftables.d/chain-pre/dstnat/ecycloud.nft
ip rule del fwmark 502 lookup 1936 2>/dev/null
ip route del local default dev lo table 1936 2>/dev/null
ip -6 rule del fwmark 502 lookup 1936 2>/dev/null
ip -6 route del local default dev lo table 1936 2>/dev/null
tun_device="$(uci -q get ecycloud.config.tun_device)"
ip link del "${tun_device:-ECYCloud}" 2>/dev/null
/etc/init.d/dnsmasq restart
fw4 reload
nft delete table inet ecycloud 2>/dev/null
rm -f /var/run/ecycloud/network.json
```

同时删除数据（不可恢复）：

若手动修改过 `ecycloud.config.run_dir`，删除配置前先用 `uci -q get ecycloud.config.run_dir` 确认路径，再清理该目录中属于插件的数据。

```sh
rm -f /etc/config/ecycloud /etc/config/ecycloud-opkg
rm -rf /etc/ecycloud /var/run/ecycloud
```

浏览器中曾勾选「记住账号密码」的，还需清除该 LuCI 站点的浏览器数据。

不再需要通过上文安装的 `mihomo-meta` 与 Nikki 源，且其它插件也不再使用它们时，可继续卸载内核、移除源。不要批量卸载 fw4、dnsmasq、LuCI 等系统共用依赖：

```sh
if command -v apk >/dev/null 2>&1; then
  apk del mihomo-meta
  sed -i '/nikki/d' /etc/apk/repositories.d/customfeeds.list
  rm -f /etc/apk/keys/nikki.pem
else
  opkg remove mihomo-meta && \
    sed -i '/^[[:space:]]*src\/gz[[:space:]][[:space:]]*nikki[[:space:]]/d' /etc/opkg/customfeeds.conf && \
    rm -f /var/opkg-lists/nikki /var/opkg-lists/nikki.sig
fi
```

24.10 / 23.05 若也要移除上文导入的 Nikki 公钥，联网执行（仅删除与该公钥匹配的信任项）：

```sh
wget -O /tmp/nikki-key.pub https://nikkinikki.pages.dev/key-build.pub && \
  opkg-key remove /tmp/nikki-key.pub && \
  rm -f /tmp/nikki-key.pub
```
