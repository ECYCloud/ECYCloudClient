package com.ecycloud.client

import android.app.Service
import android.content.Intent
import android.os.Bundle
import android.os.IBinder
import android.os.Process
import android.os.RemoteException
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
                    if (BoxState.revoked) {
                        putBoolean("revoked", true)
                    }
                    if (BoxState.stoppedByUser) {
                        putBoolean("stopped_by_user", true)
                    }
                }
                BoxState.error?.let { putString("error", it) }
                putStringArrayList("log_lines", ArrayList(lines))
                putInt("log_cursor", cursor)
            }
        }

        override fun check(config: String?): Bundle = guarded {
            BoxService.ensureSetup(this@KernelService)
            Bundle().apply {
                try {
                    Mihomo.check(config.orEmpty())
                    putBoolean("valid", true)
                } catch (e: Exception) {
                    putBoolean("valid", false)
                    putString("error", e.message ?: e.toString())
                }
            }
        }

        override fun reload(config: String?) = guarded {
            val raw = config.orEmpty()
            if (raw.isBlank()) {
                error("缺少配置内容")
            }
            Mihomo.reload(BoxState.writeConfig(this@KernelService, BoxService.ensureSetup(this@KernelService), raw))
        }

        override fun start(config: String?) = guarded {
            BoxService.start(this@KernelService, config.orEmpty())
        }

        override fun stop() = guarded {
            BoxService.stop()
        }

        // 本进程随后会被界面进程强制结束，内核与 TUN 随进程一起释放，停止失败不影响退出
        override fun clearSession(): Int = guarded {
            runCatching { BoxService.stop() }
            Process.myPid()
        }

        override fun registerUi(callback: IUiCallback?) {
            ui = callback
        }
    }

    override fun onBind(intent: Intent?): IBinder = binder

    // 绑定的会话已不是当前登录：结束本进程，界面重新绑定时换成新进程
    private fun dropRetiredSession() {
        val owner = BoxState.session ?: return
        if (owner == BoxState.sessionKey(this)) {
            return
        }
        runCatching { BoxService.stop() }
        Process.killProcess(Process.myPid())
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
