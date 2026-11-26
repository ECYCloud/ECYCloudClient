package com.ecycloud.client

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import com.ecycloud.mihomo.Mihomo

// 面板配置把 nas.lan 等局域网后缀交给 system 解析，cmfa 构建的内核只认 SetSystemDNS 交进来的地址。
// VPN 在线时本进程的默认网络就是 VPN 自己，只能另行盯住能上网的非 VPN 网络，换网时重设，内核不必重载
object SystemDns {
    private val capabilities = HashMap<Network, NetworkCapabilities>()
    private val links = HashMap<Network, LinkProperties>()
    private var registered = false
    private var applied: String? = null

    @Synchronized
    fun watch(context: Context) {
        if (registered) {
            return
        }
        val connectivity = context.getSystemService(ConnectivityManager::class.java) ?: return
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        runCatching { connectivity.registerNetworkCallback(request, callback) }
            .onSuccess { registered = true }
            .onFailure { BoxState.logs.append("WARNING 无法监听底层网络，局域网名字交给系统 DNS 的解析不可用：$it") }
    }

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) =
            update { capabilities[network] = caps }

        override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) =
            update { links[network] = properties }

        override fun onLost(network: Network) = update {
            capabilities.remove(network)
            links.remove(network)
        }
    }

    @Synchronized
    private fun update(change: () -> Unit) {
        change()
        val servers = preferred()?.dnsServers.orEmpty().mapNotNull { it.hostAddress }.joinToString(" ")
        if (servers == applied) {
            return
        }
        applied = servers
        Mihomo.setSystemDNS(servers)
    }

    // 系统选默认网络时有线优先于 Wi-Fi、Wi-Fi 优先于移动数据，未验证可上网的排在后面
    private fun preferred(): LinkProperties? = capabilities.entries
        .filter { links[it.key]?.dnsServers?.isNotEmpty() == true }
        .minByOrNull { (_, caps) ->
            val transport = when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 0
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 1
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> 2
                else -> 3
            }
            (if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) 0 else 10) + transport
        }
        ?.let { links[it.key] }
}
