package com.ecycloud.client

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.Process
import android.system.OsConstants
import android.util.Base64
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.io.File
import java.net.InetSocketAddress
import java.net.InterfaceAddress
import java.security.KeyStore
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import android.app.Notification as AndroidNotification
import io.nekohasekai.libbox.NetworkInterface as LibboxNetworkInterface
import io.nekohasekai.libbox.Notification as LibboxNotification
import java.net.NetworkInterface as JavaNetworkInterface

class BoxService :
    VpnService(),
    PlatformInterface,
    CommandServerHandler {

    private val monitor by lazy { DefaultNetworkMonitor(this) }
    private var server: CommandServer? = null
    private var tun: ParcelFileDescriptor? = null

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(
                    CHANNEL_STATUS,
                    getString(R.string.notification_channel_status),
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            Thread { shutdown() }.start()
            return START_NOT_STICKY
        }
        foreground(getString(R.string.notification_starting))
        headless = intent?.action != ACTION_START
        Thread { launch() }.start()
        return START_NOT_STICKY
    }

    override fun onRevoke() {
        Thread { shutdown() }.start()
    }

    override fun onDestroy() {
        instance = null
        shutdown()
        super.onDestroy()
    }

    private fun launch() {
        val config = runCatching { BoxState.configFile(this).readText() }.getOrNull()
        if (config.isNullOrBlank()) {
            fail("没有可用的内核配置")
            return
        }

        try {
            ensureSetup(this)
            val server = this.server ?: CommandServer(this, this).also { this.server = it }
            server.startOrReloadService(config, OverrideOptions())
        } catch (e: Exception) {
            fail(e.message ?: e.toString())
            return
        }

        BoxState.error = null
        BoxState.exitCode = null
        BoxState.running = true
        note(LEVEL_INFO, "内核已启动")
        foreground(getString(R.string.notification_running))
        startResult.offer("")
    }

    private fun fail(reason: String) {
        BoxState.error = reason
        BoxState.exitCode = 1
        note(LEVEL_ERROR, "内核启动失败：$reason")
        startResult.offer(reason)
        shutdown()
    }

    private fun shutdown() {
        server?.let {
            runCatching { it.closeService() }
            runCatching { it.close() }
        }
        server = null
        monitor.stop()
        tun?.let { runCatching { it.close() } }
        tun = null
        BoxState.running = false
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun foreground(text: String) {
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            notification(text),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            } else {
                0
            },
        )
    }

    private fun notification(text: String): AndroidNotification =
        NotificationCompat.Builder(this, CHANNEL_STATUS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setOngoing(true)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(
                PendingIntent.getActivity(
                    this,
                    0,
                    Intent(this, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                ),
            )
            .build()

    // Dart 侧按 sing-box 的行内级别解析日志，级别缺失会一律当成 info
    private fun note(level: String, message: String) {
        BoxState.logs.append("$level $message")
    }

    // 本地模板固定下发显式 DNS 服务器，不会出现 type: local，无需平台解析器
    override fun localDNSTransport(): LocalDNSTransport? = null

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {
        protect(fd)
    }

    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) {
            error("未授予 VPN 权限")
        }

        val builder = Builder()
            .setSession(getString(R.string.app_name))
            .setMtu(options.mtu)

        val inet4Address = options.inet4Address
        while (inet4Address.hasNext()) {
            val address = inet4Address.next()
            builder.addAddress(address.address(), address.prefix())
        }
        val inet6Address = options.inet6Address
        while (inet6Address.hasNext()) {
            val address = inet6Address.next()
            builder.addAddress(address.address(), address.prefix())
        }

        if (options.autoRoute) {
            builder.addDnsServer(options.dnsServerAddress.value)

            // route range 已是内核按 route_exclude_address 算好的补集，用它就不必
            // 依赖 API 33 才有的 excludeRoute
            val inet4Route = options.inet4RouteRange
            while (inet4Route.hasNext()) {
                val route = inet4Route.next()
                builder.addRoute(route.address(), route.prefix())
            }
            val inet6Route = options.inet6RouteRange
            while (inet6Route.hasNext()) {
                val route = inet6Route.next()
                builder.addRoute(route.address(), route.prefix())
            }

            val includePackage = options.includePackage
            var restricted = false
            while (includePackage.hasNext()) {
                val name = includePackage.next()
                restricted = true
                runCatching { builder.addAllowedApplication(name) }
            }
            // 只放行选中应用时本客户端也得在内，否则它自己的流量绕开隧道
            if (restricted) {
                runCatching { builder.addAllowedApplication(packageName) }
            }

            val excludePackage = options.excludePackage
            while (excludePackage.hasNext()) {
                val name = excludePackage.next()
                runCatching { builder.addDisallowedApplication(name) }
            }
        }

        val descriptor = builder.establish() ?: error("系统拒绝建立 VPN 连接")
        tun?.let { runCatching { it.close() } }
        tun = descriptor
        return descriptor.fd
    }

    override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q

    @RequiresApi(Build.VERSION_CODES.Q)
    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): ConnectionOwner {
        val uid = getSystemService(ConnectivityManager::class.java).getConnectionOwnerUid(
            ipProtocol,
            InetSocketAddress(sourceAddress, sourcePort),
            InetSocketAddress(destinationAddress, destinationPort),
        )
        if (uid == Process.INVALID_UID) {
            error("android: connection owner not found")
        }
        val names = packageManager.getPackagesForUid(uid)?.toList().orEmpty()
        return ConnectionOwner().also {
            it.userId = uid
            it.userName = names.firstOrNull().orEmpty()
            it.setAndroidPackageNames(StringArray(names))
        }
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        monitor.start(listener)
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        monitor.stop()
    }

    @Suppress("DEPRECATION")
    override fun getInterfaces(): NetworkInterfaceIterator {
        val connectivity = getSystemService(ConnectivityManager::class.java)
        val devices = JavaNetworkInterface.getNetworkInterfaces().toList()
        val interfaces = mutableListOf<LibboxNetworkInterface>()

        for (network in connectivity.allNetworks) {
            val properties = connectivity.getLinkProperties(network) ?: continue
            val capabilities = connectivity.getNetworkCapabilities(network) ?: continue
            val device = devices.find { it.name == properties.interfaceName } ?: continue

            interfaces += LibboxNetworkInterface().also {
                it.name = device.name
                it.index = device.index
                runCatching { it.mtu = device.mtu }
                it.addresses = StringArray(device.interfaceAddresses.map(::prefixOf))
                it.flags = flagsOf(device)
                it.type = interfaceTypeOf(capabilities)
                it.dnsServer = StringArray(
                    properties.dnsServers.mapNotNull { server -> server.hostAddress },
                )
                it.metered = !capabilities.hasCapability(
                    NetworkCapabilities.NET_CAPABILITY_NOT_METERED,
                )
            }
        }
        return InterfaceArray(interfaces)
    }

    override fun underNetworkExtension(): Boolean = false

    override fun includeAllNetworks(): Boolean = false

    // SSID 在 Android 10 起需要定位权限，本客户端不下发 wifi_ssid 规则，不申请该权限
    override fun readWIFIState(): WIFIState? = null

    override fun systemCertificates(): StringIterator {
        val store = KeyStore.getInstance("AndroidCAStore")
        store.load(null, null)
        val certificates = mutableListOf<String>()
        for (alias in store.aliases()) {
            val encoded = Base64.encodeToString(
                store.getCertificate(alias).encoded,
                Base64.NO_WRAP,
            )
            certificates += "-----BEGIN CERTIFICATE-----\n$encoded\n-----END CERTIFICATE-----"
        }
        return StringArray(certificates)
    }

    override fun clearDNSCache() {
    }

    override fun sendNotification(notification: LibboxNotification) {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    notification.identifier,
                    notification.typeName,
                    NotificationManager.IMPORTANCE_DEFAULT,
                ),
            )
        }
        manager.notify(
            notification.typeID,
            NotificationCompat.Builder(this, notification.identifier)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(notification.title)
                .setContentText(notification.body)
                .setAutoCancel(true)
                .build(),
        )
    }

    override fun serviceStop() {
        Thread { shutdown() }.start()
    }

    override fun serviceReload() {
        Thread { launch() }.start()
    }

    override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus()

    override fun setSystemProxyEnabled(enabled: Boolean) {
        error("android: system proxy is not supported")
    }

    override fun writeDebugMessage(message: String?) {
        note(LEVEL_DEBUG, message.orEmpty())
    }

    private fun prefixOf(address: InterfaceAddress): String {
        // netip.ParsePrefix 不接受 IPv6 的 zone 后缀，带 %iface 会让内核解析时 panic
        val host = address.address.hostAddress.orEmpty().substringBefore('%')
        return "$host/${address.networkPrefixLength}"
    }

    private fun flagsOf(device: JavaNetworkInterface): Int {
        var flags = 0
        if (device.isUp) {
            flags = flags or OsConstants.IFF_UP or OsConstants.IFF_RUNNING
        }
        if (device.isLoopback) {
            flags = flags or OsConstants.IFF_LOOPBACK
        }
        if (device.isPointToPoint) {
            flags = flags or OsConstants.IFF_POINTOPOINT
        }
        if (device.supportsMulticast()) {
            flags = flags or OsConstants.IFF_MULTICAST
        }
        return flags
    }

    private fun interfaceTypeOf(capabilities: NetworkCapabilities): Int = when {
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Libbox.InterfaceTypeWIFI
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ->
            Libbox.InterfaceTypeCellular

        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) ->
            Libbox.InterfaceTypeEthernet

        else -> Libbox.InterfaceTypeOther
    }

    companion object {
        const val ACTION_START = "com.ecycloud.client.KERNEL_START"
        const val ACTION_STOP = "com.ecycloud.client.KERNEL_STOP"

        private const val CHANNEL_STATUS = "ecycloud-status"
        private const val NOTIFICATION_ID = 1
        private const val LEVEL_INFO = "INFO"
        private const val LEVEL_ERROR = "ERROR"
        private const val LEVEL_DEBUG = "DEBUG"
        private const val START_TIMEOUT_SECONDS = 180L

        private val startResult = ArrayBlockingQueue<String>(1)

        @Volatile
        private var instance: BoxService? = null

        @Volatile
        private var headless = false

        @Volatile
        private var setupDone = false

        @Synchronized
        fun ensureSetup(context: Context) {
            if (setupDone) {
                return
            }
            val working = BoxState.runDir(context).also { it.mkdirs() }
            Libbox.setup(
                SetupOptions().also {
                    it.basePath = context.filesDir.absolutePath
                    it.workingPath = working.absolutePath
                    it.tempPath = context.cacheDir.absolutePath
                    it.logMaxLines = 3000
                },
            )
            Libbox.redirectStderr(File(working, "stderr.log").absolutePath)
            setupDone = true
        }

        fun start(context: Context, config: String) {
            ensureSetup(context)
            BoxState.configFile(context).writeText(config)
            startResult.clear()
            headless = false
            ContextCompat.startForegroundService(
                context,
                Intent(context, BoxService::class.java).setAction(ACTION_START),
            )
            val outcome = startResult.poll(START_TIMEOUT_SECONDS, TimeUnit.SECONDS)
                ?: error("内核启动超时")
            if (outcome.isNotEmpty()) {
                error(outcome)
            }
        }

        fun stop() {
            val service = instance ?: return
            service.shutdown()
        }

        // 开机自启是在没有界面的情况下拉起来的，界面一旦接管就必须让状态归它，
        // 否则界面显示未连接而隧道仍在跑
        fun releaseHeadless() {
            val service = instance ?: return
            if (!headless) {
                return
            }
            headless = false
            Thread { service.shutdown() }.start()
        }
    }
}
