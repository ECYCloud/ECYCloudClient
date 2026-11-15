package com.ecycloud.client

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

// 通道应答只能回主线程；内核调用与包列表枚举都会阻塞，必须先挪到后台。
// 单线程保证内核的启停指令按下发顺序执行
object Bridge {
    private val worker = Executors.newSingleThreadExecutor()
    private val queued = AtomicInteger()

    // 首次连接下载规则集时 kernel.start 要占住 worker 几分钟，结束内核进程不能排在它后面
    private val control = Executors.newSingleThreadExecutor()

    // 系统密钥与外部唤起同样不能等内核启停
    private val platform = Executors.newSingleThreadExecutor()

    // 状态轮询既不能排在启停指令后面（内核启动最久要几十秒，排队就取不到进度），
    // 也不能留在主线程：跨进程读状态会被内核进程的繁忙拖成 ANR
    private val poller = Executors.newSingleThreadExecutor()

    private val main = Handler(Looper.getMainLooper())

    val idle: Boolean get() = queued.get() == 0

    fun run(result: MethodChannel.Result, block: () -> Any?) {
        queued.incrementAndGet()
        dispatch(worker, result) {
            try {
                block()
            } finally {
                queued.decrementAndGet()
            }
        }
    }

    fun control(result: MethodChannel.Result, block: () -> Any?) =
        dispatch(control, result, block)

    fun platform(result: MethodChannel.Result, block: () -> Any?) =
        dispatch(platform, result, block)

    fun poll(result: MethodChannel.Result, block: () -> Any?) =
        dispatch(poller, result, block)

    private fun dispatch(
        executor: Executor,
        result: MethodChannel.Result,
        block: () -> Any?,
    ) {
        executor.execute {
            val outcome = runCatching(block)
            main.post {
                outcome.fold(
                    { result.success(it) },
                    { result.error("ecycloud", it.message ?: it.toString(), null) },
                )
            }
        }
    }
}
