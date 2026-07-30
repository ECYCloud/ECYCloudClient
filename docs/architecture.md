# 架构

## 分层

```
┌─────────────────────────────────────────────┐
│ ui/            Flutter 界面                  │
├─────────────────────────────────────────────┤
│ state/         AppState / ConnectionState    │  状态机、崩溃恢复调度
├─────────────────────────────────────────────┤
│ domain/config  ProfileAssembler              │  面板配置 + 本地模板 → 落盘配置
│ domain/kernel  KernelController（抽象）       │
│ domain/platform PlatformService（抽象）       │
├─────────────────────────────────────────────┤
│ data/api       PanelApiClient                │  账号登录、配置下发
├─────────────────────────────────────────────┤
│ platform/windows                             │  唯一已实现的平台层
│   ├ ServiceKernelController  ← KernelController
│   └ WindowsPlatformService   ← PlatformService
├─────────────────────────────────────────────┤
│ native/windows/service  Go 特权服务           │  仅平台能力，无业务判断
├─────────────────────────────────────────────┤
│ sing-box 官方二进制（子进程）                  │
└─────────────────────────────────────────────┘
```

业务逻辑（登录状态、配置组装、订阅刷新、连接状态机、重启退避）全部位于 `domain/` 与 `state/`，不含任何平台条件分支。平台差异只通过 `KernelController` 与 `PlatformService` 两个抽象注入。

## 跨平台扩展点

新增平台时只需要：

1. 实现 `KernelController`（`domain/kernel/kernel_controller.dart`）
2. 实现 `PlatformService`（`domain/platform/platform_service.dart`）
3. 在 `platform/platform_factory.dart` 注册

`ProfileAssembler` 已按平台参数化：`LocalTemplateOptions` 描述该平台的 inbound / tun / dns 取值，Android 未来只需提供另一组 options，配置生成逻辑本身不改。

未实现平台的工厂分支抛 `UnsupportedError`，不留半成品实现。

## 内核集成形态

Windows 采用**子进程**形态：`sing-box run -c config.json`。理由与 AGENTS.md 一致——与官方桌面客户端行为对齐，且进程隔离便于崩溃恢复。桌面端不使用 FFI 把内核链入 Flutter 进程。

Android 将来采用 `libbox.aar` 内嵌 + `VpnService`，届时 `KernelController` 的 Android 实现走 Platform Channel，`ProfileAssembler` 复用。

## 配置模型

单一事实源是 sing-box JSON，客户端内不存在第二套配置语义。

职责切分（AGENTS.md 硬性约束）：

| 配置段 | 归属 |
| ---- | ---- |
| `outbounds` | 面板下发 |
| `route.rules` / `route.rule_set` / `route.final` | 面板下发 |
| `log` / `dns` / `inbounds` / `experimental` | 客户端本地模板 |
| `route.auto_detect_interface` / `route.default_domain_resolver` | 客户端本地模板（依赖本地 dns 段与网卡） |
| `ntp` | 面板下发，客户端不覆盖 |

`ProfileAssembler` 只做**整段替换**，不做深度合并，两侧不存在互相覆盖的模糊地带。面板配置里出现的 `log` / `dns` / `inbounds` / `experimental` 一律丢弃。

落盘前调用 `sing-box check -c <file>` 校验，失败则保留上一份可用配置并上报错误。格式化用 `sing-box format`。

### rule_set

远程规则集由面板模板决定。当前锁定内核 v1.13.15 不支持 `initial_path` 与 `http_client`（两者自 v1.14.0 引入，v1.14.0 目前仍是 beta），因此这两项在当前版本不适用；升级到 v1.14.x 稳定版时，需要同步修改面板侧 `subscription_profile` 模板而非客户端。

## 状态机

```
disconnected ──connect──> starting ──kernel ready──> connected
     ▲                       │                          │
     │                       └──── failed ──────────────┤
     │                                                  │
     └──── stopping <───── disconnect / 内核异常退出 ─────┘
```

内核异常退出触发自动重启，退避序列 1s / 2s / 4s / 8s / 16s / 30s（上限 30s），连续失败 6 次后停在 `failed` 并保留最后 200 行内核日志。用户手动断开不触发重启。

## 热重载边界

`sing-box run` 的配置重载只由 `SIGHUP` 触发（`cmd/sing-box/cmd_run.go`），Windows 无法向子进程投递该信号，因此**配置文件层面的热重载在 Windows 上不可用**。

可以不重启进程完成的操作，全部通过 Clash API：

| 操作 | 手段 | 是否重启 |
| ---- | ---- | ---- |
| 切换节点（selector 成员） | `PUT /proxies/{selector}` | 否 |
| 切换路由模式 Rule / Global / Direct | `PATCH /configs` | 否 |
| 节点延迟测试 | `GET /proxies/{name}/delay` | 否 |
| 面板 `outbounds` / `route` 更新 | 重写配置文件 | 是 |
| 本地模板变更（TUN 开关、端口、DNS、内核日志级别） | 重写配置文件 | 是 |

内核日志级别不直接取用户设置：内核固定不低于 `info`，否则它只在出错时说话，日志页会退化成一堵错误噪声墙，首次连接时的 rule-set 下载进度也拿不到。设置里的「日志落盘级别」只把门槛用在客户端写日志文件这一步（`Logger.level`），因此在 `info` 及以上各档之间来回调不会重启内核；调到 `debug` / `trace` 才会连带把内核也调啰嗦并触发重启。

`ConnectionController` 在应用配置前对比面板下发的原始配置，完全相同则跳过重启。不比对装配后的 JSON：装配会给控制面重新分配端口与 secret，装配结果每次都不同。

重启走 `_restartKernel`：期间不还原系统代理（随即会按同一端口设回去，中间还原一次只会让应用多断一次网，且这段时间流量绕过代理直连），失败时才还原。
