package com.ecycloud.client

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.RemoteException
import android.os.Process
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

// 禁止引用 com.ecycloud.mihomo.*：静态初始化会 loadLibrary("gojni")，把 Go 运行时载进界面进程
object KernelClient {
    // 启停指令允许等绑定；状态轮询不能，Dart 每秒问一次，等久了会在轮询线程上堆积
    private const val COMMAND_WAIT_MS = 20_000L
    private const val STATUS_WAIT_MS = 2_000L

    private val lock = ReentrantLock()
    private val arrived = lock.newCondition()

    @Volatile
    private var service: IKernelService? = null

    @Volatile
    private var bound = false

    private var application: Context? = null

    private val callback = object : IUiCallback.Stub() {
        override fun requestToggle(): Boolean = MainActivity.requestToggle()
    }

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            val remote = IKernelService.Stub.asInterface(binder)
            runCatching { remote.registerUi(callback) }
            lock.withLock {
                service = remote
                arrived.signalAll()
            }
        }

        override fun onServiceDisconnected(name: ComponentName) {
            lock.withLock { service = null }
        }
    }

    @Synchronized
    fun bind(context: Context) {
        application = context.applicationContext
        if (bound) {
            return
        }
        val app = context.applicationContext
        bound = app.bindService(
            Intent(app, KernelService::class.java),
            connection,
            Context.BIND_AUTO_CREATE,
        )
    }

    fun <T> call(block: (IKernelService) -> T): T {
        check(!BoxState.sessionCleanupPending(requireNotNull(application))) { "账户会话正在清理" }
        val remote = handle(COMMAND_WAIT_MS) ?: error("内核进程未就绪")
        return try {
            block(remote)
        } catch (e: RemoteException) {
            error("内核进程已退出")
        }
    }

    fun <T> poll(block: (IKernelService) -> T): T? = try {
        if (BoxState.sessionCleanupPending(requireNotNull(application))) null
        else handle(STATUS_WAIT_MS)?.let(block)
    } catch (e: RemoteException) {
        null
    }

    fun clearSession(context: Context) {
        check(BoxState.sessionCleanupPending(context)) { "缺少会话清理标记" }
        LogDocumentsProvider.clearSession(context)
        val remote = handle(COMMAND_WAIT_MS) ?: error("内核进程未就绪")
        val binder = remote.asBinder()
        val died = CountDownLatch(1)
        val death = IBinder.DeathRecipient { died.countDown() }
        binder.linkToDeath(death, 0)
        try {
            val pid = remote.clearSession()
            check(pid > 0 && pid != Process.myPid()) { "内核进程身份异常" }
            context.stopService(Intent(context, BoxService::class.java))
            Process.killProcess(pid)
            check(died.await(5, TimeUnit.SECONDS)) { "旧内核进程尚未退出" }
            lock.withLock {
                if (service?.asBinder() == binder) service = null
            }
            BoxState.clearRunFiles(context)
        } finally {
            binder.unlinkToDeath(death, 0)
        }
    }

    private fun handle(timeoutMs: Long): IKernelService? {
        service?.let { return it }
        lock.withLock {
            var remaining = TimeUnit.MILLISECONDS.toNanos(timeoutMs)
            while (service == null) {
                if (remaining <= 0) {
                    return null
                }
                remaining = arrived.awaitNanos(remaining)
            }
            return service
        }
    }
}
