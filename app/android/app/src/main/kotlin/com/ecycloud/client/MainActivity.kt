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

    @Volatile
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

    // VpnService.prepare 不是只读查询：已授权时系统会抢走 VPN 槽位并断掉其它隧道，不得用来探测权限
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

        // 后台弹不出 VpnService 授权框；MethodChannel 只能在主线程调用
        fun requestToggle(): Boolean {
            val activity = foreground ?: return false
            val bridge = activity.platform ?: return false
            activity.runOnUiThread { bridge.notifyToggle() }
            return true
        }
    }
}
