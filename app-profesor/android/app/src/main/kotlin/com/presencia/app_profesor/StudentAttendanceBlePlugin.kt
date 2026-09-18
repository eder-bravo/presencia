package com.presencia.app_profesor

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.charset.Charset
import java.util.UUID

class StudentAttendanceBlePlugin(
    private val activity: FlutterActivity,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private const val TAG = "StudentAttendanceBLE"
        private const val METHOD_CHANNEL = "com.presencia/student_attendance_ble"
        private const val EVENT_CHANNEL = "com.presencia/student_attendance_ble_events"
        // 185 bytes is broadly supported by Android/iOS controllers and is
        // ample for the small JSON confirmation without stressing OEM stacks.
        private const val REQUESTED_MTU = 185
        private const val TEACHER_ACK_TIMEOUT_MS = 20_000L
        private const val GATT_CONNECTION_TIMEOUT_MS = 12_000L
        private const val SCAN_WINDOW_MS = 120_000L
        private const val SCAN_RESTART_DELAY_MS = 500L
        private const val MAX_SCAN_ATTEMPTS = 2
        private const val MAX_CONCURRENT_GATT_CONNECTIONS = 4
        private val SERVICE_UUID: UUID = UUID.fromString("9f5f7f86-8e67-4f12-a8a5-b7f6f4f7b2c1")
        private val ATTENDANCE_UUID_CHAR: UUID = UUID.fromString("9f5f7f86-8e67-4f12-a8a5-b7f6f4f7b2c2")
        private val CONFIRMATION_CHAR: UUID = UUID.fromString("9f5f7f86-8e67-4f12-a8a5-b7f6f4f7b2c3")
    }

    private val context: Context get() = activity.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private var targetUuids: Set<String> = emptySet()
    private var confirmationPayloads: Map<String, String> = emptyMap()
    private val handledUuids = mutableSetOf<String>()
    private val inFlightUuids = mutableSetOf<String>()
    private val activeGatts = mutableMapOf<String, BluetoothGatt>()
    private val mtuByAddress = mutableMapOf<String, Int>()
    private val pendingDetections = mutableMapOf<String, PendingDetection>()
    private val pendingAddressByUuid = mutableMapOf<String, String>()
    private val connectionTimeouts = mutableMapOf<String, Runnable>()
    private val scanTimeout = Runnable {
        if (!isScanning) return@Runnable
        if (scanAttempt < MAX_SCAN_ATTEMPTS) {
            restartScanAfterTimeout()
            return@Runnable
        }
        Log.i(TAG, "Student BLE scan exhausted both two-minute attempts")
        stopScanning()
        eventSink?.error(
            "SCAN_TIMEOUT",
            "El escaneo terminó después de cuatro minutos",
            null,
        )
    }
    private var scanAttempt = 0
    private var scanGeneration = 0
    private var scanPausedForCompletedRoster = false
    @Volatile
    private var isActivityInForeground = true
    @Volatile
    private var isScanning = false

    private data class PendingDetection(
        val uuid: String,
        val bluetoothAddress: String,
        val rssi: Int,
        val normalizedUuid: String,
    )

    private val bluetoothAdapter: BluetoothAdapter?
        get() = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            if (isActivityInForeground && isScanning && isStudentAttendanceCandidate(result)) {
                connectToCandidate(result)
            }
        }

        override fun onBatchScanResults(results: MutableList<ScanResult>) {
            if (isActivityInForeground && isScanning) {
                results
                    .asSequence()
                    .filter(::isStudentAttendanceCandidate)
                    .forEach(::connectToCandidate)
            }
        }

        override fun onScanFailed(errorCode: Int) {
            Log.e(TAG, "Scan failed: $errorCode")
            mainHandler.post {
                if (!isScanning) return@post
                stopScanning()
                eventSink?.error(
                    "SCAN_FAILED",
                    scanFailureMessage(errorCode),
                    errorCode,
                )
            }
        }
    }

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
    }

    /** Stops the student BLE scan and open GATT connections outside the visible app. */
    fun onActivityPaused() {
        isActivityInForeground = false
        stopScanning()
    }

    /** Scanning is only started again by an explicit action in the visible UI. */
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
            "startScanning", "updateBindings" -> {
                val rawPayloads = call.argument<Map<*, *>>("confirmationPayloads")
                val payloads = rawPayloads
                    ?.entries
                    ?.mapNotNull { entry ->
                        val uuid = entry.key as? String ?: return@mapNotNull null
                        val payload = entry.value as? String ?: return@mapNotNull null
                        val normalized = normalizeUuid(uuid)
                        if (normalized.isEmpty() || payload.isBlank()) null else normalized to payload
                    }
                    ?.toMap()
                    .orEmpty()
                if (rawPayloads == null || (payloads.isEmpty() && call.method == "startScanning")) {
                    result.error("INVALID_ARGUMENT", "Se requieren confirmaciones por matricula", null)
                    return
                }
                try {
                    if (call.method == "updateBindings") {
                        result.success(updateBindings(payloads))
                    } else {
                        startScanning(payloads)
                        result.success(true)
                    }
                } catch (error: SecurityException) {
                    Log.e(TAG, "Missing permission for student BLE scan", error)
                    result.error("PERMISSION_DENIED", error.message, null)
                } catch (error: IllegalStateException) {
                    Log.e(TAG, "Bluetooth unavailable for student scan", error)
                    val code = if (error.message?.contains("Bluetooth") == true) {
                        "BLUETOOTH_OFF"
                    } else {
                        "SCAN_ERROR"
                    }
                    result.error(code, error.message, null)
                } catch (error: Exception) {
                    Log.e(TAG, "Error starting student BLE scan", error)
                    result.error("SCAN_ERROR", error.message, null)
                }
            }
            "stopScanning" -> {
                stopScanning()
                result.success(true)
            }
            "confirmAttendance" -> {
                val normalized = normalizeUuid(call.argument<String>("uuid"))
                if (normalized.isEmpty()) {
                    result.error("INVALID_ARGUMENT", "Se requiere el UUID del alumno", null)
                    return
                }
                result.success(confirmAttendance(normalized))
            }
            "getAndroidSdkInt" -> result.success(Build.VERSION.SDK_INT)
            "checkBluetoothState" -> result.success(getBluetoothState())
            "checkLocationServices" -> result.success(isLocationEnabled())
            "openBluetoothSettings" -> result.success(openSettings(Settings.ACTION_BLUETOOTH_SETTINGS))
            "openLocationSettings" -> result.success(openSettings(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
            else -> result.notImplemented()
        }
    }

    @SuppressLint("MissingPermission")
    private fun updateBindings(payloads: Map<String, String>): Boolean {
        if (!isActivityInForeground || scanAttempt == 0) return false
        val previousPayloads = confirmationPayloads
        val previousTargets = targetUuids
        confirmationPayloads = payloads
        targetUuids = payloads.keys
        try {
            // A completed roster pauses only the radio. New students can resume
            // it without clearing handled UUIDs or closing pending GATT writes.
            if (scanPausedForCompletedRoster && !handledUuids.containsAll(targetUuids)) {
                ensureRuntimePermissions()
                val scanner = readyBluetoothLeScanner()
                    ?: throw IllegalStateException("Bluetooth no disponible o apagado")
                startBleScan(scanner)
                scanPausedForCompletedRoster = false
            }
        } catch (error: Exception) {
            confirmationPayloads = previousPayloads
            targetUuids = previousTargets
            throw error
        }
        return true
    }

    @SuppressLint("MissingPermission")
    private fun startScanning(payloads: Map<String, String>) {
        if (!isActivityInForeground) {
            throw IllegalStateException("La detección BLE solo está disponible con la app en primer plano")
        }
        ensureRuntimePermissions()
        stopScanning()
        confirmationPayloads = payloads
        targetUuids = payloads.keys
        handledUuids.clear()
        inFlightUuids.clear()

        val scanner = readyBluetoothLeScanner()
            ?: throw IllegalStateException("Bluetooth no disponible o apagado")
        scanAttempt = 1
        startBleScan(scanner)
        Log.i(TAG, "Student BLE scan attempt 1/$MAX_SCAN_ATTEMPTS started for ${targetUuids.size} UUID(s)")
    }

    @SuppressLint("MissingPermission")
    private fun startBleScan(scanner: android.bluetooth.le.BluetoothLeScanner) {
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setReportDelay(0L)
            .build()
        isScanning = true
        try {
            // Do not allocate a controller-side ScanFilter here. Some Samsung
            // devices exhaust their finite hardware filter slots with system
            // services and silently leave this app's filter blocked, producing
            // zero callbacks even while the radio is receiving advertisements.
            // Scan broadly and apply the same service UUID check in-process.
            scanner.startScan(null, settings, scanCallback)
        } catch (error: Exception) {
            isScanning = false
            throw error
        }
        mainHandler.removeCallbacks(scanTimeout)
        mainHandler.postDelayed(scanTimeout, SCAN_WINDOW_MS)
    }

    private fun isStudentAttendanceCandidate(result: ScanResult): Boolean {
        return result.scanRecord
            ?.serviceUuids
            ?.any { advertisedUuid -> advertisedUuid.uuid == SERVICE_UUID }
            ?: false
    }

    @SuppressLint("MissingPermission")
    private fun stopScanning() {
        scanGeneration++
        scanAttempt = 0
        scanPausedForCompletedRoster = false
        stopCurrentScanAndConnections()
    }

    @SuppressLint("MissingPermission")
    private fun stopCurrentScanAndConnections() {
        isScanning = false
        mainHandler.removeCallbacks(scanTimeout)
        try {
            bluetoothAdapter?.bluetoothLeScanner?.stopScan(scanCallback)
        } catch (error: Exception) {
            Log.w(TAG, "Error stopping scan: ${error.message}")
        }
        activeGatts.values.forEach { gatt ->
            try {
                gatt.disconnect()
                gatt.close()
            } catch (_: Exception) {
            }
        }
        connectionTimeouts.values.forEach(mainHandler::removeCallbacks)
        connectionTimeouts.clear()
        activeGatts.clear()
        pendingDetections.clear()
        pendingAddressByUuid.clear()
        mtuByAddress.clear()
        inFlightUuids.clear()
    }

    @SuppressLint("MissingPermission")
    private fun restartScanAfterTimeout() {
        val generation = scanGeneration
        val nextAttempt = scanAttempt + 1
        Log.i(
            TAG,
            "Student BLE scan attempt $scanAttempt/$MAX_SCAN_ATTEMPTS timed out; restarting once",
        )
        stopCurrentScanAndConnections()

        mainHandler.postDelayed({
            if (generation != scanGeneration || !isActivityInForeground) {
                return@postDelayed
            }
            val scanner = readyBluetoothLeScanner()
            if (scanner == null) {
                stopScanning()
                eventSink?.error(
                    "BLUETOOTH_OFF",
                    "Bluetooth se apagó durante el reintento del escaneo",
                    null,
                )
                return@postDelayed
            }
            scanAttempt = nextAttempt
            try {
                startBleScan(scanner)
                Log.i(TAG, "Student BLE scan attempt $scanAttempt/$MAX_SCAN_ATTEMPTS started")
            } catch (error: Exception) {
                Log.e(TAG, "Could not restart student BLE scan", error)
                stopScanning()
                eventSink?.error(
                    "SCAN_FAILED",
                    "No se pudo reiniciar el escaneo Bluetooth",
                    null,
                )
            }
        }, SCAN_RESTART_DELAY_MS)
    }

    @SuppressLint("MissingPermission")
    private fun connectToCandidate(result: ScanResult) {
        if (!isActivityInForeground || !isScanning) return
        if (!hasConnectPermission()) {
            stopScanning()
            return
        }

        val device = result.device ?: return
        val address = device.address ?: return
        if (activeGatts.containsKey(address)) return
        // Android devices have a small BLE connection budget. Advertisements
        // continue arriving, so remaining students are picked up as slots free.
        if (activeGatts.size >= MAX_CONCURRENT_GATT_CONNECTIONS) return

        @SuppressLint("MissingPermission")
        val callback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                if (!isActivityInForeground || !hasConnectPermission()) {
                    closeGatt(address, gatt)
                    return
                }
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    Log.w(TAG, "Connection failed for $address with status=$status")
                    closeGatt(address, gatt)
                    return
                }
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    Log.i(TAG, "Connected to student candidate $address; requesting MTU")
                    mtuByAddress[address] = 23
                    if (!gatt.requestMtu(REQUESTED_MTU) && !gatt.discoverServices()) {
                        Log.w(TAG, "Could not start service discovery for $address")
                        closeGatt(address, gatt)
                    }
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    closeGatt(address, gatt)
                }
            }

            override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
                if (!hasConnectPermission()) {
                    closeGatt(address, gatt)
                    return
                }
                mtuByAddress[address] = if (status == BluetoothGatt.GATT_SUCCESS) mtu else 23
                if (!gatt.discoverServices()) {
                    Log.w(TAG, "Could not start service discovery after MTU negotiation for $address")
                    closeGatt(address, gatt)
                }
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                if (!isActivityInForeground || !hasConnectPermission()) {
                    closeGatt(address, gatt)
                    return
                }
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    Log.w(TAG, "Service discovery failed for $address with status=$status")
                    closeGatt(address, gatt)
                    return
                }
                val characteristic = gatt
                    .getService(SERVICE_UUID)
                    ?.getCharacteristic(ATTENDANCE_UUID_CHAR)
                if (characteristic == null) {
                    Log.w(TAG, "Attendance characteristic not found for $address")
                    closeGatt(address, gatt)
                    return
                }
                if (!gatt.readCharacteristic(characteristic)) {
                    Log.w(TAG, "Could not start attendance UUID read for $address")
                    closeGatt(address, gatt)
                }
            }

            @Suppress("DEPRECATION")
            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                val value = characteristic.value
                handleAttendanceUuid(gatt, address, result.rssi, value, status)
            }

            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
                status: Int,
            ) {
                handleAttendanceUuid(gatt, address, result.rssi, value, status)
            }

            override fun onCharacteristicWrite(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                if (!isActivityInForeground || !hasConnectPermission()) {
                    closeGatt(address, gatt)
                    return
                }
                if (characteristic.uuid == CONFIRMATION_CHAR &&
                    status == BluetoothGatt.GATT_SUCCESS) {
                    completeConfirmation(address)
                } else {
                    Log.w(
                        TAG,
                        "Attendance confirmation failed for $address with status=$status",
                    )
                }
                mainHandler.postDelayed({ closeGatt(address, gatt) }, 650)
            }
        }

        val gatt = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                device.connectGatt(
                    context,
                    false,
                    callback,
                    BluetoothDevice.TRANSPORT_LE,
                    BluetoothDevice.PHY_LE_1M_MASK,
                    mainHandler,
                )
            } else {
                device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
            }
        } catch (error: Exception) {
            Log.w(TAG, "Could not connect to student candidate $address: ${error.message}")
            return
        }
        activeGatts[address] = gatt
        scheduleConnectionTimeout(address, gatt)
    }

    @Suppress("DEPRECATION")
    private fun handleAttendanceUuid(
        gatt: BluetoothGatt,
        address: String,
        rssi: Int,
        value: ByteArray?,
        status: Int = BluetoothGatt.GATT_SUCCESS,
    ) {
        if (!isActivityInForeground) {
            closeGatt(address, gatt)
            return
        }
        if (status != BluetoothGatt.GATT_SUCCESS || value == null) {
            Log.w(TAG, "Attendance UUID read failed for $address status=$status valueIsNull=${value == null}")
            closeGatt(address, gatt)
            return
        }
        val uuid = value.toString(Charset.forName("UTF-8")).trim()
        val normalized = normalizeUuid(uuid)
        if (normalized.isEmpty() ||
            !targetUuids.contains(normalized) ||
            handledUuids.contains(normalized) ||
            !inFlightUuids.add(normalized)) {
            Log.i(TAG, "Ignoring non-target student UUID from $address: $uuid")
            closeGatt(address, gatt)
            return
        }

        Log.i(TAG, "Matched student UUID from $address: $uuid")

        val confirmation = gatt.getService(SERVICE_UUID)?.getCharacteristic(CONFIRMATION_CHAR)
        if (confirmation == null) {
            Log.w(TAG, "Confirmation characteristic not found for $address")
            inFlightUuids.remove(normalized)
            closeGatt(address, gatt)
            return
        }
        val confirmationPayload = confirmationPayloads[normalized]
        if (confirmationPayload == null) {
            Log.w(TAG, "No confirmation payload for matched UUID $normalized")
            inFlightUuids.remove(normalized)
            closeGatt(address, gatt)
            return
        }
        val confirmationBytes = confirmationPayload.toByteArray(Charsets.UTF_8)
        val maximumPayloadSize = (mtuByAddress[address] ?: 23) - 3
        if (confirmationBytes.size > maximumPayloadSize) {
            Log.w(
                TAG,
                "Student confirmation is too large for $address: ${confirmationBytes.size}/$maximumPayloadSize bytes",
            )
            inFlightUuids.remove(normalized)
            closeGatt(address, gatt)
            return
        }
        pendingDetections[address] = PendingDetection(
            uuid = uuid,
            bluetoothAddress = address,
            rssi = rssi,
            normalizedUuid = normalized,
        )
        cancelConnectionTimeout(address)
        pendingAddressByUuid[normalized] = address
        emitDetectionForTeacher(pendingDetections.getValue(address))
        mainHandler.postDelayed({
            if (pendingAddressByUuid[normalized] == address) {
                Log.w(TAG, "Teacher app did not acknowledge $normalized before timeout")
                closeGatt(address, gatt)
            }
        }, TEACHER_ACK_TIMEOUT_MS)
    }

    @Suppress("DEPRECATION")
    @SuppressLint("MissingPermission")
    private fun confirmAttendance(normalizedUuid: String): Boolean {
        val address = pendingAddressByUuid[normalizedUuid] ?: return false
        val detection = pendingDetections[address]
        val gatt = activeGatts[address]
        if (detection == null || gatt == null || detection.normalizedUuid != normalizedUuid) {
            return false
        }
        if (!hasConnectPermission()) {
            closeGatt(address, gatt)
            return false
        }

        val confirmation = gatt.getService(SERVICE_UUID)?.getCharacteristic(CONFIRMATION_CHAR)
            ?: run {
                closeGatt(address, gatt)
                return false
            }
        val payload = confirmationPayloads[normalizedUuid]
            ?: run {
                closeGatt(address, gatt)
                return false
            }
        val bytes = payload.toByteArray(Charsets.UTF_8)
        val maximumPayloadSize = (mtuByAddress[address] ?: 23) - 3
        if (bytes.size > maximumPayloadSize) {
            Log.w(TAG, "Student confirmation is too large for $address: ${bytes.size}/$maximumPayloadSize bytes")
            closeGatt(address, gatt)
            return false
        }

        val writeStarted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeCharacteristic(
                confirmation,
                bytes,
                BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
            ) == BluetoothStatusCodes.SUCCESS
        } else {
            confirmation.value = bytes
            gatt.writeCharacteristic(confirmation)
        }
        if (!writeStarted) {
            Log.w(TAG, "Could not write teacher-approved confirmation to $address")
            closeGatt(address, gatt)
            return false
        }
        return true
    }

    private fun emitDetectionForTeacher(detection: PendingDetection) {
        mainHandler.post {
            if (isActivityInForeground) {
                eventSink?.success(
                    listOf(
                        mapOf(
                            "uuid" to detection.uuid,
                            "bluetoothAddress" to detection.bluetoothAddress,
                            "rssi" to detection.rssi,
                        )
                    )
                )
            }
        }
    }

    private fun completeConfirmation(address: String) {
        val detection = pendingDetections.remove(address) ?: return
        if (pendingAddressByUuid[detection.normalizedUuid] == address) {
            pendingAddressByUuid.remove(detection.normalizedUuid)
        }
        inFlightUuids.remove(detection.normalizedUuid)
        handledUuids.add(detection.normalizedUuid)
        Log.i(TAG, "Teacher-approved confirmation delivered for ${detection.normalizedUuid}")
        if (handledUuids.containsAll(targetUuids)) {
            stopBleScanOnly()
        }
    }

    @SuppressLint("MissingPermission")
    private fun closeGatt(address: String, gatt: BluetoothGatt) {
        // A late callback from an old connection must not clear a newer GATT
        // session that happens to use the same Bluetooth address.
        if (activeGatts[address] === gatt) {
            activeGatts.remove(address)
            cancelConnectionTimeout(address)
            pendingDetections.remove(address)?.let { pending ->
                if (pendingAddressByUuid[pending.normalizedUuid] == address) {
                    pendingAddressByUuid.remove(pending.normalizedUuid)
                }
                inFlightUuids.remove(pending.normalizedUuid)
            }
            mtuByAddress.remove(address)
        }
        try {
            gatt.disconnect()
            gatt.close()
        } catch (_: Exception) {
        }
    }

    private fun ensureRuntimePermissions() {
        val missing = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (!hasPermission(Manifest.permission.BLUETOOTH_SCAN)) missing.add(Manifest.permission.BLUETOOTH_SCAN)
            if (!hasPermission(Manifest.permission.BLUETOOTH_CONNECT)) missing.add(Manifest.permission.BLUETOOTH_CONNECT)
        }
        if (!hasPermission(Manifest.permission.ACCESS_FINE_LOCATION)) {
            missing.add(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        if (missing.isNotEmpty()) {
            throw SecurityException("Permisos faltantes: ${missing.joinToString()}")
        }
    }

    private fun readyBluetoothLeScanner(): android.bluetooth.le.BluetoothLeScanner? {
        val adapter = bluetoothAdapter ?: return null
        if (adapter.state != BluetoothAdapter.STATE_ON || !adapter.isEnabled) return null
        return adapter.bluetoothLeScanner
    }

    private fun scheduleConnectionTimeout(address: String, gatt: BluetoothGatt) {
        cancelConnectionTimeout(address)
        val timeout = Runnable {
            if (activeGatts[address] === gatt && !pendingDetections.containsKey(address)) {
                Log.w(TAG, "GATT connection timed out for $address")
                closeGatt(address, gatt)
            }
        }
        connectionTimeouts[address] = timeout
        mainHandler.postDelayed(timeout, GATT_CONNECTION_TIMEOUT_MS)
    }

    private fun cancelConnectionTimeout(address: String) {
        connectionTimeouts.remove(address)?.let(mainHandler::removeCallbacks)
    }

    @SuppressLint("MissingPermission")
    private fun stopBleScanOnly() {
        if (!isScanning) return
        scanPausedForCompletedRoster = true
        isScanning = false
        mainHandler.removeCallbacks(scanTimeout)
        try {
            bluetoothAdapter?.bluetoothLeScanner?.stopScan(scanCallback)
        } catch (error: Exception) {
            Log.w(TAG, "Error stopping completed scan: ${error.message}")
        }
        Log.i(TAG, "All target students were confirmed; BLE scan stopped")
    }

    private fun scanFailureMessage(errorCode: Int): String {
        return when (errorCode) {
            ScanCallback.SCAN_FAILED_ALREADY_STARTED -> "El escaneo Bluetooth ya estaba activo"
            ScanCallback.SCAN_FAILED_APPLICATION_REGISTRATION_FAILED ->
                "Android no pudo registrar el escáner Bluetooth; vuelve a intentarlo"
            ScanCallback.SCAN_FAILED_FEATURE_UNSUPPORTED ->
                "Este teléfono no admite el modo de escaneo requerido"
            ScanCallback.SCAN_FAILED_INTERNAL_ERROR ->
                "El sistema Bluetooth tuvo un error interno; apágalo y enciéndelo"
            else -> "No se pudo continuar el escaneo Bluetooth ($errorCode)"
        }
    }

    private fun hasPermission(permission: String): Boolean {
        return ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
    }

    private fun hasConnectPermission(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            hasPermission(Manifest.permission.BLUETOOTH_CONNECT)
    }

    private fun normalizeUuid(uuid: String?): String {
        return uuid?.replace("-", "")?.lowercase()?.trim().orEmpty()
    }

    private fun getBluetoothState(): String {
        return try {
            when {
                bluetoothAdapter == null -> "unsupported"
                bluetoothAdapter?.isEnabled == true -> "poweredOn"
                else -> "poweredOff"
            }
        } catch (_: SecurityException) {
            "unauthorized"
        }
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

    private fun openSettings(action: String): Boolean {
        return try {
            activity.startActivity(Intent(action))
            true
        } catch (error: Exception) {
            Log.w(TAG, "Could not open settings: ${error.message}")
            false
        }
    }
}
