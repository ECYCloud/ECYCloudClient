package com.ecycloud.client

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.nekohasekai.libbox.InterfaceUpdateListener
import java.util.concurrent.Executors
import java.net.NetworkInterface as JavaNetworkInterface

class DefaultNetworkMonitor(context: Context) {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private var callback: ConnectivityManager.NetworkCallback? = null

    fun start(listener: InterfaceUpdateListener) {
        stop()

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                worker.execute { publish(listener, network) }
            }

            override fun onCapabilitiesChanged(
                network: Network,
                networkCapabilities: NetworkCapabilities,
            ) {
                worker.execute { publish(listener, network) }
            }

            override fun onLost(network: Network) {
                worker.execute { listener.updateDefaultInterface("", -1, false, false) }
            }
        }
        this.callback = callback

        // Android P 起 registerDefaultNetworkCallback 会把本应用自己的 VPN 报成默认网络，
        // 拿到的接口就是 tun 自身，必须改用带 REQUEST 语义的注册方式才能得到物理网卡
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
                connectivity.registerBestMatchingNetworkCallback(request, callback, main)

            Build.VERSION.SDK_INT >= Build.VERSION_CODES.P ->
                connectivity.requestNetwork(request, callback)

            else -> connectivity.registerDefaultNetworkCallback(callback)
        }
    }

    fun stop() {
        callback?.let { runCatching { connectivity.unregisterNetworkCallback(it) } }
        callback = null
    }

    // 网络刚可用时 LinkProperties 与内核接口表都可能还没建好，取不到就短暂重试
    private fun publish(listener: InterfaceUpdateListener, network: Network) {
        repeat(10) {
            val name = connectivity.getLinkProperties(network)?.interfaceName
            val index = name?.let {
                runCatching { JavaNetworkInterface.getByName(it).index }.getOrNull()
            }
            if (index != null) {
                val metered = connectivity.getNetworkCapabilities(network)
                    ?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == false
                listener.updateDefaultInterface(name, index, metered, false)
                return
            }
            Thread.sleep(100)
        }
    }
}
