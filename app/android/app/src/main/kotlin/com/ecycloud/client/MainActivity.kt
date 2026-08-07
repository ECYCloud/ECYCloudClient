package com.ecycloud.client

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var vpnConsent: ((String?) -> Unit)? = null
    private var platform: PlatformBridge? = null

    private val resumed get() = foreground === this

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATION)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        platform = PlatformBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        VpnBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onResume() {
        super.onResume()
        foreground = this
    }

    override fun onPause() {
        if (foreground === this) {
            foreground = null
        }
        super.onPause()
    }

    // VpnService.prepare 不是只读查询：本应用已获授权时系统会就地把 VPN 槽位切过来，
    // 顺带断掉别的应用正在跑的隧道（AOSP Vpn.prepare → prepareInternal），
    // 因此只能在真的要建立隧道前调用，不得用于探测权限。
    // callback 收到 null 表示已授权，否则是失败原因
    fun requestVpnConsent(callback: (String?) -> Unit) {
        val intent = VpnService.prepare(this)
        if (intent == null) {
            callback(null)
            return
        }
        // 后台起 Activity 会被系统静默丢弃，onActivityResult 永远不来，
        // 这次 kernel.start 就会永久挂起
        if (!resumed) {
            callback("需要授予 VPN 权限，请打开应用后重试")
            return
        }
        vpnConsent = callback
        startActivityForResult(intent, REQUEST_VPN)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_VPN) {
            return
        }
        val callback = vpnConsent ?: return
        vpnConsent = null
        callback(if (resultCode == Activity.RESULT_OK) null else "用户未授予 VPN 权限")
    }

    companion object {
        @Volatile
        private var foreground: MainActivity? = null

        private const val REQUEST_VPN = 0x5650
        private const val REQUEST_NOTIFICATION = 0x4e54

        // 界面不在前台时不交给 Dart：连接要过 requestVpnConsent，而后台弹不出授权框，
        // 那条路只能直接失败。返回 false 时由磁贴自己启停 BoxService
        fun requestToggle(): Boolean {
            val bridge = foreground?.platform ?: return false
            bridge.notifyToggle()
            return true
        }
    }
}
