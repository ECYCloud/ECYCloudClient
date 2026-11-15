package com.ecycloud.client

import java.net.URI
import java.security.MessageDigest

// 必须与 Dart AuthController._accountDirKey 逐字一致，由 AccountKeyTest 用 Dart 实际算出的值核对
object AccountKey {
    fun of(savedSite: String, bundledSite: String, email: String): String? {
        val address = email.trim().lowercase()
        val origin = origin(savedSite) ?: origin(bundledSite) ?: return null
        if (address.isEmpty()) {
            return null
        }
        val identity = "[${jsonString(origin)},${jsonString(address)}]"
        return MessageDigest.getInstance("SHA-256").digest(identity.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }

    // 与 Dart Uri.origin 同一口径：只认 https，主机小写，443 不写端口
    private fun origin(raw: String): String? = runCatching {
        val uri = URI(raw.trim())
        val host = uri.host?.lowercase()
        if (uri.scheme != "https" || host.isNullOrEmpty()) null
        else if (uri.port == -1 || uri.port == 443) "https://$host" else "https://$host:${uri.port}"
    }.getOrNull()

    // 与 Dart jsonEncode 对字符串的转义一致；Android JSONObject 会多转义 /，不能用
    private fun jsonString(value: String): String = buildString {
        append('"')
        for (char in value) {
            when {
                char == '"' -> append("\\\"")
                char == '\\' -> append("\\\\")
                char == '\n' -> append("\\n")
                char == '\r' -> append("\\r")
                char == '\t' -> append("\\t")
                char == '\b' -> append("\\b")
                char == '\u000c' -> append("\\f")
                char < ' ' -> append("\\u%04x".format(char.code))
                else -> append(char)
            }
        }
        append('"')
    }
}
