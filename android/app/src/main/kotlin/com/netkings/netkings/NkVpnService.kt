package com.netkings.netkings

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelFileDescriptor
import android.system.OsConstants
import android.util.Log
import io.nekohasekai.libbox.BridgeOptions
import io.nekohasekai.libbox.BridgeSession
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.NeighborUpdateListener
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.PlatformUser
import io.nekohasekai.libbox.RoutePrefix
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.ShellSession
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.io.File
import java.net.Inet6Address
import java.net.NetworkInterface
import io.nekohasekai.libbox.NetworkInterface as BoxInterface

/**
 * The VPN: sing-box (libbox) running inside this service. The Flutter side hands over a full sing-box config
 * (built from the subscription), this service only opens the TUN for it and tells the core which network is the
 * real one (so its own sockets bypass the tunnel).
 */
class NkVpnService : VpnService(), PlatformInterface, CommandServerHandler {
    companion object {
        private const val TAG = "NkVpn"
        const val ACTION_START = "com.netkings.vpn.START"
        const val ACTION_STOP = "com.netkings.vpn.STOP"
        const val EXTRA_CONFIG = "config"
        private const val CHANNEL = "vpn"
        private const val NOTIFICATION_ID = 1

        @Volatile var status = "stopped"      // stopped | starting | started | stopping
            private set
        @Volatile var lastError: String? = null
            private set
        @Volatile var listener: ((String, String?) -> Unit)? = null
        private var setupDone = false

        fun setup(ctx: Context) {
            if (setupDone) return
            val work = File(ctx.filesDir, "box").apply { mkdirs() }
            Libbox.setup(SetupOptions().apply {
                basePath = ctx.filesDir.path
                workingPath = work.path
                tempPath = ctx.cacheDir.path
                fixAndroidStack = Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && Build.VERSION.SDK_INT <= Build.VERSION_CODES.N_MR1
                logMaxLines = 300
                appVersion = BuildConfig.VERSION_CODE.toString()
                appMarketingVersion = BuildConfig.VERSION_NAME
            })
            setupDone = true
        }

        fun configFile(ctx: Context) = File(ctx.filesDir, "active-config.json")
    }

    private var server: CommandServer? = null
    private var tunFd: ParcelFileDescriptor? = null
    private val connectivity by lazy { getSystemService(ConnectivityManager::class.java) }
    private val netHandler by lazy { Handler(HandlerThread("nk-net").apply { start() }.looper) }
    @Volatile private var defaultNetwork: Network? = null
    @Volatile private var interfaceListener: InterfaceUpdateListener? = null
    private var netCallback: ConnectivityManager.NetworkCallback? = null

    private fun setStatus(s: String, error: String? = null) {
        status = s
        if (s == "starting") lastError = null
        if (error != null) lastError = error
        listener?.invoke(s, lastError)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopVpn(null)
            return START_NOT_STICKY
        }
        // null intent = the system restarted us (START_STICKY): reuse the last config
        val config = intent?.getStringExtra(EXTRA_CONFIG)?.also { configFile(this).writeText(it) }
            ?: configFile(this).takeIf { it.exists() }?.readText()
        if (config == null || status == "started" || status == "starting") return START_STICKY
        startForegroundCompat()
        setStatus("starting")
        Thread { startVpn(config) }.start()
        return START_STICKY
    }

    private fun startVpn(config: String) {
        try {
            setup(this)
            startNetworkMonitor()
            val s = CommandServer(this, this)
            s.start()
            server = s
            s.startOrReloadService(config, OverrideOptions())
            setStatus("started")
        } catch (e: Exception) {
            Log.e(TAG, "start", e)
            stopVpn(e.message ?: e.toString())
        }
    }

    @Synchronized
    private fun stopVpn(error: String?) {
        if (status == "stopped" && server == null) return
        setStatus("stopping")
        runCatching { server?.closeService() }
        runCatching { server?.close() }
        server = null
        runCatching { tunFd?.close() }
        tunFd = null
        stopNetworkMonitor()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE) else @Suppress("DEPRECATION") stopForeground(true)
        stopSelf()
        setStatus("stopped", error)
    }

    override fun onRevoke() = stopVpn(null)      // another VPN app took over / user revoked in settings

    override fun onDestroy() {
        stopVpn(null)
        super.onDestroy()
    }

    private fun startForegroundCompat() {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "VPN", NotificationManager.IMPORTANCE_LOW))
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, NkVpnService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(this)
        val n = b.setSmallIcon(R.drawable.ic_stat_vpn)
            .setContentTitle("NetKings VPN")
            .setContentText("Подключено")
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Отключить", stop).build())
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }

    // ---- the real (non-VPN) default network, for the core's own sockets -----------------------------

    private fun startNetworkMonitor() {
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = update(network)
            override fun onLinkPropertiesChanged(network: Network, lp: LinkProperties) = update(network)
            override fun onLost(network: Network) {
                if (network == defaultNetwork) update(null)
            }
        }
        netCallback = cb
        // registerDefaultNetworkCallback would report our own VPN; ask for the best non-VPN network instead
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            connectivity.registerBestMatchingNetworkCallback(request, cb, netHandler)
        } else {
            connectivity.requestNetwork(request, cb, netHandler)
        }
        defaultNetwork = connectivity.activeNetwork
    }

    private fun stopNetworkMonitor() {
        netCallback?.let { runCatching { connectivity.unregisterNetworkCallback(it) } }
        netCallback = null
    }

    private fun update(network: Network?) {
        defaultNetwork = network
        val l = interfaceListener ?: return
        if (network == null) {
            l.updateDefaultInterface("", -1, false, false)
            return
        }
        repeat(10) {
            val name = connectivity.getLinkProperties(network)?.interfaceName
            val index = name?.let { runCatching { NetworkInterface.getByName(it).index }.getOrNull() }
            if (name != null && index != null) {
                l.updateDefaultInterface(name, index, false, false)
                return
            }
            Thread.sleep(100)
        }
    }

    // ---- PlatformInterface ------------------------------------------------------------------------------

    override fun usePlatformAutoDetectInterfaceControl() = true

    override fun autoDetectInterfaceControl(fd: Int) {
        protect(fd)
    }

    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) error("нет разрешения на VPN")
        val b = Builder().setSession("NetKings").setMtu(options.mtu)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) b.setMetered(false)
        options.inet4Address.let { while (it.hasNext()) it.next().let { a -> b.addAddress(a.address(), a.prefix()) } }
        options.inet6Address.let { while (it.hasNext()) it.next().let { a -> b.addAddress(a.address(), a.prefix()) } }
        if (options.autoRoute) {
            options.dnsServerAddress.let { while (it.hasNext()) b.addDnsServer(it.next()) }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val r4 = options.inet4RouteAddress
                if (r4.hasNext()) while (r4.hasNext()) b.addRoute(r4.next().toIpPrefix())
                else if (options.inet4Address.hasNext()) b.addRoute("0.0.0.0", 0)
                val r6 = options.inet6RouteAddress
                if (r6.hasNext()) while (r6.hasNext()) b.addRoute(r6.next().toIpPrefix())
                else if (options.inet6Address.hasNext()) b.addRoute("::", 0)
                options.inet4RouteExcludeAddress.let { while (it.hasNext()) b.excludeRoute(it.next().toIpPrefix()) }
                options.inet6RouteExcludeAddress.let { while (it.hasNext()) b.excludeRoute(it.next().toIpPrefix()) }
            } else {
                options.inet4RouteRange.let { while (it.hasNext()) it.next().let { a -> b.addRoute(a.address(), a.prefix()) } }
                options.inet6RouteRange.let { while (it.hasNext()) it.next().let { a -> b.addRoute(a.address(), a.prefix()) } }
            }
        }
        val pfd = b.establish() ?: error("VPN не запущен: приложение не подготовлено или разрешение отозвано")
        tunFd = pfd
        return pfd.fd
    }

    private fun RoutePrefix.toIpPrefix() = IpPrefix(java.net.InetAddress.getByName(address()), prefix())

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        interfaceListener = listener
        netHandler.post { update(defaultNetwork) }
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        interfaceListener = null
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        val javaIfs = NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
        val out = mutableListOf<BoxInterface>()
        for (network in connectivity.allNetworks) {
            val lp = connectivity.getLinkProperties(network) ?: continue
            val caps = connectivity.getNetworkCapabilities(network) ?: continue
            val ji = javaIfs.find { it.name == lp.interfaceName } ?: continue
            out += BoxInterface().apply {
                name = lp.interfaceName
                index = ji.index
                runCatching { mtu = ji.mtu }
                dnsServer = StringArray(lp.dnsServers.mapNotNull { it.hostAddress }.iterator())
                type = when {
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Libbox.InterfaceTypeWIFI
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Libbox.InterfaceTypeCellular
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Libbox.InterfaceTypeEthernet
                    else -> Libbox.InterfaceTypeOther
                }
                addresses = StringArray(ji.interfaceAddresses.map {
                    val host = if (it.address is Inet6Address) Inet6Address.getByAddress(it.address.address).hostAddress else it.address.hostAddress
                    "$host/${it.networkPrefixLength}"
                }.iterator())
                var f = 0
                if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) f = OsConstants.IFF_UP or OsConstants.IFF_RUNNING
                if (ji.isLoopback) f = f or OsConstants.IFF_LOOPBACK
                if (ji.isPointToPoint) f = f or OsConstants.IFF_POINTOPOINT
                if (ji.supportsMulticast()) f = f or OsConstants.IFF_MULTICAST
                flags = f
                metered = !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            }
        }
        val it = out.iterator()
        return object : NetworkInterfaceIterator {
            override fun hasNext() = it.hasNext()
            override fun next() = it.next()
        }
    }

    override fun findConnectionOwner(ipProtocol: Int, sourceAddress: String, sourcePort: Int, destinationAddress: String, destinationPort: Int): ConnectionOwner =
        error("not used")      // no process rules in our configs
    override fun underNetworkExtension() = false
    override fun includeAllNetworks() = false
    override fun readWIFIState(): WIFIState? = null
    override fun clearDNSCache() {}
    override fun localDNSTransport(): LocalDNSTransport? = null
    override fun sendNotification(notification: io.nekohasekai.libbox.Notification) {}
    override fun cancelNotification(identifier: String, typeID: Int) {}
    override fun startNeighborMonitor(listener: NeighborUpdateListener?) {}
    override fun closeNeighborMonitor(listener: NeighborUpdateListener?) {}
    override fun registerMyInterface(name: String?) {}
    override fun usePlatformShell() = false
    override fun checkPlatformShell() = error("not supported")
    override fun openShellSession(user: PlatformUser?, command: String?, environ: StringIterator?, term: String?, rows: Int, cols: Int): ShellSession = error("not supported")
    override fun lookupUser(username: String?): PlatformUser = error("not supported")
    override fun lookupSFTPServer(): String = error("not supported")
    override fun readSystemSSHHostKey(): String = error("not supported")
    override fun tailscaleHostname() = ""
    override fun usePlatformBridge() = false
    override fun createBridge(options: BridgeOptions?): BridgeSession = error("not supported")

    // ---- CommandServerHandler ---------------------------------------------------------------------------

    override fun serviceStop() = stopVpn(null)
    override fun serviceReload() {}
    override fun getSystemProxyStatus() = SystemProxyStatus()
    override fun setSystemProxyEnabled(enabled: Boolean) {}
    override fun connectSSHAgent(): Int = error("not supported")
    override fun triggerNativeCrash() {}
    override fun writeDebugMessage(message: String?) {
        Log.d(TAG, message ?: "")
    }

    private class StringArray(private val it: Iterator<String>) : StringIterator {
        override fun len() = 0
        override fun hasNext() = it.hasNext()
        override fun next() = it.next()
    }
}
