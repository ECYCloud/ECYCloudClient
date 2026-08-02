package com.ecycloud.client

import android.os.Process
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.nekohasekai.libbox.Libbox

// 指令名、请求体与应答字段与桌面端特权服务的 JSON 协议逐字一致，见 Dart 侧 VpnChannel
class VpnBridge(private val activity: MainActivity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    init {
        MethodChannel(messenger, "ecycloud/vpn").setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // 状态轮询必须与启停指令解耦：内核启动最久要几十秒，排在后面就取不到进度
            "kernel.status" -> result.success(status(call))
            "ping" -> Bridge.run(result) { ping() }
            "tun.ensure" -> ensureTun(result)
            "kernel.check" -> Bridge.run(result) { check(call.argument<String>("config")) }
            "kernel.start" -> Bridge.run(result) {
                BoxService.start(activity, call.argument<String>("config").orEmpty())
                emptyMap<String, Any>()
            }
            "kernel.stop" -> Bridge.run(result) {
                BoxService.stop()
                emptyMap<String, Any>()
            }
            else -> result.notImplemented()
        }
    }

    private fun ping(): Map<String, Any> {
        BoxService.ensureSetup(activity)
        return mapOf(
            "version" to BuildConfig.VERSION_NAME,
            "kernel" to "sing-box version ${Libbox.version()}",
            "cache_ready" to BoxState.cacheReady(activity),
        )
    }

    private fun ensureTun(result: MethodChannel.Result) {
        activity.requestVpnConsent { granted ->
            result.success(
                if (granted) {
                    mapOf("ready" to true)
                } else {
                    mapOf("ready" to false, "reason" to "用户未授予 VPN 权限")
                },
            )
        }
    }

    private fun check(config: String?): Map<String, Any> {
        BoxService.ensureSetup(activity)
        return try {
            Libbox.checkConfig(config.orEmpty())
            mapOf("valid" to true)
        } catch (e: Exception) {
            mapOf("valid" to false, "error" to (e.message ?: e.toString()))
        }
    }

    private fun status(call: MethodCall): Map<String, Any> {
        val (lines, cursor) = BoxState.logs.since(call.argument<Int>("log_cursor") ?: 0)
        return buildMap {
            put("running", BoxState.running)
            if (BoxState.running) {
                put("pid", Process.myPid())
            } else {
                BoxState.exitCode?.let { put("exit_code", it) }
            }
            BoxState.error?.let { put("error", it) }
            put("log_lines", lines)
            put("log_cursor", cursor)
        }
    }
}
