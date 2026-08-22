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

    fun runDir(context: Context): File = File(context.filesDir, "run")

    fun configFile(context: Context): File = File(runDir(context), "config.json")

    fun cacheReady(context: Context): Boolean =
        File(runDir(context), "cache.db").let { it.isFile && it.length() > 0 }

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
        val file = resolveWithin(runDir(context), relative)
        require(file.isFile) { if (file.exists()) "不能读取目录" else "文件不存在" }
        require(file.length() <= maxRunFileBytes) { "文件过大（超过 ${maxRunFileBytes shr 20} MiB）" }
        return file.readText()
    }
}
