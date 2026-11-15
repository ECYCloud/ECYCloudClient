package com.ecycloud.client

import android.content.Context
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import org.json.JSONObject
import java.io.File

class LogRing(private val limit: Int) {
    private val lines = ArrayDeque<String>()
    private var first = 0
    private var next = 0

    @Synchronized
    fun append(line: String) {
        lines.addLast(line)
        next++
        while (lines.size > limit) {
            lines.removeFirst()
            first++
        }
    }

    @Synchronized
    fun since(cursor: Int): Pair<List<String>, Int> {
        val from = cursor.coerceAtLeast(first)
        if (from >= next) {
            return Pair(emptyList(), next)
        }
        return Pair(lines.drop(from - first).toList(), next)
    }
}

object BoxState {
    // 以下可变字段与日志缓冲只在 :kernel 进程内有效。界面进程有各自一份静态副本，
    // 读到的永远是初值，要状态必须经 KernelClient 取
    val logs = LogRing(800)

    @Volatile
    var running = false

    // 内核常驻但不接管出口时 running 同样为真，隧道在不在跑只有这个字段说了算
    @Volatile
    var takeover = false

    @Volatile
    var starting = false

    @Volatile
    var startedAt = 0L

    @Volatile
    var error: String? = null

    @Volatile
    var exitCode: Int? = null

    // 系统只有一个 VPN 槽位，授权被别的应用抢走后自动重启只会反复弹授权框，上层不得重试
    @Volatile
    var revoked = false

    // 不置位则界面进程会把内核消失当成崩溃并自动重连，表现为隧道关不掉
    @Volatile
    var stoppedByUser = false

    // 本进程内核已绑定的登录会话；mihomo 的 cache.db 按进程只打开一次，换会话只能换进程
    @Volatile
    var session: String? = null

    private val sessionKeyPattern = Regex("[a-f0-9]{64}")

    // 与 Dart CredentialStore 的 session_key 字段同名，退出登录时随令牌一起删掉。
    // 旧版凭据没有这个字段：按 Dart AuthController._accountDirKey 同一算法补算，界面下次启动时会写回
    fun sessionKey(context: Context): String? {
        val saved = runCatching {
            JSONObject(File(context.filesDir, "credentials.json").readText())
        }.getOrNull() ?: return null
        saved.optString("session_key").takeIf(sessionKeyPattern::matches)?.let { return it }
        val email = saved.optString("email").trim().lowercase()
        if (saved.optString("token").isEmpty() || email.isEmpty()) {
            return null
        }
        val key = AccountKey.of(saved.optString("site_origin"), BuildConfig.SITE_URL, email) ?: return null
        adoptLegacyRunDir(context, key)
        return key
    }

    // 旧版的共享运行目录归这个账号：搬进账号目录，开机自启与磁贴才能找到原配置
    fun adoptLegacyRunDir(context: Context, key: String) {
        val legacy = File(context.filesDir, "run")
        val target = runDir(context, key)
        if (stat(legacy)?.let { OsConstants.S_ISDIR(it.st_mode) } != true || stat(target) != null) {
            return
        }
        target.parentFile?.mkdirs()
        runCatching { Os.rename(legacy.path, target.path) }
    }

    // 与 Dart AppPaths.sessions 逐字一致
    fun sessionDir(context: Context, key: String): File = File(File(context.filesDir, "sessions"), key)

    fun runDir(context: Context, key: String): File = File(sessionDir(context, key), "run")

    fun configFile(context: Context, key: String): File = File(runDir(context, key), "config.json")

    // 退出时删掉带节点凭据的配置，规则集与 cache.db 留给同账号下次登录
    fun dropRuntimeSecrets(context: Context, key: String) {
        runDir(context, key).listFiles()?.filter {
            it.name == "config.json" || (it.name.startsWith("ecy-panel-") && it.name.endsWith(".json"))
        }?.forEach { check(it.delete()) { "不能删除旧账户配置" } }
    }

    // 节点已写成各自的文件，内核按 path 读取；payload 留在配置里只会被内核当作后备节点再解析一遍，
    // 所以落盘与交给内核的都是去掉 payload 的配置。重建服务时读回的落盘配置没有 payload，沿用已写好的节点文件
    @Synchronized
    fun writeConfig(context: Context, key: String, raw: String): String {
        val config = JSONObject(raw)
        val providers = config.optJSONObject("proxy-providers")
        val root = runDir(context, key)
        root.mkdirs()
        require(stat(root)?.let { OsConstants.S_ISDIR(it.st_mode) } == true) { "运行目录类型不可信" }
        val files = mutableMapOf<String, String>()
        var stripped = false
        providers?.keys()?.forEach { name ->
            if (name.startsWith("ecy-panel-")) {
                require(name == "ecy-panel-nodes" || Regex("ecy-panel-[a-f0-9]{64}").matches(name)) {
                    "节点文件名称不合法"
                }
                val provider = providers.getJSONObject(name)
                require(provider.getString("type") == "file" && provider.getString("path") == "$name.json") {
                    "节点文件配置不合法"
                }
                val payloadKeys = provider.keys().asSequence().filter { it.equals("payload", ignoreCase = true) }.toList()
                if (payloadKeys.isEmpty()) {
                    require(stat(File(root, "$name.json"))?.let { OsConstants.S_ISREG(it.st_mode) && it.st_nlink == 1L } == true) {
                        "节点文件缺失"
                    }
                    return@forEach
                }
                val payload = provider.getJSONArray("payload")
                require(payload.length() > 0) { "节点文件不能为空" }
                val content = JSONObject().put("proxies", payload).toString()
                require(content.toByteArray(Charsets.UTF_8).size <= maxRunFileBytes) { "节点文件过大" }
                files["$name.json"] = content
                payloadKeys.forEach { provider.remove(it) }
                stripped = true
            }
        }
        files.forEach { (name, content) ->
            val target = File(root, name)
            stat(target)?.let {
                require(OsConstants.S_ISREG(it.st_mode) && it.st_nlink == 1L) { "节点文件类型或链接数不可信" }
                if (target.readText() == content) return@forEach
            }
            val temp = File.createTempFile(".ecy-provider-", ".tmp", root)
            try {
                temp.writeText(content)
                Os.rename(temp.path, target.path)
            } finally {
                temp.delete()
            }
        }
        // AOSP JSONObject 会把 / 编成 \/，mihomo 的 yaml.v3 不认该转义
        val written = if (stripped) config.toString(2).replace("\\/", "/") else raw
        configFile(context, key).writeText(written)
        return written
    }

    private fun stat(file: File) = try {
        Os.lstat(file.path)
    } catch (e: ErrnoException) {
        if (e.errno != OsConstants.ENOENT) throw e
        null
    }

    fun cacheReady(context: Context): Boolean = session?.let { key ->
        File(runDir(context, key), "cache.db").let { it.isFile && it.length() > 0 }
    } ?: false

    fun takesOverExit(config: String): Boolean = runCatching {
        JSONObject(config).getJSONObject("tun").getBoolean("enable")
    }.getOrDefault(false)

    private const val maxRunFileBytes = 8L shl 20

    fun resolveWithin(base: File, relative: String): File {
        val rel = relative.trim()
            .replace('\\', '/')
            .removePrefix("./")
            .trim('/')
        require(rel.isNotEmpty() && !rel.contains("..") && !File(rel).isAbsolute) {
            "非法路径"
        }
        val root = base.canonicalFile
        val file = File(root, rel).canonicalFile
        require(file.path == root.path || file.path.startsWith(root.path + File.separator)) {
            "非法路径"
        }
        return file
    }

    // 与桌面 kernel.read 同语义
    fun readRunFile(context: Context, relative: String): String {
        val key = sessionKey(context) ?: error("尚未登录")
        val file = resolveWithin(runDir(context, key), relative)
        require(file.isFile) { if (file.exists()) "不能读取目录" else "文件不存在" }
        require(file.length() <= maxRunFileBytes) { "文件过大（超过 ${maxRunFileBytes shr 20} MiB）" }
        return file.readText()
    }
}
