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

        // 内核的可用网卡表只在 updateDefaultInterface 里刷新（sing-box
        // route.NetworkManager.UpdateInterfaces 仅由这一个回调触发）。等系统回调
        // 到达时启动期的规则集下载早已开始拨号，表还是空的，会全部报
        // no available network interface，因此返回前必须同步推一次当前网络
        publish(listener, currentNetwork())
    }

    fun stop() {
        callback?.let { runCatching { connectivity.unregisterNetworkCallback(it) } }
        callback = null
    }

    // 网络刚可用时 LinkProperties 与内核接口表都可能还没建好，取不到就短暂重试；
    // 部分鸿蒙 / 定制 ROM 上 getByName(LinkProperties.interfaceName) 会失败，
    // 失败时必须回退到枚举可用物理网卡，否则 sing-box 报 no available network interface
    private fun publish(listener: InterfaceUpdateListener, network: Network?) {
        if (network != null) {
            repeat(10) {
                val name = connectivity.getLinkProperties(network)?.interfaceName
                val device = resolveDevice(name)
                if (device != null) {
                    val metered = connectivity.getNetworkCapabilities(network)
                        ?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == false
                    listener.updateDefaultInterface(device.name, device.index, metered, false)
                    return
                }
                Thread.sleep(100)
            }
        }
        val fallback = fallbackDevice() ?: return
        listener.updateDefaultInterface(fallback.name, fallback.index, false, false)
    }

    @Suppress("DEPRECATION")
    private fun currentNetwork(): Network? {
        val active = connectivity.activeNetwork
        if (active != null && isPhysical(active)) {
            return active
        }
        return connectivity.allNetworks.firstOrNull(::isPhysical)
    }

    // 本应用自己的 VPN 也算一条默认网络，取到它就等于把 tun 当成物理网卡推给内核
    private fun isPhysical(network: Network): Boolean {
        val capabilities = connectivity.getNetworkCapabilities(network) ?: return false
        return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
    }

    companion object {
        fun resolveDevice(name: String?): JavaNetworkInterface? {
            if (name.isNullOrEmpty()) {
                return null
            }
            runCatching { JavaNetworkInterface.getByName(name) }.getOrNull()?.let { return it }
            return runCatching {
                JavaNetworkInterface.getNetworkInterfaces()?.toList()?.firstOrNull {
                    it.name == name || it.displayName == name
                }
            }.getOrNull()
        }

        fun fallbackDevice(): JavaNetworkInterface? = runCatching {
            JavaNetworkInterface.getNetworkInterfaces()?.toList()?.firstOrNull { iface ->
                !iface.isLoopback &&
                    iface.isUp &&
                    iface.interfaceAddresses.isNotEmpty() &&
                    !iface.name.startsWith("tun") &&
                    !iface.name.startsWith("ppp") &&
                    !iface.name.startsWith("dummy")
            }
        }.getOrNull()
    }
}
