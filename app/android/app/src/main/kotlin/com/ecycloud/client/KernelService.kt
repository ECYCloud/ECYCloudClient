package com.ecycloud.client

import android.app.Service
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.RemoteException
import androidx.core.content.ContextCompat
import com.ecycloud.mihomo.Mihomo

class KernelService : Service() {

    private val binder = object : IKernelService.Stub() {
        override fun ping(): Bundle = guarded {
            Bundle().apply {
                putString("session", BoxState.session.orEmpty())
                putString("version", BuildConfig.VERSION_NAME)
                // 与桌面端 `mihomo -v` 的首行同一口径，设置页的内核版本从中取数字
                putString("kernel", "Mihomo Meta ${Mihomo.version()}")
                putBoolean("cache_ready", BoxState.cacheReady(this@KernelService))
            }
        }

        override fun status(logCursor: Int): Bundle {
            dropRetiredSession()
            BoxService.refreshLanguage()
            val (lines, cursor) = BoxState.logs.since(logCursor)
            return Bundle().apply {
                putBoolean("running", BoxState.running)
                if (BoxState.running) {
                    putInt("pid", Process.myPid())
                    putLong("started_at", BoxState.startedAt)
                } else {
                    BoxState.exitCode?.let { putInt("exit_code", it) }
                    BoxState.stopReason(this@KernelService)?.let { putBoolean(it, true) }
                    if (BoxState.starting) {
                        putBoolean("starting", true)
                    }
                }
                BoxState.error?.let { putString("error", it) }
                putStringArrayList("log_lines", ArrayList(lines))
                putInt("log_cursor", cursor)
            }
        }

        override fun check(config: ParcelFileDescriptor): Bundle = receiving(config) { raw ->
            BoxService.ensureSetup(this@KernelService)
            Bundle().apply {
                try {
                    Mihomo.check(raw)
                    putBoolean("valid", true)
                } catch (e: Exception) {
                    putBoolean("valid", false)
                    putString("error", e.message ?: e.toString())
                }
            }
        }

        override fun reload(config: ParcelFileDescriptor) = receiving(config) { raw ->
            if (raw.isBlank()) {
                error("缺少配置内容")
            }
            Mihomo.reload(BoxState.writeConfig(this@KernelService, BoxService.ensureSetup(this@KernelService), raw))
        }

        override fun start(config: ParcelFileDescriptor) = receiving(config) { raw ->
            BoxService.start(this@KernelService, raw)
        }

        override fun stop() = guarded {
            BoxService.stop(this@KernelService)
        }

        // 本进程随后会被界面进程强制结束，内核与 TUN 随进程一起释放，停止失败不影响退出
        override fun clearSession(): Int = guarded {
            runCatching { BoxService.stop(this@KernelService) }
            Process.myPid()
        }

        override fun registerUi(callback: IUiCallback?) {
            ui = callback
        }
    }

    private val main = Handler(Looper.getMainLooper())

    override fun onBind(intent: Intent?): IBinder = binder

    // intent 为空只发生在内核进程被杀后系统按 START_STICKY 重建本服务
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            main.postDelayed(::recover, NativeRecovery.GRACE_MS)
        }
        return START_STICKY
    }

    // 与开机自启、磁贴同一条原生启动路径；VpnService.prepare 放最后，它在槽位属于别人时会抢槽位
    private fun recover() {
        if (BoxState.running || BoxState.starting) {
            return
        }
        val key = BoxState.sessionKey(this)
        val attempts = BoxState.recoveryAttempts(this)
        if (key == null ||
            attempts == null ||
            !NativeRecovery.shouldRecover(attempts, BoxState.stopReason(this), BoxState.configFile(this, key).isFile) ||
            VpnService.prepare(this) != null
        ) {
            giveUp()
            return
        }
        BoxState.setRecoveryAttempts(this, key, attempts + 1)
        BoxState.logs.append("WARNING 内核进程意外退出，原生自恢复第 ${attempts + 1} 次")
        runCatching {
            ContextCompat.startForegroundService(this, Intent(this, BoxService::class.java))
        }.onFailure {
            BoxState.logs.append("ERROR 原生自恢复被系统拒绝：$it")
        }
        main.postDelayed({ watch(attempts + 1) }, 1_000)
    }

    private fun watch(attempts: Int) {
        when {
            BoxState.takeover -> Unit
            BoxState.starting -> main.postDelayed({ watch(attempts) }, 1_000)
            else -> main.postDelayed(::recover, NativeRecovery.retryDelayMs(attempts))
        }
    }

    // 系统留下的 BoxService 记录不清掉，startForeground 发出的「已连接」通知会一直在
    private fun giveUp() {
        BoxState.sessionKey(this)?.let { BoxState.clearTakeover(this, it) }
        stopService(Intent(this, BoxService::class.java))
        stopSelf()
    }

    // 绑定的会话已不是当前登录：结束本进程，界面重新绑定时换成新进程
    private fun dropRetiredSession() {
        val owner = BoxState.session ?: return
        if (owner == BoxState.sessionKey(this)) {
            return
        }
        runCatching { BoxService.stop(this) }
        Process.killProcess(Process.myPid())
    }

    // 读端要先整份读完并关闭再处理：留着不关，界面进程的写线程会一直堵在管道上
    private fun <T> receiving(config: ParcelFileDescriptor, block: (String) -> T): T = guarded {
        block(ParcelFileDescriptor.AutoCloseInputStream(config).reader().use { it.readText() })
    }

    // Binder 只透传少数框架异常，其余类型跨进程时连消息一并丢掉，界面侧就只能报「调用失败」
    private fun <T> guarded(block: () -> T): T = try {
        block()
    } catch (e: IllegalStateException) {
        throw e
    } catch (e: Exception) {
        error(e.message ?: e.toString())
    }

    companion object {
        @Volatile
        private var ui: IUiCallback? = null

        fun requestToggle(): Boolean {
            val callback = ui ?: return false
            return try {
                callback.requestToggle()
            } catch (e: RemoteException) {
                ui = null
                false
            }
        }
    }
}
