package com.ecycloud.client

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class PlatformBridge(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "ecycloud/platform").also {
        it.setMethodCallHandler(this)
    }

    // 指令名与实参必须与 Dart 侧 AndroidPlatformService._onNativeCall 逐字一致
    fun notifyToggle() {
        channel.invokeMethod("tray.action", "toggle")
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "paths.data" -> result.success(context.filesDir.absolutePath)
            "device.name" -> result.success(deviceName())
            "autostart.get" -> result.success(Autostart.enabled(context))
            "autostart.set" -> {
                Autostart.setEnabled(context, call.argument<Boolean>("enabled") == true)
                result.success(null)
            }
            "apps.list" -> Bridge.run(result) { installedApps() }
            "installer.run" -> Bridge.run(result) { runInstaller(call.argument<String>("path")) }
            "url.open" -> Bridge.run(result) { openUrl(call.argument<String>("url")) }
            else -> result.notImplemented()
        }
    }

    private fun deviceName(): String {
        val name = Settings.Global.getString(context.contentResolver, "device_name")
        return if (name.isNullOrBlank()) Build.MODEL else name
    }

    private fun installedApps(): List<Map<String, Any>> {
        val packages = context.packageManager
        return packages.getInstalledApplications(0)
            .filter { it.packageName != context.packageName }
            .map {
                mapOf(
                    "package" to it.packageName,
                    "label" to packages.getApplicationLabel(it).toString(),
                    "system" to (it.flags and ApplicationInfo.FLAG_SYSTEM != 0),
                )
            }
            .sortedBy { it["label"] as String }
    }

    private fun runInstaller(path: String?): Boolean {
        if (path.isNullOrEmpty() || !File(path).isFile) {
            return false
        }
        // 未开「安装未知应用」时安装器会被系统直接丢弃，先把用户送到授权页
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !context.packageManager.canRequestPackageInstalls()
        ) {
            openIntent(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                    .setData(Uri.parse("package:${context.packageName}")),
            )
            return false
        }

        val uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            File(path),
        )
        return openIntent(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
        )
    }

    private fun openUrl(url: String?): Boolean {
        if (url.isNullOrEmpty()) {
            return false
        }
        return openIntent(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
    }

    private fun openIntent(intent: Intent): Boolean =
        runCatching { context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            .isSuccess
}
