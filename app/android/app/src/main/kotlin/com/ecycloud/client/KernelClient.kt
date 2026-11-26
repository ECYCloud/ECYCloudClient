package com.ecycloud.client

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.RemoteException
import android.os.Process
import android.os.SystemClock
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.thread
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

    @Volatile
    private var boundAt = 0L

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
            lock.withLock {
                service = null
                boundAt = 0L
                arrived.signalAll()
            }
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
        boundAt = SystemClock.elapsedRealtime()
    }

    // 内核进程死后系统只按退避重启服务，连续死亡就不再重启，部分 ROM 还会拦下这种重启；
    // 由前台界面重新绑定属于调用方发起的启动，会立即拉起新进程
    @Synchronized
    private fun revive() {
        if (service != null || (bound && SystemClock.elapsedRealtime() - boundAt < COMMAND_WAIT_MS)) {
            return
        }
        if (bound) {
            runCatching { app.unbindService(connection) }
            bound = false
        }
        bind(app)
    }

    fun <T> call(block: (IKernelService) -> T): T {
        val remote = handle(COMMAND_WAIT_MS, revive = true) ?: error("内核进程未就绪")
        return try {
            block(remote)
        } catch (e: RemoteException) {
            error(crashReason() ?: "内核进程已退出")
        }
    }

    // 配置里每个分组各带一份完整节点，按 UTF-16 传输会超过 Binder 单次事务约 1 MiB 的上限，只能经管道交给内核进程
    fun <T> send(config: String, block: (IKernelService, ParcelFileDescriptor) -> T): T {
        val (source, sink) = ParcelFileDescriptor.createPipe()
        thread {
            runCatching {
                ParcelFileDescriptor.AutoCloseOutputStream(sink).use { it.write(config.toByteArray()) }
            }
        }
        return source.use { call { remote -> block(remote, it) } }
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
                if (service?.asBinder() == binder) {
                    service = null
                    boundAt = 0L
                }
            }
        }
    }

    private fun handle(timeoutMs: Long, revive: Boolean = false): IKernelService? {
        service?.let { return it }
        lock.withLock {
            var remaining = TimeUnit.MILLISECONDS.toNanos(timeoutMs)
            while (service == null) {
                if (revive) {
                    revive()
                }
                if (remaining <= 0) {
                    return null
                }
                remaining = arrived.awaitNanos(remaining)
            }
            return service
        }
    }
}
