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
    private var vpnConsent: ((Boolean) -> Unit)? = null

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
        PlatformBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        VpnBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        BoxService.releaseHeadless()
    }

    fun requestVpnConsent(callback: (Boolean) -> Unit) {
        val intent = VpnService.prepare(this)
        if (intent == null) {
            callback(true)
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
        callback(resultCode == Activity.RESULT_OK)
    }

    private companion object {
        const val REQUEST_VPN = 0x5650
        const val REQUEST_NOTIFICATION = 0x4e54
    }
}
