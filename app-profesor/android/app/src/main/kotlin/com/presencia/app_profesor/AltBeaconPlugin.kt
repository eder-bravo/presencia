package com.presencia.app_profesor

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.altbeacon.beacon.Beacon
import org.altbeacon.beacon.BeaconManager
import org.altbeacon.beacon.BeaconParser
import org.altbeacon.beacon.Identifier
import org.altbeacon.beacon.RangeNotifier
import org.altbeacon.beacon.Region

class AltBeaconPlugin(
    private val activity: FlutterActivity,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private const val TAG = "AltBeaconPlugin"
        private const val METHOD_CHANNEL = "com.presencia/altbeacon"
        private const val EVENT_CHANNEL = "com.presencia/altbeacon_events"
        private const val REGION_ID = "com.presencia.altbeacon.region"
    }

    private val context: Context get() = activity.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val beaconManager: BeaconManager by lazy {
        BeaconManager.getInstanceForApplication(context)
    }

    private var eventSink: EventChannel.EventSink? = null
    private var activeRegion: Region? = null
    private var activeUuids: Set<String> = emptySet()
    @Volatile
    private var isActivityInForeground = true

    private val rangeNotifier = RangeNotifier { beacons, _ ->
        if (!isActivityInForeground || activeUuids.isEmpty()) {
            return@RangeNotifier
        }

        val targetUuids = activeUuids
        val payload = beacons
            .asSequence()
            .filter { beacon ->
                targetUuids.isEmpty() ||
                    targetUuids.contains(normalizeUuid(beacon.id1?.toString()))
            }
            .map { beacon -> beacon.toMap() }
            .toList()

        if (payload.isNotEmpty()) {
            mainHandler.post {
                if (isActivityInForeground) {
                    eventSink?.success(payload)
                }
            }
        }
    }

    fun register(messenger: BinaryMessenger) {
        setupBeaconParsers()
        // AltBeacon enables scheduled scan jobs by default on Android 8+.
        // They can continue scanning without a visible app, so use the regular
        // activity-bound service exclusively for this app.
        beaconManager.setEnableScheduledScanJobs(false)
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
    }

    /** Stops any active ranging as soon as the Flutter activity loses foreground. */
    fun onActivityPaused() {
        isActivityInForeground = false
        stopScanning()
    }

    /** Scanning is never resumed automatically; the visible Flutter flow starts it again. */
    fun onActivityResumed() {
        isActivityInForeground = true
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkBluetoothState" -> result.success(getBluetoothState())
            "startScanning" -> {
                val uuid = call.argument<String>("uuid")
                val uuids = call.argument<List<String>>("uuids")
                    ?: uuid?.let { listOf(it) }
                    ?: emptyList()

                if (uuids.isEmpty()) {
                    result.error("INVALID_ARGUMENT", "Se requiere al menos un UUID", null)
                    return
                }

                try {
                    startScanning(uuids)
                    result.success(true)
                } catch (error: Exception) {
                    Log.e(TAG, "Error starting AltBeacon scan", error)
                    result.error("SCAN_ERROR", error.message, null)
                }
            }
            "stopScanning" -> {
                stopScanning()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun setupBeaconParsers() {
        val parsers = beaconManager.beaconParsers
        val layouts = listOf(
            "m:2-3=beac,i:4-19,i:20-21,i:22-23,p:24-24,d:25-25",
            "m:2-3=0215,i:4-19,i:20-21,i:22-23,p:24-24",
        )

        layouts.forEach { layout ->
            parsers.add(BeaconParser().setBeaconLayout(layout))
        }
    }

    private fun startScanning(uuids: List<String>) {
        if (!isActivityInForeground) {
            throw IllegalStateException("El escaneo de beacons solo está disponible con la app en primer plano")
        }
        ensureRuntimePermissions()
        if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.R && !isLocationEnabled()) {
            throw IllegalStateException("Activa la ubicación del teléfono para buscar el beacon del salón")
        }
        stopScanning()

        activeUuids = uuids.map { normalizeUuid(it) }.filter { it.isNotEmpty() }.toSet()

        if (activeUuids.isEmpty()) {
            throw IllegalArgumentException("UUID inválido")
        }
        if (!isBluetoothPoweredOn()) {
            throw IllegalStateException("Bluetooth no disponible o apagado")
        }
        val regionIdentifier = if (activeUuids.size == 1) {
            Identifier.parse(activeUuids.first())
        } else {
            null
        }
        val region = Region(
            REGION_ID,
            regionIdentifier,
            null,
            null,
        )
        activeRegion = region

        beaconManager.addRangeNotifier(rangeNotifier)
        beaconManager.startRangingBeacons(region)
        Log.i(TAG, "AltBeacon scan started for ${activeUuids.size} UUID(s)")
    }

    private fun stopScanning() {
        activeRegion?.let { region ->
            try {
                beaconManager.stopRangingBeacons(region)
            } catch (error: Exception) {
                Log.w(TAG, "Error stopping ranging: ${error.message}")
            }
        }
        beaconManager.removeRangeNotifier(rangeNotifier)
        beaconManager.shutdownIfIdle()
        activeRegion = null
        activeUuids = emptySet()
    }

    private fun ensureRuntimePermissions() {
        val missing = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (!hasPermission(Manifest.permission.BLUETOOTH_SCAN)) {
                missing.add(Manifest.permission.BLUETOOTH_SCAN)
            }
            if (!hasPermission(Manifest.permission.BLUETOOTH_CONNECT)) {
                missing.add(Manifest.permission.BLUETOOTH_CONNECT)
            }
        }
        if (!hasPermission(Manifest.permission.ACCESS_FINE_LOCATION)) {
            missing.add(Manifest.permission.ACCESS_FINE_LOCATION)
        }

        if (missing.isNotEmpty()) {
            throw SecurityException("Permisos faltantes: ${missing.joinToString()}")
        }
    }

    private fun hasPermission(permission: String): Boolean {
        return ContextCompat.checkSelfPermission(context, permission) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun isLocationEnabled(): Boolean {
        val manager = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            manager.isLocationEnabled
        } else {
            manager.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        }
    }

    private fun getBluetoothState(): String {
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            ?: return "unsupported"
        return when (manager.adapter?.state) {
            BluetoothAdapter.STATE_ON -> "poweredOn"
            BluetoothAdapter.STATE_OFF -> "poweredOff"
            BluetoothAdapter.STATE_TURNING_ON,
            BluetoothAdapter.STATE_TURNING_OFF -> "transitioning"
            else -> "unknown"
        }
    }

    private fun isBluetoothPoweredOn(): Boolean {
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            ?: return false
        val adapter = manager.adapter ?: return false
        return adapter.state == BluetoothAdapter.STATE_ON && adapter.isEnabled
    }

    private fun normalizeUuid(uuid: String?): String {
        return uuid?.replace("-", "")?.lowercase()?.trim().orEmpty()
    }

    private fun Beacon.toMap(): Map<String, Any?> {
        return mapOf(
            "uuid" to id1?.toString(),
            "major" to id2?.toInt(),
            "minor" to id3?.toInt(),
            "rssi" to rssi,
            "distance" to distance,
            "txPower" to txPower,
            "bluetoothAddress" to bluetoothAddress,
        )
    }
}
