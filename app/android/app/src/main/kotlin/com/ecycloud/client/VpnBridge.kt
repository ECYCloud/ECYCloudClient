package com.ecycloud.client

import android.os.Process
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import com.ecycloud.mihomo.Mihomo

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
            "kernel.check" -> Bridge.run(result) { check(call.argument<String>("config")) }
            "kernel.write" -> Bridge.run(result) {
                val config = call.argument<String>("config").orEmpty()
                if (config.isBlank()) {
                    error("缺少配置内容")
                }
                BoxState.runDir(activity).mkdirs()
                BoxState.configFile(activity).writeText(config)
                emptyMap<String, Any>()
            }
            "kernel.reload" -> Bridge.run(result) {
                val config = call.argument<String>("config").orEmpty()
                if (config.isBlank()) {
                    error("缺少配置内容")
                }
                BoxService.ensureSetup(activity)
                BoxState.configFile(activity).writeText(config)
                Mihomo.reload(config)
                emptyMap<String, Any>()
            }
            "kernel.read" -> Bridge.run(result) {
                val path = call.argument<String>("path").orEmpty()
                if (path.isBlank()) {
                    error("缺少路径")
                }
                mapOf("content" to BoxState.readRunFile(activity, path))
            }
            "kernel.start" -> {
                val config = call.argument<String>("config").orEmpty()
                val startKernel = {
                    Bridge.run(result) {
                        BoxService.start(activity, config)
                        emptyMap<String, Any>()
                    }
                }
                // 内核常驻不建隧道，没有理由为它弹系统的 VPN 授权框
                if (BoxService.takesOverExit(config)) {
                    activity.requestVpnConsent { denied ->
                        if (denied != null) {
                            result.error("ecycloud", denied, null)
                        } else {
                            startKernel()
                        }
                    }
                } else {
                    startKernel()
                }
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
            // 与桌面端 `mihomo -v` 的首行同一口径，设置页的内核版本从中取数字
            "kernel" to "Mihomo Meta ${Mihomo.version()}",
            "cache_ready" to BoxState.cacheReady(activity),
        )
    }

    private fun check(config: String?): Map<String, Any> {
        BoxService.ensureSetup(activity)
        return try {
            Mihomo.check(config.orEmpty())
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
                put("started_at", BoxState.startedAt)
            } else {
                BoxState.exitCode?.let { put("exit_code", it) }
                if (BoxState.revoked) {
                    put("revoked", true)
                }
                if (BoxState.stoppedByUser) {
                    put("stopped_by_user", true)
                }
            }
            BoxState.error?.let { put("error", it) }
            put("log_lines", lines)
            put("log_cursor", cursor)
        }
    }
}
