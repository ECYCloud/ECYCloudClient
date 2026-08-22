package com.ecycloud.client

import android.os.Bundle
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// 指令名、请求体与应答字段与桌面端特权服务的 JSON 协议逐字一致，见 Dart 侧 VpnChannel
class VpnBridge(private val activity: MainActivity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    init {
        MethodChannel(messenger, "ecycloud/vpn").setMethodCallHandler(this)
        KernelClient.bind(activity)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "kernel.status" -> Bridge.poll(result) {
                status(call.argument<Int>("log_cursor") ?: 0)
            }
            "ping" -> Bridge.run(result) { KernelClient.call { it.ping() }.toMap() }
            "kernel.check" -> Bridge.run(result) {
                KernelClient.call { it.check(call.argument<String>("config")) }.toMap()
            }
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
                KernelClient.call { it.reload(call.argument<String>("config")) }
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
                        KernelClient.call { it.start(config) }
                        emptyMap<String, Any>()
                    }
                }
                if (BoxState.takesOverExit(config)) {
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
                KernelClient.call { it.stop() }
                emptyMap<String, Any>()
            }
            else -> result.notImplemented()
        }
    }

    // 内核进程不在时如实报「没在跑」：抛异常会让 Dart 侧把轮询本身当成与后台失联，
    // 转而停掉轮询，之后即使内核被系统重建也无人接管
    private fun status(cursor: Int): Map<String, Any?> =
        KernelClient.poll { it.status(cursor) }?.toMap()
            ?: mapOf("running" to false, "log_cursor" to cursor)
}

// Bundle 的键集就是应答字段本身，逐键抄一遍等于把协议同时写在两个进程里
@Suppress("DEPRECATION")
private fun Bundle.toMap(): Map<String, Any?> = keySet().associateWith { get(it) }
