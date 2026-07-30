# 控制面选型

## 结论

Windows 桌面端使用 **sing-box 的 `experimental.clash_api`（REST over TCP）** 作为唯一控制面。不启用 `v2ray_api`，不引入 libbox `CommandServer`。

## 为什么不用 libbox CommandServer

AGENTS.md 的优先级是「优先使用 libbox 的 `CommandServer` / `CommandClient`」，但该能力在当前集成形态下不存在：

- `CommandServer` 只实现在 `experimental/libbox` 包内，由 gomobile bind 出的 `libbox.aar` / `Libbox.xcframework` 暴露给 Android / Apple 平台宿主。
- 官方 `sing-box` CLI 二进制不注册也不启动 `CommandServer`，没有任何命令行开关或配置项可以打开它。

Windows 端按 AGENTS.md 固定为「子进程 + 控制通道」形态，用的就是官方 CLI 二进制。要使用 `CommandServer` 就必须改为 libbox 内嵌（FFI 同进程），而 AGENTS.md 明确要求这一改动须先提方案评审，且同进程链接会加重 GPL 衍生作品判定。

因此在当前形态下，`clash_api` 是唯一可用的控制面。AGENTS.md 也已为此留了口子：「桌面子进程模式下可启用 `with_clash_api` 提供 REST 控制」。

Android 将来走 libbox 内嵌时使用 `CommandServer`，与桌面端不冲突——两者是不同平台的不同集成形态，同一进程内始终只有一套控制面。

## 端口与密钥约定

| 项 | 取值 |
| ---- | ---- |
| 监听地址 | `127.0.0.1`，仅回环，不监听 `0.0.0.0` |
| 端口 | 每次启动由客户端向系统申请空闲端口后写入配置，默认起始探测 `19090`；不复用面板模板里的 `9090`，避免与用户已装的其它客户端冲突 |
| `secret` | 每次启动生成 32 字节随机值的 hex，仅存在于内存与当次配置文件中 |
| `external_ui` | 不配置，不下载任何面板 UI |
| `access_control_allow_origin` | 不配置，默认不允许跨源 |
| `default_mode` | `Rule` |

端口与密钥由 Dart 侧生成，随配置文件一起交给特权服务；Dart 侧直接连 `http://127.0.0.1:<port>`，不经过特权服务转发。

## 用到的端点

| 用途 | 端点 |
| ---- | ---- |
| 内核就绪探测 | `GET /version` |
| 出站与分组列表 | `GET /proxies` |
| 切换 selector 选中项 | `PUT /proxies/{name}` |
| 单节点延迟测试 | `GET /proxies/{name}/delay` |
| 让 urltest 分组立即重选 | `GET /group/{name}/delay` |
| 路由模式读写 | `GET /configs` / `PATCH /configs` |
| 连接列表、流量与内存 | `GET /connections` / `DELETE /connections` |
| 内核日志 | `GET /logs?level=<level>`（chunked JSON 流） |
| goroutine 数量 | `GET /debug/memory`（`experimental.debug.listen`，不在 Clash API 上） |

鉴权统一使用 `Authorization: Bearer <secret>`；`experimental.debug` 那个口没有鉴权，只能绑 `127.0.0.1`。

`GET /connections` 的非 websocket 请求是一次性快照，同一份响应里已带 `memory` 与逐连接计数（`trafficontrol/manager.go` 的 `Snapshot.MarshalJSON`），所以首页的内存、流量、连接数与连接页的明细共用这一次轮询（1 秒一次）。goroutine 数量 Clash API 不提供，只有 `experimental.debug` 的独立监听口有（`debug_http.go`），该口给的内存口径与 `/connections` 不同，因此只取 `goroutines` 一个字段。

## 首页流量只算代理

`GET /traffic` 与快照里的 `uploadTotal` / `downloadTotal` 是**全量**：规则判给 direct 的国内流量、TUN 兜底的本机流量都算在里面，用户看到的数字与套餐消耗对不上。所以这两个数据源都不用，首页的速率与累计改为按连接自行汇总：每次轮询把逐连接的 `upload` / `download` 与上一份快照差分，只累加走代理的连接，速率 = 本次增量 / 两次快照的间隔，走势图的每个采样点就是一次轮询。

判定走没走代理看 `chains` 的首项（该字段是反转过的出站链，首项即最终落地的出站）在 `/proxies` 里的**类型**，`Direct` / `Block` / `Reject` / `DNS` 不算——`clashapi/proxies.go` 的 `proxyInfo()` 把 block 显示成 `Reject`，其余取 `constant.ProxyDisplayName`。按类型判而不是按 tag，面板把直连出站改名也不受影响。

代价是每次轮询之间连接关闭会漏掉最后一小段字节，以及累计量随内核重启归零；面板侧的用量以服务端统计为准，这里只反映本次连接。

## 延迟测试端点的选型与约束

这两个端点测的是到探测地址的**毫秒延迟**，与带宽无关，界面文案统一用「延迟测试」，不写「测速」。

### 延迟这个数里含什么

`common/urltest/urltest.go` 的 `URLTest` 计时口径是固定的，客户端无法改：

```go
start := time.Now()
instance, err := detour.DialContext(ctx, "tcp", host:port)  // 含主机名解析 + 代理握手
if N.NeedHandshakeForWrite(instance) { start = time.Now() } // 惰性握手协议在此重置起点
client.Do(HEAD link)                                        // https 则含到目标站的 TLS 握手 + 一次 HEAD
t = time.Since(start)
```

由此可确定三件事：

- **这个数至少是 2 个 RTT，与「TCP ping」不是同一个指标。** 拨号之外还必然含一次 HTTP HEAD 的往返，https 再加一次 TLS 握手，不能和只测 TCP 握手的工具横向比。
- **明文 HTTP 能省掉 TLS 那一个往返，但要绕过内核的一处过滤。** 两个 delay 端点都有 `strings.HasPrefix(url, "http://")` 就丢弃并回退到内置 `https://www.gstatic.com/generate_204` 的分支（`clashapi/proxies.go`、`clashapi/api_meta_group.go`）。该判断区分大小写，而 `url.Parse` 与 `http.NewRequest` 都会把 scheme 转小写，所以 scheme 写成大写就能原样传下去。客户端因此传 `HTTP://cp.cloudflare.com/generate_204`。真内核实测：`url=http://127.0.0.1:1/` 返回 `{"delay":238}`（说明换成了默认地址），`url=HTTP://127.0.0.1:1/` 在 25ms 内返回 `An error occurred in the delay test`（说明按传入地址拨号）；同机对比明文 HTTP 中位 593ms、https 中位 729ms。上游若改成大小写不敏感，只是退回 https 默认地址、数字变大，不会坏。
- 探测失败时内核会**删除**该出站的延迟记录，界面据此显示「超时」；内核自身的周期探测一旦重新写入延迟，客户端就清掉本地的不可用标记。

### ws 的 early data 会让套 CDN 的节点延迟虚高

上面那行 `NeedHandshakeForWrite` 的重置是关键：VLESS/VMess 的请求头是首次写入时才发的（`sing-vmess` 的 `Conn.NeedHandshakeForWrite`），所以**普通节点**的 TCP + TLS 握手发生在 `DialContext` 里、被重置甩掉，报的数只含「代理请求头 + 一次 HEAD」。

而 `max_early_data > 0` 时 ws 客户端的 `DialContext` 直接返回一个空的 `EarlyWebsocketConn`，什么都不做（`transport/v2raywebsocket/client.go`）：TCP、TLS、WebSocket Upgrade 全部推迟到首次写入，也就是全部落在计时窗口内。套 Cloudflare 这类 CDN 时 Upgrade 还要经边缘回源站，等于多算两三个往返，同一批节点里 CDN 节点因此高出好几倍，`urltest` 也永远不会选中它们。

面板对所有 ws 节点都下发 `max_early_data: 2048` + `early_data_header_name`（`Website/src/Utils/AppURI.php`）。客户端在装配配置时把这两个键剥掉（`ProfileAssembler`），代价是真实连接少了 early data 省下的那一个往返，换来各节点延迟同口径、自动选择可用。

### 分组自身读不到延迟

`proxyInfo` 读延迟用的是**分组自身的 tag**（`LoadURLTestHistory(adapter.OutboundTag(detour))`），而 `getProxyDelay` 测完是存到 `group.RealTag(proxy)` 解析出的**叶子节点**上。两边键不一致，所以对分组测完延迟，`GET /proxies` 里这个分组的 `history` 依然是空的。

面板下发的分组会把「主节点」「自动选择」这类分组当成成员，界面上这些成员因此永远显示不出延迟。客户端照内核的办法处理：顺着 `now` 把分组解析到叶子节点（`ConnectionController.resolveNode`），延迟、探测进度、不可用标记一律以叶子名为键，并在成员上标出 `→ 叶子节点` 让选中项可见。

### 分组延迟测试为什么逐个打

`/group/{name}/delay` 挂载在 `setupMetaAPI()` 而非 `server.go` 的 Mount 列表里（`clashapi/api_meta.go`），1.13.14 起可用。它内核侧按并发 10 批量测，但**不适合**用来做界面上的分组延迟测试：

- 它是整批测完一次性返回，界面在整批结束前看不到任何进度；
- 用**一个**上下文超时罩住整批，而单个成员的 HTTP 超时是 `C.TCPTimeout`（15s，`constant/timeout.go`），成员一多超时给不够就会把整批掐断，表现为「分组延迟测不出来」；
- 响应体 `{tag: 延迟}` **只含探测成功的成员**，且 `urltest` 分组内部以 `force=false` 调用、会静默跳过距上次探测不足 `interval` 的成员——失败与跳过在返回值里都是缺项，分不开；
- 对 `urltest` 分组它还会忽略传入的 `url` 与 `timeout`。

因此客户端改为把成员解析到叶子节点后**逐个打 `/proxies/{name}/delay`**，并发 8（与内核同量级，再高会互相抢带宽把延迟测虚高），测完一个就回填一个，界面上哪些节点在转圈、哪些已出数一目了然（`ConnectionController._testNodes`）。

`/group/{name}/delay` 仍保留一处用途：`urltest` 分组测完后调它一次触发重选。此时全部成员都在 `interval` 内，`urlTest` 会全部跳过、直接走到 `performUpdateCheck()` 重算 `selectedOutboundTCP/UDP`，几乎零开销。这是外部唯一能让「自动选择」马上跟上延迟的手段（`PUT /proxies/{name}` 对非 `selector` 分组直接返回 400，客户端不得替内核选节点）。`selector` 分组的选中项仍归用户，不因一次延迟测试被覆盖。

## 连接与日志的容量上限

内核侧的事实：

- 活跃连接在内存里，`GET /connections` 只返回活跃项；已关闭的连接内核自己留最近 **1000** 条（`trafficontrol/manager.go` 的 `closedConnectionsLimit`），但只有 libbox 命令接口取得到，Clash API 没有这个端点。客户端因此按快照差分自己补一份，上限对齐内核的 1000 条（`ConnectionController._applyConnections`）。
- `log.output` 是纯 append 打开（`log/observable.go` 的 `O_APPEND|O_CREATE|O_WRONLY`），**既不轮转也没有大小上限**；`/logs` 订阅侧只有 128 条的缓冲（`observable.NewSubscriber[Entry](128)`）。

客户端不照抄这个无上限的写法：内核输出在服务侧留 800 行环形缓冲（`logbuf.go`），`service.log` 满 2 MiB 轮转，客户端自身日志内存里留 2000 条、按天分文件并只保留最近 7 天（`Logger._retentionDays`）。

## 不启用 v2ray_api 的理由

`clash_api` 已覆盖流量统计与连接列表，`v2ray_api` 的 gRPC stats 会重复同一份数据，并额外占用一个监听端口。同时启用两套控制面为 AGENTS.md 禁止事项。
