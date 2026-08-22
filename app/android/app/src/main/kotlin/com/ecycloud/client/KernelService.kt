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
            BoxService.ensureSetup(this@KernelService)
            Bundle().apply {
                putString("version", BuildConfig.VERSION_NAME)
                // 与桌面端 `mihomo -v` 的首行同一口径，设置页的内核版本从中取数字
                putString("kernel", "Mihomo Meta ${Mihomo.version()}")
                putBoolean("cache_ready", BoxState.cacheReady(this@KernelService))
            }
        }

        override fun status(logCursor: Int): Bundle {
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
            BoxService.ensureSetup(this@KernelService)
            BoxState.configFile(this@KernelService).writeText(raw)
            Mihomo.reload(raw)
        }

        override fun start(config: String?) = guarded {
            BoxService.start(this@KernelService, config.orEmpty())
        }

        override fun stop() = guarded {
            BoxService.stop()
        }

        override fun registerUi(callback: IUiCallback?) {
            ui = callback
        }
    }

    override fun onBind(intent: Intent?): IBinder = binder

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
