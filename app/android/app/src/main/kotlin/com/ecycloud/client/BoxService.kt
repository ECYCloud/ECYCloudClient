package com.ecycloud.client

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.ecycloud.mihomo.Mihomo
import com.ecycloud.mihomo.Protector
import org.json.JSONObject
import java.io.File
import java.net.InetAddress
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import android.app.Notification as AndroidNotification

class BoxService : VpnService() {

    private var tun: ParcelFileDescriptor? = null

    // 内核出站的 socket 不 protect 就会被本服务自己建的 TUN 再吸一遍，直接成环
    private val protector = Protector { fd -> protect(fd) }

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

    // 开机自启与系统重建服务都不带 intent，与界面点连接走同一条路：
    // 谁拉起来的不影响内核，界面起来后自己去接管
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        BoxState.starting = true
        QuickToggleService.refresh()
        try {
            foreground(getString(R.string.notification_starting))
        } catch (e: Exception) {
            // API 31+ 拒绝后台启动前台服务、API 34+ 拒绝准入条件不满足的 specialUse，
            // 两者都在主线程抛，不接住就直接带崩进程——反复崩溃后系统连重建都会放弃
            Thread { fail("系统拒绝前台服务（${e.message ?: e}）") }.start()
            return START_NOT_STICKY
        }
        Thread { launch() }.start()
        return START_STICKY
    }

    override fun onRevoke() {
        BoxState.revoked = true
        BoxState.error = "VPN 授权已被其它应用接管"
        note(LEVEL_INFO, "VPN 授权已被其它应用接管，停止内核")
        Thread { shutdown() }.start()
    }

    // 只收内核，不调 shutdown()：其中的 stopSelf 会把 START_STICKY 取消，
    // 系统本要重建服务时反被告知「不必再起」，隧道就此消失。
    // instance 判等是因为重建后的新实例可能已在 onCreate 里登记过自己
    override fun onDestroy() {
        if (instance === this) {
            instance = null
        }
        closeKernel()
        super.onDestroy()
    }

    // 系统按 START_STICKY 重建服务与界面下发的 kernel.start 是两条独立的路，内核进程
    // 独立后两者会真的并发；同时进两次 Mihomo.start 会把内核搞成半启动状态
    @Synchronized
    private fun launch() {
        BoxState.revoked = false
        BoxState.stoppedByUser = false
        val raw = runCatching { BoxState.configFile(this).readText() }.getOrNull()
        if (raw.isNullOrBlank()) {
            fail("没有可用的内核配置")
            return
        }

        // VpnService 路径必然接管出口。落盘配置可能仍是常驻时的 tun.enable=false
        // （界面断开后的 standby），不改过来内核不会接 fd
        val configJson = runCatching { JSONObject(raw) }.getOrElse {
            fail(it.message ?: it.toString())
            return
        }
        configJson.getJSONObject("tun").put("enable", true)
        // AOSP JSONObject 会把 / 编成 \/，mihomo 的 yaml.v3 不认该转义
        val config = configJson.toString().replace("\\/", "/")
        BoxState.configFile(this).writeText(config)

        try {
            ensureSetup(this)
            Mihomo.setProtector(protector)

            // 换配置重启时再 establish 一次，系统就地改这张网卡的地址与路由，不掉线
            val descriptor = establish(configJson)
            tun?.let { runCatching { it.close() } }
            tun = descriptor

            // 内核会把交给它的描述符包成 os.File 并在停止时关掉，给它一份独立副本，
            // 免得与 shutdown() 里的 close 撞成对同一个号的重复关闭
            Mihomo.start(config, descriptor.dup().detachFd())
        } catch (e: Exception) {
            fail(e.message ?: e.toString())
            return
        }

        BoxState.error = null
        BoxState.exitCode = null
        BoxState.startedAt = System.currentTimeMillis()
        BoxState.starting = false
        BoxState.running = true
        BoxState.takeover = true
        note(LEVEL_INFO, "内核已启动")
        foreground(getString(R.string.notification_running))
        QuickToggleService.refresh()
        startResult.offer("")
    }

    // 地址、路由、MTU 与分应用名单全部取自装配好的配置，不在 Kotlin 侧另算一份
    private fun establish(config: JSONObject): ParcelFileDescriptor {
        if (prepare(this) != null) {
            error("未授予 VPN 权限")
        }

        val options = config.getJSONObject("tun")
        val builder = Builder()
            .setSession(getString(R.string.app_name))
            .setMtu(options.getInt("mtu"))
            // FileDescriptor 路径上 sing-tun 不会 SetNonblock，阻塞 fd 会卡住读包
            .setBlocking(false)

        // targetSdk 29 起系统默认把 VpnService 建的网络标成计费网络，Play 商店、
        // 系统更新等按计费状态限流的应用会一直卡在「等待 WLAN」；置 false 后
        // 计费状态跟随底层物理网卡
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

        val inet4 = options.strings("inet4-address")
        val inet6 = options.strings("inet6-address")
        for (address in inet4 + inet6) {
            builder.addAddress(address.host(), address.prefixLength())
        }

        // route-exclude-address 只对内核自建的 TUN 生效，这张网卡由 VpnService 建，
        // 排除段得翻成补集逐条 addRoute（excludeRoute 要 API 33，minSdk 24 覆盖不到）
        val ranges = Mihomo.routeRanges(
            options.strings("route-exclude-address").joinToString("\n"),
        )
        for (range in ranges.lineSequence()) {
            // 没给地址的协议族不能加路由，Builder 会直接抛
            if ((if (range.contains(':')) inet6 else inet4).isEmpty()) {
                continue
            }
            builder.addRoute(range.host(), range.prefixLength())
        }

        // 内核把每个 TUN 地址的下一个地址当作 DNS 入口（listener/sing_tun/server.go
        // 按 Addr().Next() 拼 dns-hijack 目标），系统 DNS 必须指到同样的地址，并且
        // 必须单独给它补一条主机路由：这些地址落在被 route-exclude-address 排掉的私有
        // 网段里（172.16.0.0/12、fc00::/7），而 VpnService 那张网卡的路由表只由 addRoute
        // 决定——addAddress 带来的直连路由在主表，安全 VPN 的 UID 规则后面紧跟一条
        // prohibit，落不到主表上。少了这条路由，全机 DNS 查询一律不可达，域名一个都解析
        // 不出来，表现就是「显示已连接但没网」。Clash Meta for Android 的 TunService
        // 同样显式 addRoute(TUN_DNS, 32)
        for (address in inet4 + inet6) {
            val dns = address.host().nextAddress()
            builder.addDnsServer(dns)
            builder.addRoute(dns, if (dns.contains(':')) 128 else 32)
        }

        // 分应用名单仍由配置表达（内核的 include-package / exclude-package），
        // Kotlin 侧只做 Builder 的翻译，不另存一份
        val included = options.strings("include-package")
        for (name in included) {
            runCatching { builder.addAllowedApplication(name) }
        }
        // 只放行选中应用时本客户端也得在内，否则它自己的流量绕开隧道
        if (included.isNotEmpty()) {
            runCatching { builder.addAllowedApplication(packageName) }
        }
        for (name in options.strings("exclude-package")) {
            runCatching { builder.addDisallowedApplication(name) }
        }

        return builder.establish() ?: error("系统拒绝建立 VPN 连接")
    }

    private fun fail(reason: String) {
        BoxState.error = reason
        BoxState.exitCode = 1
        note(LEVEL_ERROR, "内核启动失败：$reason")
        startResult.offer(reason)
        shutdown()
    }

    private fun shutdown() {
        closeKernel()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun closeKernel() {
        Mihomo.stop()
        Mihomo.setProtector(null)
        tun?.let { runCatching { it.close() } }
        tun = null
        BoxState.starting = false
        BoxState.running = false
        BoxState.takeover = false
        QuickToggleService.refresh()
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

    // Dart 侧按内核的行内级别解析日志，级别缺失会一律当成 info
    private fun note(level: String, message: String) {
        BoxState.logs.append("$level $message")
    }

    private fun String.host(): String = substringBefore('/')

    private fun String.prefixLength(): Int = substringAfter('/').toInt()

    // 与内核的 netip.Addr.Next() 同一口径
    private fun String.nextAddress(): String {
        val bytes = InetAddress.getByName(this).address
        for (index in bytes.indices.reversed()) {
            bytes[index]++
            if (bytes[index] != 0.toByte()) {
                break
            }
        }
        return InetAddress.getByAddress(bytes).hostAddress
    }

    // 配置里没有这个键就是没配
    private fun JSONObject.strings(name: String): List<String> {
        val array = optJSONArray(name) ?: return emptyList()
        return (0 until array.length()).map(array::getString)
    }

    companion object {
        private const val CHANNEL_STATUS = "ecycloud-status"
        private const val NOTIFICATION_ID = 1
        private const val LEVEL_INFO = "INFO"
        private const val LEVEL_WARNING = "WARNING"
        private const val LEVEL_ERROR = "ERROR"
        private const val START_TIMEOUT_SECONDS = 180L

        // 内核认的 geodata 本地文件名（mihomo constant/path.go），与 APK assets 里的同名
        private val GEO_DATA_FILES = arrayOf("geoip.metadb", "GeoSite.dat")

        private val startResult = ArrayBlockingQueue<String>(1)

        @Volatile
        private var instance: BoxService? = null

        @Volatile
        private var setupDone = false

        @Synchronized
        fun ensureSetup(context: Context) {
            if (setupDone) {
                return
            }
            // cache.db、geodata 与 rule-providers 都落在这里，与 Dart 侧
            // AppPaths.kernelConfigFile 所在目录必须是同一个
            val runDir = BoxState.runDir(context).also { it.mkdirs() }
            seedGeoData(context, runDir)
            Mihomo.setup(runDir.absolutePath)
            setupDone = true
        }

        /**
         * 把 APK 里的 geodata 铺进内核运行目录。
         *
         * 内核解析 GEOIP / GEOSITE 规则时会就地读这两个库，缺文件就按 geox-url 同步下载，
         * 而面板下发的地址指向 GitHub，在目标网络里必然超时，整份配置随之校验失败、内核起不来。
         * 已存在的不覆盖：内核 geo-auto-update 刷新过的那份比包内的新。
         * 失败不抛：内核仍可自行下载，只是慢且依赖网络能通。
         */
        private fun seedGeoData(context: Context, runDir: File) {
            for (name in GEO_DATA_FILES) {
                val target = File(runDir, name)
                if (target.exists()) {
                    continue
                }
                runCatching {
                    context.assets.open(name).use { input ->
                        target.outputStream().use { output -> input.copyTo(output) }
                    }
                }.onFailure {
                    // 半截文件会让内核的 Verify 失败后试图删了重下，留着比删掉更糟
                    target.delete()
                    BoxState.logs.append("$LEVEL_WARNING 播种 $name 失败，内核将自行下载：$it")
                }
            }
        }

        fun start(context: Context, config: String) {
            ensureSetup(context)
            BoxState.configFile(context).writeText(config)

            // 这一轮接不接管出口由配置里的 tun.enable 表达，与桌面端同一份装配逻辑。
            // 不接管时内核只需在进程内跑起来供控制面使用：不建隧道、不弹授权、
            // 不占通知栏，用户没按连接却看见一条 VPN 才是不对的
            if (!BoxState.takesOverExit(config)) {
                standby(config)
                return
            }

            startResult.clear()
            // 换配置重启时服务还在前台跑着，内核就地重载即可；再过一遍
            // startForegroundService 只会在后台被 API 31+ 的启动限制拒掉。
            // 判据是 takeover 而不是 running：常驻内核不在 VpnService 里，此时
            // instance 可能是一个已经 stopSelf()、只等系统回收的壳，不能拿来建隧道
            val service = instance
            if (service != null && BoxState.takeover) {
                service.launch()
            } else {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, BoxService::class.java),
                )
            }

            val outcome = startResult.poll(START_TIMEOUT_SECONDS, TimeUnit.SECONDS)
                ?: error("内核启动超时")
            if (outcome.isNotEmpty()) {
                error(outcome)
            }
        }

        /**
         * 内核常驻但不接管出口。起它不需要 VpnService。
         *
         * protect 回调必须摘掉：它要经 VpnService 实例才能生效，服务不在时每个出站
         * socket 都会被判成 protect 失败，内核一条连接也拨不出去。
         */
        private fun standby(config: String) {
            instance?.takeIf { BoxState.takeover }?.shutdown()
            Mihomo.setProtector(null)
            try {
                Mihomo.start(config, 0)
            } catch (e: Exception) {
                val reason = e.message ?: e.toString()
                BoxState.error = reason
                BoxState.exitCode = 1
                BoxState.running = false
                BoxState.takeover = false
                BoxState.logs.append("$LEVEL_ERROR 内核常驻启动失败：$reason")
                error(reason)
            }

            BoxState.error = null
            BoxState.exitCode = null
            BoxState.startedAt = System.currentTimeMillis()
            BoxState.starting = false
            BoxState.running = true
            BoxState.takeover = false
            BoxState.logs.append("$LEVEL_INFO 内核已常驻，未接管出口")
            QuickToggleService.refresh()
        }

        fun stop() {
            val service = instance
            if (service != null) {
                service.shutdown()
                return
            }

            // 常驻的内核不在 VpnService 里，服务不在也要把它停掉
            Mihomo.stop()
            BoxState.starting = false
            BoxState.running = false
            BoxState.takeover = false
            QuickToggleService.refresh()
        }
    }
}
