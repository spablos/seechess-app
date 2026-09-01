package com.seechess.seechess

import android.Manifest
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Offline-match Wi-Fi automation, Android side.
 *
 * hostStart: spin up a local-only hotspot (no internet, app-owned) and hand
 * back its SSID/passphrase so the host's QR can carry them — the guest then
 * joins without touching Settings. Requires fine-location permission and
 * location services on (Android's rule for hotspot APIs, not ours).
 *
 * guestJoin: join the hotspot named in a scanned QR via WifiNetworkSpecifier
 * (a peer-to-peer, no-internet connection the OS keeps only while requested)
 * and pin the process to it so the match socket routes over it.
 */
class MainActivity : FlutterActivity() {
    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var pendingStart: MethodChannel.Result? = null
    private var guestCallback: ConnectivityManager.NetworkCallback? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "seechess/hotspot"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "hostStart" -> hostStart(result)
                "hostStop" -> {
                    reservation?.close()
                    reservation = null
                    result.success(null)
                }
                "guestJoin" -> guestJoin(
                    call.argument<String>("ssid")!!,
                    call.argument<String>("pass")!!,
                    result
                )
                "guestLeave" -> {
                    guestCallback?.let {
                        val cm = getSystemService(ConnectivityManager::class.java)
                        cm.bindProcessToNetwork(null)
                        cm.unregisterNetworkCallback(it)
                    }
                    guestCallback = null
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hostStart(result: MethodChannel.Result) {
        if (reservation != null) {
            result.success(currentConfig())
            return
        }
        if (ContextCompat.checkSelfPermission(
                this, Manifest.permission.ACCESS_FINE_LOCATION
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            pendingStart = result
            ActivityCompat.requestPermissions(
                this, arrayOf(Manifest.permission.ACCESS_FINE_LOCATION), 7311
            )
            return
        }
        reallyStart(result)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 7311) return
        val result = pendingStart ?: return
        pendingStart = null
        if (grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        ) {
            reallyStart(result)
        } else {
            result.error("denied", "location permission denied", null)
        }
    }

    private fun reallyStart(result: MethodChannel.Result) {
        val wifi = applicationContext.getSystemService(WifiManager::class.java)
        try {
            wifi.startLocalOnlyHotspot(
                object : WifiManager.LocalOnlyHotspotCallback() {
                    override fun onStarted(
                        r: WifiManager.LocalOnlyHotspotReservation
                    ) {
                        reservation = r
                        result.success(currentConfig())
                    }

                    override fun onFailed(reason: Int) {
                        result.error("failed", "hotspot failed: $reason", null)
                    }

                    override fun onStopped() {
                        reservation = null
                    }
                },
                null
            )
        } catch (e: Exception) {
            // SecurityException when location services are off, IllegalState
            // when tethering is active — the Dart side falls back to manual
            result.error("failed", e.message, null)
        }
    }

    @Suppress("DEPRECATION")
    private fun currentConfig(): Map<String, String?>? {
        val r = reservation ?: return null
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val c = r.softApConfiguration
            mapOf("ssid" to c.ssid, "pass" to c.passphrase)
        } else {
            val c = r.wifiConfiguration
            mapOf("ssid" to c?.SSID, "pass" to c?.preSharedKey)
        }
    }

    private fun guestJoin(ssid: String, pass: String, result: MethodChannel.Result) {
        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .setWpa2Passphrase(pass)
            .build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()
        val cm = getSystemService(ConnectivityManager::class.java)
        var replied = false
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                cm.bindProcessToNetwork(network)
                runOnUiThread {
                    if (!replied) {
                        replied = true
                        result.success(true)
                    }
                }
            }

            override fun onUnavailable() {
                runOnUiThread {
                    if (!replied) {
                        replied = true
                        result.success(false)
                    }
                }
            }
        }
        guestCallback?.let { cm.unregisterNetworkCallback(it) }
        guestCallback = callback
        cm.requestNetwork(request, callback, 30000)
    }

    override fun onDestroy() {
        reservation?.close()
        reservation = null
        super.onDestroy()
    }
}
