# Windows 实现

目标系统：Windows 10 1809（build 17763）及以上、Windows 11，架构 x64 与 arm64。

## 提权形态：服务模式

在「服务模式」与「提权模式」之间选择**服务模式**。

### 取舍

| | 服务模式（采用） | 提权模式（未采用） |
| ---- | ---- | ---- |
| UAC | 仅安装 / 卸载时各一次 | 每次开启 TUN 都弹 |
| 崩溃 / 强杀后还原系统代理 | 服务常驻，能兜底还原 | 无人兜底，代理设置残留 |
| 开机自启后自动连接 | 可行 | 登录后仍需 UAC，无法静默 |
| GUI 进程权限 | 保持普通用户权限，攻击面小 | 整个 Flutter 进程以管理员运行 |
| 分发 | 必须走安装器 | 可绿色版 |
| 卸载 | 需要注销服务 | 无残留 |

代价是必须提供安装器且卸载要清理服务，换来的是日常零 UAC 与可靠的状态还原，对常驻型代理客户端更重要。

### 服务定义

| 项 | 值 |
| ---- | ---- |
| 服务名 | `ECYCloudService` |
| 显示名 | `ECY Cloud 网络服务` |
| 账户 | `LocalSystem` |
| 启动类型 | 自动（延迟启动） |
| 失败恢复 | 第 1/2 次 5 秒后重启，后续 60 秒 |
| 可执行文件 | `<InstallDir>\service\ecycloud-service.exe` |

### IPC

命名管道 `\\.\pipe\ECYCloudService`，逐行 JSON（每行一个请求 / 响应对象，UTF-8，`\n` 结尾）。一次连接只处理一条请求：GUI 写一行，服务应答一行后关闭连接，GUI 以 EOF 判定应答结束，因此不需要维护会话状态。

服务不读请求体里的 `pid` 字段（调用方自己填的，不可信，仅为兼容旧版协议保留），改用 `GetNamedPipeClientProcessId` 取内核记录的真实连接进程 PID，据此挂进程监听、定位 GUI 所在会话，用于 GUI 崩溃时的收尾。

安全描述符只授予 `BUILTIN\Administrators`、`NT AUTHORITY\SYSTEM` 与**交互登录用户**（`SDDL` 中的 `IU`）读写权限，拒绝网络登录与匿名，防止其它本地账户或远程会话操控内核。但 DACL 分不清"同一账户下的哪个进程"，`kernel.start`（写任意配置并以 SYSTEM 拉起内核）与 `kernel.upgrade`（替换安装目录下的内核二进制）这两条会让 SYSTEM 执行调用方给的内容，额外在应用层核对真实连接进程的可执行文件路径必须是安装目录下的官方 GUI（`<InstallDir>\ECYCloud.exe`），非此路径一律拒绝。

管道只承载平台能力指令，不承载业务判断：

| 指令 | 作用 |
| ---- | ---- |
| `ping` | 存活与版本，附 `kernel`（服务代跑 `sing-box version` 的首行，设置里的内核版本与更新检查用它）与 `cache_ready`：内核缓存 `cache.db` 是否已落盘，GUI 据此判断本次是否为首次连接（首次要现下载远程规则集，明显更慢，需要在界面上交代） |
| `kernel.start` | 写入配置文件并拉起 sing-box 子进程 |
| `kernel.stop` | 停止子进程 |
| `kernel.status` | 返回运行状态、PID、退出码与增量日志 |
| `kernel.check` | 用 `sing-box check` 校验配置 |
| `kernel.upgrade` | 按版本号换成官方发布的内核，见「内核升级」 |
| `proxy.set` | 设置系统代理 |
| `proxy.restore` | 还原系统代理 |
| `proxy.state` | 返回当前系统代理与快照状态 |
| `wintun.ensure` | 校验 TUN 依赖是否就绪 |

服务不解析配置内容、不判断该不该连、不做重启决策；这些都在 Dart 侧。内核异常退出时服务只上报事件。

内核日志用有界缓冲承载，游标全局单调递增。`kernel.status` 携带 `log_cursor` 只取增量，缓冲溢出丢弃的行由游标跳变体现，不会让 GUI 误判为没有新日志。

## 内核升级

内核装在安装目录（Program Files）下，替换要管理员权限，因此整条链路都在服务里：GUI 只交一个版本号，资产名、下载地址与校验值全由服务自己向 `api.github.com/repos/SagerNet/sing-box` 解析，避免 GUI 被替换后能指使 SYSTEM 进程下载任意文件。

1. 版本号须匹配 `^\d+(\.\d+){1,3}$`；按 `runtime.GOARCH` 定位资产 `sing-box-<版本>-windows-<arch>.zip`。
2. 校验值取 Releases API 资产的 `digest` 字段（`sha256:…`），缺失即拒绝升级——不安装没有校验值的二进制。该哈希与二进制同源，挡的是传输损坏与镜像替换，不构成对上游发布本身的信任。
3. 下载落在 `%ProgramData%\ECYCloud\update`，DACL 与 `run` 目录同一套（仅 SYSTEM 与管理员），普通用户无法在校验通过后掉包。边下边算 SHA-256，超过 128 MiB 直接判废。
4. **下载与校验期间内核不停**：网络受限时只有隧道通着才取得到 GitHub。校验通过后先用暂存的新内核跑一次 `sing-box version` 自证可运行，再停内核、替换文件。
5. 替换按「旧文件改名为 `.bak` → 拷入新文件」进行，任一文件失败就把已换过的全部换回，绝不停在半新半旧的状态。文件集与 `scripts/fetch-kernel.ps1` 的 `singBox.files` 一致。
6. 服务不重启内核：替换完成后由 `ConnectionController.upgradeKernel` 按升级前的连接状态决定是否重连，期间「内核意外退出即自动重启」的重试链被显式摘掉，避免这次计划内的停机被当成崩溃。

`scripts/kernel.lock.json` 仍是**出包**时的唯一版本来源，升级只影响已装机器上的内核文件。

安装器 `[Files]` 对整个产物目录用 `ignoreversion`，即不比版本也不比时间戳、一律覆盖（自家 Flutter 与 Go 产物没有可靠的版本资源，去掉它会让新版程序装不上去），因此重装客户端会把内核重置成包内那一份。所以出客户端包前**必须先把 `kernel.lock.json` 抬到当时的最新正式版并回归测试**，否则手动升过内核的用户会被降级；`fetch-kernel.ps1` 会比对上游最新版并在落后时告警（查不到版本时只跳过，不阻断构建）。

## 客户端升级

客户端与内核的版本检查都在 `UpdateController`：启动后查一次，之后每 24 小时一次；首次失败时等隧道连上再补一次（GitHub 在部分网络下要走代理才通）。发现新版时在主界面弹一次窗告知，同一批版本不重复弹，常驻入口在设置 - 关于。

客户端自身的升级由 GUI 发起，不经特权服务：

1. 按 `Abi.current()` 取本机架构，在 `ECYCloud/ECYCloudClient` 的最新正式版里找资产 `ECYCloud-<版本>-windows-<arch>.exe`，命名与 `scripts/installer/ecycloud.iss` 的 `OutputBaseFilename` 同源。
2. 下载到 `%APPDATA%\ECYCloud\updates`，按 Releases API 的 `digest` 校验 SHA-256，缺校验值即中止——与内核升级同一条底线。
3. 安装包清单要求管理员权限，`CreateProcess` 会直接失败（`ERROR_ELEVATION_REQUIRED`），只能由原生侧 `installer.run` 走 `ShellExecuteEx`/`runas` 弹 UAC；用户拒绝提权则返回 false，客户端留在原版本。
4. 提权通过后客户端立刻 `exit(0)`：安装器认单实例互斥体 `Local\ECYCloud.SingleInstance`，GUI 不退出就装不上。内核与系统代理由服务的 `onClientGone` 收尾，不需要 GUI 自己先断开。
5. 覆盖安装时旧服务占着 `ecycloud-service.exe` 与 `sing-box.exe`，且 `install` 子命令遇到已注册的服务会报错，因此安装器在 `PrepareToInstall` 里先调旧版 `ecycloud-service.exe uninstall`（会停内核并还原系统代理），装完再由 `[Run]` 重新注册。

## 内核进程的停止

Windows 无法向子进程投递 `SIGINT`，服务无控制台也无法使用 `GenerateConsoleCtrlEvent`，因此停止内核只能 `TerminateProcess`。内核来不及执行自身清理，善后由服务承担（见下）。

## wintun

TUN 入站要求 `wintun.dll` 与 sing-box 二进制同目录。构建脚本从官方发布包按 SHA-256 校验后取出对应架构的 DLL 放进 `service/` 目录；**完整性校验属于构建期职责**，运行期 `wintun.ensure` 只检查文件存在、DLL 可加载、导出符号齐全，不重复算哈希，也不联网下载。

TUN 网卡名固定为 `ECYCloud`，`interface_name` 写入配置。`WintunCloseAdapter` 只移除由 `WintunCreateAdapter` 创建的网卡，被强杀后遗留的同名网卡无法靠"打开再关闭"删除，因此服务在内核退出后先探测存在性，再以"重新创建后关闭"的方式让驱动真正删掉它。网卡消失后其上的路由一并失效。

## TUN 入站与应用兼容性

`strict_route` 在 Windows 上是靠 WFP 过滤器实现的，sing-tun 的两个行为直接决定应用能不能跑：

- TUN 若没有 IPv6 地址，会在 `FWPM_LAYER_ALE_AUTH_CONNECT_V6` 挂一条**无条件 BLOCK**（`tun_windows.go`，`len(Inet6Address) == 0` 分支），除内核自身进程外全部 IPv6 连接被掐断，连 `::1` 也不通。把 `localhost` 解析成 `::1` 再做本地 IPC 的客户端（英雄联盟的 LCU、各类 Electron / CEF 壳）会直接起不来。因此 `address` **恒定同时下发 IPv4 与 IPv6**，用户设置里的「IPv6」只作用于 `dns.strategy`，不参与 TUN 地址。
- `auto_route` 会让 TUN 接管默认路由，本机、局域网、组播网段随之进隧道。`route_exclude_address` 排除 `127.0.0.0/8`、RFC1918 三段、`169.254.0.0/16`、`224.0.0.0/4` 及对应 IPv6 网段，这些前缀会从 TUN 路由集合里被减去（`BuildAutoRouteRanges`），仍走物理网卡，局域网联机与设备发现不受影响。

`strict_route` 的正向价值只有一条：阻断不经 TUN 的 53 端口查询以防 DNS 泄露。但它的实现是「除内核自身外一律 BLOCK」的粗粒度 WFP 过滤，官方文档在 Windows 段落自己写明 "Let unsupported network unreachable" 且 "may prevent some Windows applications (such as VirtualBox) from working properly"，维护者在 sing-box #3515 里也确认 "it is NOT enabled by default, and you should understand the consequence before enabling it"。已确诊的破坏面包括本机回环访问（#2096、#3515）与回环 IPC 型服务（#3039）。

因此 `strict_route` 与内核一致**默认关闭**（`option/tun.go` 的 `StrictRoute` 为裸 bool，不写即 false；官方 Windows 客户端也不暴露该开关），仅在设置里留给明确需要防 DNS 泄露、且确认本机应用不受影响的用户。`AppSettings` 的 schema 因此从 1 升到 2，迁移时只丢弃 `tun_strict_route` 一个键，其余设置保留。

`endpoint_independent_nat` 在 sing-box 1.13 已标记 `Deprecated: removed`（`option/tun.go`），下发不生效，不要再写进模板。

## 系统代理还原

系统代理写在 `Software\Microsoft\Windows\CurrentVersion\Internet Settings` 的 `ProxyEnable` / `ProxyServer` / `ProxyOverride`，改完调用 `InternetSetOption` 的 `INTERNET_OPTION_SETTINGS_CHANGED` 与 `INTERNET_OPTION_REFRESH` 通知系统。

服务以 `LocalSystem` 运行，`HKCU` 指向 SYSTEM 自己的 hive，直接写会写错地方。因此服务用请求里的 `pid` 打开 GUI 进程令牌取其用户 SID，落到 `HKEY_USERS\<SID>\...`。

不用 `WTSQueryUserToken` 取控制台会话用户：那需要 `SE_TCB_NAME`（只有 SYSTEM 有），`debug` 模式无法本地验证，也认不出跑在远程桌面会话里的 GUI。

SID 一并存进快照，还原时不依赖当时是否有人登录。

设置前把原值写入快照文件 `%ProgramData%\ECYCloud\proxy-snapshot.json`，含原值、用户 SID、写入时间与写入方 PID。值原本不存在时记为 `null`，还原时删除而不是写回空串。三条还原路径：

| 路径 | 还原方式 |
| ---- | ---- |
| 正常退出 | GUI 发 `proxy.restore`，服务按快照还原并删除快照 |
| GUI 崩溃 / 被强杀 | 服务用请求里的 `pid` 持有 GUI 进程句柄，`WaitForSingleObject` 触发后停内核并按快照还原 |
| 服务自身被强杀或掉电 | 快照文件残留；服务下次启动时自检，发现快照存在即还原并删除 |

启动自检在服务 `SERVICE_START_PENDING` 阶段完成，早于任何 GUI 连接，因此重启电脑后打开浏览器前系统代理已恢复。

GUI 侧也在启动时调 `proxy.state`，若发现"服务认为代理已还原但注册表仍指向本机端口"，提示用户一键修复。

## 架构支持

x64 与 arm64 分别构建，各自打包对应架构的 sing-box 二进制与 `wintun.dll`。不提供 x86 32 位版本。

arm64 上 Flutter Windows 桌面产物为原生 arm64；若目标机器缺少 arm64 运行库，用 x64 包在 arm64 上通过模拟运行也可用，但 TUN 性能下降，不作为默认分发。

## 单实例与托盘

单实例用命名互斥体 `Local\ECYCloud.SingleInstance`。不用 `Global\` 前缀：创建全局命名对象需要 `SeCreateGlobalPrivilege`，普通用户没有；而单实例本来就只需在当前登录会话内唯一。

第二个实例检测到互斥体已存在时，用 `FindWindow` 找到首个实例的窗口（缩在托盘里也找得到），发一条注册消息 `ECYCloud.ShowWindow` 让它显示，然后自行退出。为此不额外开命名管道。

窗口标题为「ECY Cloud 网络助手 <版本号>」，版本号取编译期注入的 `FLUTTER_VERSION`（`flutter build --build-name`，与安装包版本同源）。安装器与卸载器判断「程序正在运行」认的是上述互斥体（`AppMutex`）而不是窗口标题，装新版时才能匹配到旧版窗口。

托盘图标、开机自启（当前用户 `Run` 键，仅拉起 GUI，不需要提权）、窗口关闭到托盘均在 Windows runner 的 C++ 侧实现，Dart 通过 MethodChannel `ecycloud/platform` 调用：

| 方法 | 作用 |
| ---- | ---- |
| `tray.install` / `tray.remove` | 增删托盘图标 |
| `tray.closeToTray` | 设置关闭窗口时是最小化到托盘还是退出 |
| `tray.state` | Dart 下推连接态与系统代理 / TUN 开关，供菜单渲染文案与勾选 |
| `autostart.get` / `autostart.set` | 读写当前用户 `Run` 键 |

右键菜单项为「连接 / 断开连接（连接中显示取消连接）」「系统代理」「TUN 模式」「显示主界面」「退出」。C++ 侧不持有业务状态机，命中菜单只通过 `tray.action` 回调上报动作名，连不连、开不开由 Dart 的 `ConnectionController` 决定，避免两侧状态分叉。

托盘不可用时不吞 `WM_CLOSE`，否则窗口再也关不掉。

## 上线前必须验证

- DNS 无泄漏：TUN 开启后 `nslookup` 与浏览器 DNS 均走内核
- IPv6：系统无 IPv6 时不产生连接错误；有 IPv6 时行为与配置一致
- 断网、切换 Wi-Fi / 有线后能自愈
- 三条还原路径下系统代理与路由完全还原，`route print` 无残留
