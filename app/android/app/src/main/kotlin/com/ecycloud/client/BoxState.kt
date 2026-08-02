package com.ecycloud.client

import android.content.Context
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
    val logs = LogRing(800)

    @Volatile
    var running = false

    @Volatile
    var error: String? = null

    @Volatile
    var exitCode: Int? = null

    fun runDir(context: Context): File = File(context.filesDir, "run")

    fun configFile(context: Context): File = File(runDir(context), "config.json")

    // 与 Dart 侧 AppPaths.kernelCacheFile 必须一致
    fun cacheReady(context: Context): Boolean =
        File(runDir(context), "cache.db").let { it.isFile && it.length() > 0 }
}
