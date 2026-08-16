package com.ecycloud.client

import android.content.Context
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

    // 内核常驻但不接管出口时 running 同样为真（控制面在线，只是没有隧道）。
    // 「隧道到底在不在跑」只有这个字段说了算，磁贴的亮灭按它来
    @Volatile
    var takeover = false

    // 服务已在前台、内核还没起来的那段时间。磁贴 onClick 据此忽略重复点击
    @Volatile
    var starting = false

    // 内核起来的时刻。界面比内核起得晚时（开机自启、磁贴、进程重建）只有这里
    // 知道连接是什么时候建立的，接管后要靠它显示已连接时长
    @Volatile
    var startedAt = 0L

    @Volatile
    var error: String? = null

    @Volatile
    var exitCode: Int? = null

    // 系统撤销 VPN 授权与内核崩溃是两回事：前者是用户切到了别的 VPN，自动重启
    // 只会反复弹授权框去抢回槽位，因此单独标记，让上层不要重试
    @Volatile
    var revoked = false

    // 通知栏磁贴关掉内核时置位。界面进程可能还活着，不告诉它这是用户的意思，
    // 它会把内核消失当成崩溃并自动重连，表现为隧道关不掉
    @Volatile
    var stoppedByUser = false

    fun runDir(context: Context): File = File(context.filesDir, "run")

    fun configFile(context: Context): File = File(runDir(context), "config.json")

    // 内核把 cache.db 放在 -d 目录，即 runDir
    fun cacheReady(context: Context): Boolean =
        File(runDir(context), "cache.db").let { it.isFile && it.length() > 0 }

    /** 这一份配置要不要接管出口。装配逻辑全端共用，Kotlin 侧只读结论 */
    fun takesOverExit(config: String): Boolean = runCatching {
        JSONObject(config).getJSONObject("tun").getBoolean("enable")
    }.getOrDefault(false)

    private const val maxRunFileBytes = 8L shl 20

    /** 读取 run 目录下相对路径；拒绝绝对路径与 `..`。与桌面 `kernel.read` 同语义。 */
    fun readRunFile(context: Context, relative: String): String {
        val rel = relative.trim()
            .replace('\\', '/')
            .removePrefix("./")
            .trim('/')
        require(rel.isNotEmpty() && !rel.contains("..") && !File(rel).isAbsolute) {
            "非法路径"
        }
        val base = runDir(context).canonicalFile
        val file = File(base, rel).canonicalFile
        require(file.path == base.path || file.path.startsWith(base.path + File.separator)) {
            "非法路径"
        }
        require(file.isFile) { if (file.exists()) "不能读取目录" else "文件不存在" }
        require(file.length() <= maxRunFileBytes) { "文件过大（超过 ${maxRunFileBytes shr 20} MiB）" }
        return file.readText()
    }
}
