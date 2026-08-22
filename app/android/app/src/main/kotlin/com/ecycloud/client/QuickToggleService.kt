package com.ecycloud.client

import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.core.content.ContextCompat

class QuickToggleService : TileService() {

    private var takeover = false

    override fun onClick() {
        val tile = qsTile ?: return
        when (tile.state) {
            Tile.STATE_INACTIVE -> startTunnel()
            Tile.STATE_ACTIVE -> stopTunnel()
        }
    }

    override fun onStartListening() {
        super.onStartListening()
        listening = this
        takeover = BoxState.takeover
        updateTile()
    }

    override fun onStopListening() {
        listening = null
        super.onStopListening()
    }

    private fun startTunnel() {
        if (KernelService.requestToggle()) {
            return
        }
        if (BoxState.starting || !BoxState.configFile(this).isFile) {
            return
        }
        // 已获 VPN 授权时 API 31+ 允许后台起前台服务（REASON_OP_ACTIVATE_VPN）；授权被抢走仍会抛
        runCatching {
            ContextCompat.startForegroundService(this, Intent(this, BoxService::class.java))
        }.onFailure {
            BoxState.error = "系统拒绝启动内核（${it.message ?: it}）"
        }
    }

    private fun stopTunnel() {
        if (KernelService.requestToggle()) {
            return
        }
        // TileService 回调里 stop 会阻塞，挪到后台；磁贴由 shutdown() 回刷
        Thread {
            BoxState.stoppedByUser = true
            BoxService.stop()
        }.start()
    }

    private fun updateTile() {
        val tile = qsTile ?: return
        tile.state = if (takeover) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = getText(R.string.app_name)
        tile.icon = Icon.createWithResource(this, R.drawable.ic_notification)
        tile.updateTile()
    }

    companion object {
        // 未声明 META_DATA_ACTIVE_TILE 的磁贴只在 onStartListening 与 onStopListening
        // 之间绑定，TileService.requestListeningState 对它不生效，回刷只能走这个实例
        @Volatile
        private var listening: QuickToggleService? = null

        private val main = Handler(Looper.getMainLooper())

        fun refresh() {
            val service = listening ?: return
            main.post {
                service.takeover = BoxState.takeover
                service.updateTile()
            }
        }
    }
}
