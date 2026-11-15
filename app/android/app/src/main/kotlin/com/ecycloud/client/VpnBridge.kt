package com.ecycloud.client

import android.os.Bundle
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// 指令名、请求体与应答字段与桌面端特权服务的 JSON 协议逐字一致，见 Dart 侧 VpnChannel
class VpnBridge(private val activity: MainActivity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    private var generation = 0

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
            "kernel.bind" -> Bridge.run(result) {
                val key = call.argument<String>("cache_key").orEmpty()
                require(Regex("[a-f0-9]{64}").matches(key)) { "缓存身份格式错误" }
                KernelClient.bindSession(activity, key)
                emptyMap<String, Any>()
            }
            "kernel.check" -> Bridge.run(result) {
                KernelClient.call { it.check(call.argument<String>("config")) }.toMap()
            }
            "kernel.write" -> Bridge.run(result) {
                val config = call.argument<String>("config").orEmpty()
                if (config.isBlank()) {
                    error("缺少配置内容")
                }
                BoxState.writeConfig(activity, BoxState.sessionKey(activity) ?: error("尚未登录"), config)
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
                val requested = generation
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
                            if (requested != generation) {
                                result.error("ecycloud", "账户会话已变化", null)
                            } else {
                                startKernel()
                            }
                        }
                    }
                } else {
                    startKernel()
                }
            }
            // 有启动排队时不等它：直接结束内核进程，进行中的启动随之失败
            "kernel.stop" -> if (Bridge.idle) {
                Bridge.run(result) {
                    KernelClient.call { it.stop() }
                    emptyMap<String, Any>()
                }
            } else {
                generation++
                Bridge.control(result) {
                    KernelClient.clearSession(activity)
                    emptyMap<String, Any>()
                }
            }
            "kernel.clear" -> {
                generation++
                Bridge.control(result) {
                    val key = call.argument<String>("cache_key").orEmpty()
                    require(key.isEmpty() || Regex("[a-f0-9]{64}").matches(key)) { "缓存身份格式错误" }
                    try {
                        // 晚到的旧账号退出不能结束已经属于新账号的内核
                        val owner = KernelClient.poll { it.ping() }?.getString("session").orEmpty()
                        if (key.isEmpty() || owner.isEmpty() || owner == key) {
                            KernelClient.clearSession(activity)
                        }
                    } finally {
                        if (key.isNotEmpty()) BoxState.dropRuntimeSecrets(activity, key)
                    }
                    emptyMap<String, Any>()
                }
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
