package com.netkings.netkings

import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/** Bridge to the Flutter UI: method channel "netkings/vpn" (start / stop / status / links), event channel
 *  "netkings/vpn/status" (status changes), deep links netkings://import/<subscription url> from the bot. */
class MainActivity : FlutterActivity() {
    private val main = Handler(Looper.getMainLooper())
    private var pendingConfig: String? = null
    private var pendingResult: MethodChannel.Result? = null
    private var channel: MethodChannel? = null
    private var initialLink: String? = null

    companion object {
        private const val REQ_VPN = 7001
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        initialLink = intent?.dataString
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "netkings/vpn")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val config = call.argument<String>("config")!!
                    val prepare = VpnService.prepare(this)
                    if (prepare == null) {
                        startVpn(config)
                        result.success(true)
                    } else {
                        pendingConfig = config
                        pendingResult = result
                        startActivityForResult(prepare, REQ_VPN)
                    }
                }
                "stop" -> {
                    startService(Intent(this, NkVpnService::class.java).setAction(NkVpnService.ACTION_STOP))
                    result.success(true)
                }
                "status" -> result.success(mapOf("status" to NkVpnService.status, "error" to NkVpnService.lastError))
                "initialLink" -> {
                    result.success(initialLink)
                    initialLink = null
                }
                "device" -> result.success(mapOf("model" to "${Build.MANUFACTURER} ${Build.MODEL}", "os" to "Android ${Build.VERSION.RELEASE}",
                    "abi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: "")))
                // update downloaded by the Flutter side: the system installer takes it from here
                "installApk" -> {
                    val uri = FileProvider.getUriForFile(this, "$packageName.files", File(call.argument<String>("path")!!))
                    startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(true)
                }
                // "always-on VPN" / "block connections without VPN" (kill switch) live in the system settings
                "vpnSettings" -> {
                    startActivity(Intent(Settings.ACTION_VPN_SETTINGS))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "netkings/vpn/status").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    NkVpnService.listener = { s, e -> main.post { events.success(mapOf("status" to s, "error" to e)) } }
                    events.success(mapOf("status" to NkVpnService.status, "error" to NkVpnService.lastError))
                }

                override fun onCancel(arguments: Any?) {
                    NkVpnService.listener = null
                }
            },
        )
    }

    private fun startVpn(config: String) {
        val i = Intent(this, NkVpnService::class.java).setAction(NkVpnService.ACTION_START).putExtra(NkVpnService.EXTRA_CONFIG, config)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(i) else startService(i)
    }

    @Deprecated("startActivityForResult is enough for the one VPN consent dialog")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_VPN) return
        val ok = resultCode == RESULT_OK
        pendingConfig?.takeIf { ok }?.let { startVpn(it) }
        pendingResult?.success(ok)
        pendingConfig = null
        pendingResult = null
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.dataString?.let { channel?.invokeMethod("link", it) }
    }
}
