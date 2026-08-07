package com.ecycloud.client

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

// 通道应答只能回主线程；内核调用与包列表枚举都会阻塞，必须先挪到后台。
// 单线程保证内核的启停指令按下发顺序执行
object Bridge {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun run(result: MethodChannel.Result, block: () -> Any?) {
        worker.execute {
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
