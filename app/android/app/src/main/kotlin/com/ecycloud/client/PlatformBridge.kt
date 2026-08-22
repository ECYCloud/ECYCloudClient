package com.ecycloud.client

import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract.Root
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

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
            "device.profile" -> result.success(deviceProfile())
            "device.television" -> result.success(isTelevision())
            "autostart.get" -> result.success(Autostart.enabled(context))
            "autostart.set" -> {
                Autostart.setEnabled(context, call.argument<Boolean>("enabled") == true)
                result.success(null)
            }
            "apps.list" -> Bridge.run(result) { installedApps() }
            "installer.run" -> Bridge.run(result) { runInstaller(call.argument<String>("path")) }
            "url.open" -> Bridge.run(result) { openUrl(call.argument<String>("url")) }
            "dir.open" -> Bridge.run(result) { openDirectory(call.argument<String>("path")) }
            "secret.protect" -> Bridge.run(result) {
                protectSecret(
                    call.argument<String>("name"),
                    call.argument<String>("value"),
                )
            }
            "secret.unprotect" -> Bridge.run(result) {
                unprotectSecret(
                    call.argument<String>("name"),
                    call.argument<String>("value"),
                )
            }
            "secret.delete" -> Bridge.run(result) {
                deleteSecret(call.argument<String>("name"))
                null
            }
            else -> result.notImplemented()
        }
    }

    // 只认系统口径：UI_MODE_TYPE_TELEVISION 或 FEATURE_LEANBACK
    private fun isTelevision(): Boolean {
        val television = context.getSystemService(UiModeManager::class.java)
            ?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
        return television || context.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
    }

    private fun deviceName(): String {
        val name = Settings.Global.getString(context.contentResolver, "device_name")
        return if (name.isNullOrBlank()) Build.MODEL else name
    }

    private fun deviceProfile(): Map<String, String> {
        val brand = Build.MANUFACTURER.orEmpty().trim()
        val model = Build.MODEL.orEmpty().trim()
        return mapOf(
            "model" to if (brand.isEmpty() || model.startsWith(brand, ignoreCase = true)) {
                model
            } else {
                "$brand $model"
            },
            "os" to "Android ${Build.VERSION.RELEASE}",
        )
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

    private fun openDirectory(path: String?): Boolean {
        if (path.isNullOrEmpty()) {
            return false
        }
        val root = LogDocumentsProvider.rootUri(context, path) ?: return false
        return openIntent(
            Intent(Intent.ACTION_VIEW).setDataAndType(root, Root.MIME_TYPE_ITEM),
        )
    }

    private fun openIntent(intent: Intent): Boolean =
        runCatching { context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            .isSuccess

    private fun protectSecret(name: String?, value: String?): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey(name))
        val iv = cipher.iv
        val encrypted = cipher.doFinal((value ?: "").toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(iv + encrypted, Base64.NO_WRAP)
    }

    private fun unprotectSecret(name: String?, blob: String?): String? {
        if (blob.isNullOrEmpty()) {
            return null
        }
        val raw = Base64.decode(blob, Base64.NO_WRAP)
        if (raw.size <= 12) {
            return null
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            secretKey(name),
            GCMParameterSpec(128, raw.copyOfRange(0, 12)),
        )
        return cipher.doFinal(raw.copyOfRange(12, raw.size)).toString(Charsets.UTF_8)
    }

    private fun deleteSecret(name: String?) {
        val alias = aliasFor(name)
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (keyStore.containsAlias(alias)) {
            keyStore.deleteEntry(alias)
        }
    }

    private fun secretKey(name: String?): SecretKey {
        val alias = aliasFor(name)
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = keyStore.getKey(alias, null) as? SecretKey
        if (existing != null) {
            return existing
        }
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore",
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private fun aliasFor(name: String?): String =
        if (name == "remembered_password") {
            rememberedKeyAlias
        } else {
            "ecycloud_${name ?: "secret"}"
        }

    companion object {
        private const val rememberedKeyAlias = "ecycloud_remembered_login"
    }
}
