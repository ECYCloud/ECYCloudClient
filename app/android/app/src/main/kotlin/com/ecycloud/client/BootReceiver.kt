package com.ecycloud.client

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import androidx.core.content.ContextCompat

object Autostart {
    private const val PREFERENCES = "ecycloud"
    private const val KEY = "autostart"

    fun enabled(context: Context): Boolean =
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getBoolean(KEY, false)

    fun setEnabled(context: Context, enabled: Boolean) {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY, enabled)
            .apply()
    }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) {
            return
        }
        if (!Autostart.enabled(context) || !BoxState.configFile(context).isFile) {
            return
        }
        // 未授权时 establish 必然失败，拉起来只会留下一个空跑的前台服务
        if (VpnService.prepare(context) != null) {
            return
        }
        ContextCompat.startForegroundService(context, Intent(context, BoxService::class.java))
    }
}
