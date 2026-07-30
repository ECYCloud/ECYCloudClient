# 客户端 API 契约

服务端实现位于 `Website/src/Controllers/Client/`，路由注册在 `Website/app/routes.php`，鉴权中间件为 `Website/src/Middleware/ClientApi.php`。

面板此前只有网页 Cookie 会话与订阅链接两种入口，没有面向客户端的接口，因此新增了这一组。它不替代订阅链接，两者互不影响。

## 基址

`https://<面板域名>/api/client/v1`

本客户端只服务自家面板，不是通用第三方软件，**面板地址在构建期确定，登录界面不提供输入框**。

地址默认读取本地文件 `config/panel.json` 里的 `panelUrl`（人工誊抄自网站设置中心的 `website_url`，不联网、不自动同步），也可用 `-PanelUrl` 显式覆盖（`build-windows.ps1`），通过 `--dart-define=ECYCLOUD_PANEL_URL` 注入。客户端源码里不留任何域名字面量，`app/lib/core/app_config.dart` 只声明这个编译期常量。

两者都没有就直接构建失败，不回退默认值。出包机是仓库副本、连不到面板数据库，因此这个值不能在构建时实时查库；网站后台改了域名，必须手动同步改 `config/panel.json`，没有任何机制会自动提醒或代劳。

## 鉴权

除登录外，所有请求带 `Authorization: Bearer <token>`。

token 由登录接口签发，库内只存 SHA-256（表 `client_token`，建表语句见 `Website/sql/2026_07_28_client_token.sql`），有效期取面板设置项 `rememberMeDuration`（天）。同一 `device_id` 再次登录会顶掉旧 token。

令牌失效统一返回 `401`，客户端收到后清除本地凭据并回到登录页。

## 响应约定

```json
{ "ret": 1, "msg": "", "data": {} }
```

`ret` 为 `1` 表示成功，`0` 表示失败，`2` 表示需要补充两步验证码。失败时 `msg` 为可直接展示给用户的中文文案。

## POST /auth/login

请求体（JSON）：

| 字段 | 必填 | 说明 |
| ---- | ---- | ---- |
| `email` | 是 | 登录邮箱 |
| `passwd` | 是 | 登录密码 |
| `code` | 否 | 两步验证码，账号开启 2FA 时必填 |
| `platform` | 否 | `windows` / `macos` / `linux` / `android` |
| `device_id` | 否 | 客户端生成并持久化的设备标识 |
| `device_name` | 否 | 设备名 |
| `app_version` | 否 | 客户端版本 |

成功：

```json
{
  "ret": 1,
  "msg": "登录成功",
  "data": {
    "token": "...",
    "expires_at": "2026-08-27T11:45:00+08:00",
    "user": { }
  }
}
```

账号开启两步验证但未提交 `code` 时返回 `401` 且 `ret = 2`，客户端据此展示验证码输入框。

与网页登录共用 IP 归属地限制、登录失败锁定、两步验证锁定、邮箱黑名单与密码哈希渐进升级；不做人机验证（桌面客户端无法承载 Turnstile），暴力破解由既有的登录锁定机制拦截。

## POST /auth/logout

删除当前 token。

## GET /user/profile

```json
{
  "ret": 1,
  "data": {
    "id": 1,
    "email": "a@b.c",
    "user_name": "...",
    "class": 1,
    "class_expire": "2026-12-31 00:00:00",
    "expire_in": "2027-12-31 00:00:00",
    "upload": 0,
    "download": 0,
    "transfer_enable": 0,
    "node_speedlimit": 0,
    "node_connector": 0,
    "online_ip_count": 0,
    "money": 0,
    "last_check_in_time": null,
    "able_to_checkin": true
  }
}
```

`node_connector` 是同时在线 IP 数上限（`0` 为不限制），`online_ip_count` 是当前在线 IP 数，与面板用户中心、`User::onlineIpCount()` 同一口径。

## GET /config/sing-box

返回该账号有权限使用的完整 sing-box 配置，内容与订阅链接 `?sing-box=1` 完全一致，走 `LinkController::getSingBox()` 同一份生成逻辑。

```json
{
  "ret": 1,
  "data": {
    "config": { },
    "update_interval": 86400,
    "group_icons": { "OpenAI": "https://图标站/OpenAI.png" },
    "flag_regex": "/[\\p{L}\\p{N}]+/u",
    "userinfo": { "upload": 0, "download": 0, "transfer_enable": 0, "expire": 1767110400 }
  }
}
```

面板订阅总开关关闭时返回 `503`。

`group_icons` 与 `flag_regex` 是**界面元信息**，不能塞进 `config`（sing-box 遇到未知字段会报错），所以与 `config` 平级：

- `group_icons`：策略组 tag => 图标地址，取自 sing-box 模板的 `x-sspanel.group_icons`（`x-sspanel` 整段在下发前被 `LinkController::getSingBox()` 去掉，因此 `ConfigController` 单独读模板）。客户端首次显示时下载并落盘缓存到 `%APPDATA%\ECYCloud\icons`，之后只读本地文件；没配或取不到的组退回内置图形。**只读 sing-box 那一行**，不碰 clash / stash / surge / surfboard / quantumultx / loon 的配置。
- `flag_regex`：设置项原文（PHP 形态，含定界符与修饰符）。面板不存节点国家字段（`node` 表无对应列），`Node::getNodeFlag()` 就是用它从节点名取词再查 `config/regions.json`；客户端照搬同一套算法，映射表随包（`app/assets/regions.json`），并在取词前先认名字自带的国旗 emoji。客户端里没有任何关键词表。

客户端拿到 `data.config` 后**不会原样落盘**：按 AGENTS.md 的配置职责切分，只保留 `outbounds`、`route.rules`、`route.rule_set`、`route.final` 与 `ntp`，其余段由本地模板注入。详见 `docs/architecture.md`。

## 未实现

版本检查与更新分发暂未提供接口。面板已有 `tutorial_software` 表与 `ClientDownloadVersion.json` 版本快照，接入时在此文档补充端点，不要让客户端直接读取那两处内部结构。
