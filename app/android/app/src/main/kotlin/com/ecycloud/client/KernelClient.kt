package com.ecycloud.client

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.RemoteException
import android.os.Process
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

// 禁止引用 com.ecycloud.mihomo.*：静态初始化会 loadLibrary("gojni")，把 Go 运行时载进界面进程
object KernelClient {
    // 启停指令允许等绑定；状态轮询不能，Dart 每秒问一次，等久了会在轮询线程上堆积
    private const val COMMAND_WAIT_MS = 20_000L
    private const val STATUS_WAIT_MS = 2_000L
    private const val KERNEL_EXIT_WAIT_MS = 5_000L

    private val lock = ReentrantLock()
    private val arrived = lock.newCondition()

    @Volatile
    private var service: IKernelService? = null

    @Volatile
    private var bound = false

    private lateinit var app: Context

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
        if (bound) {
            return
        }
        app = context.applicationContext
        bound = app.bindService(
            Intent(app, KernelService::class.java),
            connection,
            Context.BIND_AUTO_CREATE,
        )
    }

    fun <T> call(block: (IKernelService) -> T): T {
        val remote = handle(COMMAND_WAIT_MS) ?: error("内核进程未就绪")
        return try {
            block(remote)
        } catch (e: RemoteException) {
            error(crashReason() ?: "内核进程已退出")
        }
    }

    // Go 运行时崩溃前写下的 panic / fatal error 原因（Mihomo.setup 登记，每个内核进程起来时清空）
    fun crashReason(): String? {
        val key = BoxState.sessionKey(app) ?: return null
        return runCatching { File(BoxState.runDir(app, key), "kernel-crash.log").readLines() }
            .getOrNull()
            ?.map(String::trim)
            ?.filter(String::isNotEmpty)
            ?.takeWhile { !it.startsWith("goroutine ") }
            ?.take(2)
            ?.takeIf(List<String>::isNotEmpty)
            ?.joinToString(" | ", prefix = "内核进程已退出：")
    }

    fun <T> poll(block: (IKernelService) -> T): T? = try {
        handle(STATUS_WAIT_MS)?.let(block)
    } catch (e: RemoteException) {
        null
    }

    fun bindSession(context: Context, key: String) {
        check(key == BoxState.sessionKey(context)) { "登录状态已变化，请重新操作" }
        val owner = call { it.ping() }.getString("session").orEmpty()
        if (owner.isNotEmpty() && owner != key) {
            clearSession(context)
        }
    }

    fun clearSession(context: Context) {
        context.stopService(Intent(context, BoxService::class.java))
        val remote = handle(STATUS_WAIT_MS) ?: return
        val binder = remote.asBinder()
        val died = CountDownLatch(1)
        val death = IBinder.DeathRecipient { died.countDown() }
        try {
            binder.linkToDeath(death, 0)
            val pid = remote.clearSession()
            check(pid > 0 && pid != Process.myPid()) { "内核进程身份异常" }
            Process.killProcess(pid)
            check(died.await(KERNEL_EXIT_WAIT_MS, TimeUnit.MILLISECONDS)) { "旧内核进程尚未退出" }
        } catch (e: RemoteException) {
        } finally {
            runCatching { binder.unlinkToDeath(death, 0) }
            lock.withLock {
                if (service?.asBinder() == binder) service = null
            }
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
