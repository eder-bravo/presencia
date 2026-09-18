import CoreBluetooth
import Flutter
import UIKit

final class StudentAttendanceBlePlugin: NSObject, FlutterStreamHandler, CBCentralManagerDelegate, CBPeripheralDelegate {
  private let methodChannelName = "com.presencia/student_attendance_ble"
  private let eventChannelName = "com.presencia/student_attendance_ble_events"
  private let serviceUuid = CBUUID(string: "9f5f7f86-8e67-4f12-a8a5-b7f6f4f7b2c1")
  private let attendanceUuidCharacteristicUuid = CBUUID(string: "9f5f7f86-8e67-4f12-a8a5-b7f6f4f7b2c2")
  private let confirmationCharacteristicUuid = CBUUID(string: "9f5f7f86-8e67-4f12-a8a5-b7f6f4f7b2c3")
  private let maxConcurrentConnections = 6

  private var centralManager: CBCentralManager?
  private var eventSink: FlutterEventSink?
  private var targetUuids: Set<String> = []
  private var confirmationPayloads: [String: Data] = [:]
  private var handledUuids: Set<String> = []
  private var inFlightUuids: Set<String> = []
  private var peripherals: [UUID: CBPeripheral] = [:]
  private var rssiByPeripheral: [UUID: NSNumber] = [:]
  private var pendingDetections: [UUID: [String: Any]] = [:]
  private var pendingUuidByPeripheral: [UUID: String] = [:]
  private var teacherAckTimeouts: [String: DispatchWorkItem] = [:]
  private var pendingStartResult: FlutterResult?
  private var pendingBluetoothStateResults: [FlutterResult] = []
  private var pendingBluetoothPermissionResults: [FlutterResult] = []

  func register(with messenger: FlutterBinaryMessenger) {
    let methodChannel = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "UNAVAILABLE", message: "BLE no disponible", details: nil))
        return
      }
      DispatchQueue.main.async {
        self.handle(call, result: result)
      }
    }

    let eventChannel = FlutterEventChannel(name: eventChannelName, binaryMessenger: messenger)
    eventChannel.setStreamHandler(self)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startScanning", "updateBindings":
      guard let args = call.arguments as? [String: Any],
            let rawPayloads = args["confirmationPayloads"] as? [String: Any]
      else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Se requieren confirmaciones por matricula", details: nil))
        return
      }
      let payloads = rawPayloads.reduce(into: [String: Data]()) { values, entry in
        let normalized = normalizeUuid(entry.key)
        if !normalized.isEmpty,
           let payload = entry.value as? String,
           let data = payload.data(using: .utf8),
           !data.isEmpty {
          values[normalized] = data
        }
      }
      guard !payloads.isEmpty || call.method == "updateBindings" else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Las confirmaciones por matricula son invalidas", details: nil))
        return
      }
      if call.method == "updateBindings" {
        guard centralManager?.isScanning == true else {
          result(false)
          return
        }
        // Keep the active connections and already confirmed students intact.
        targetUuids = Set(payloads.keys)
        confirmationPayloads = payloads
        result(true)
      } else {
        startScanning(confirmationPayloads: payloads, result: result)
      }

    case "stopScanning":
      stopScanning()
      result(true)

    case "confirmAttendance":
      guard let args = call.arguments as? [String: Any],
            let rawUuid = args["uuid"] as? String
      else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Se requiere el UUID del alumno", details: nil))
        return
      }
      let normalized = normalizeUuid(rawUuid)
      guard !normalized.isEmpty else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "UUID de alumno inválido", details: nil))
        return
      }
      result(confirmAttendance(normalizedUuid: normalized))

    case "checkBluetoothState":
      checkBluetoothState(result: result)

    case "checkBluetoothPermission":
      result(bluetoothAuthorizationName())

    case "requestBluetoothPermission":
      requestBluetoothPermission(result: result)

    case "openBluetoothSettings", "openLocationSettings":
      guard let url = URL(string: UIApplication.openSettingsURLString) else {
        result(false)
        return
      }
      UIApplication.shared.open(url, options: [:]) { opened in
        result(opened)
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startScanning(
    confirmationPayloads: [String: Data],
    result: @escaping FlutterResult
  ) {
    targetUuids = Set(confirmationPayloads.keys)
    self.confirmationPayloads = confirmationPayloads
    handledUuids.removeAll()
    inFlightUuids.removeAll()
    pendingDetections.removeAll()
    pendingUuidByPeripheral.removeAll()
    teacherAckTimeouts.values.forEach { $0.cancel() }
    teacherAckTimeouts.removeAll()
    guard !targetUuids.isEmpty else {
      result(FlutterError(code: "INVALID_UUID", message: "UUIDs invalidos", details: nil))
      return
    }

    let manager = ensureCentralManager()

    if manager.state != .poweredOn {
      if manager.state == .unknown || manager.state == .resetting {
        pendingStartResult = result
      } else {
        result(FlutterError(code: "BLUETOOTH_OFF", message: "Bluetooth no disponible", details: nil))
      }
      return
    }

    manager.scanForPeripherals(
      withServices: [serviceUuid],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
    )
    result(true)
  }

  private func stopScanning() {
    centralManager?.stopScan()
    for peripheral in peripherals.values {
      centralManager?.cancelPeripheralConnection(peripheral)
    }
    peripherals.removeAll()
    rssiByPeripheral.removeAll()
    pendingDetections.removeAll()
    pendingUuidByPeripheral.removeAll()
    teacherAckTimeouts.values.forEach { $0.cancel() }
    teacherAckTimeouts.removeAll()
    inFlightUuids.removeAll()
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if bluetoothAuthorizationName() != "notDetermined" &&
       !pendingBluetoothPermissionResults.isEmpty {
      let results = pendingBluetoothPermissionResults
      pendingBluetoothPermissionResults.removeAll()
      let permission = bluetoothAuthorizationName()
      results.forEach { $0(permission) }
    }

    if !pendingBluetoothStateResults.isEmpty {
      let state = bluetoothStateName(central.state)
      let results = pendingBluetoothStateResults
      pendingBluetoothStateResults.removeAll()
      results.forEach { $0(state) }
    }

    guard let result = pendingStartResult else { return }
    pendingStartResult = nil
    if central.state == .poweredOn {
      central.scanForPeripherals(
        withServices: [serviceUuid],
        options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
      )
      result(true)
    } else {
      result(FlutterError(code: "BLUETOOTH_OFF", message: "Bluetooth no disponible", details: nil))
    }
  }

  private func ensureCentralManager() -> CBCentralManager {
    if let manager = centralManager { return manager }
    let manager = CBCentralManager(delegate: self, queue: nil)
    centralManager = manager
    return manager
  }

  private func checkBluetoothState(result: @escaping FlutterResult) {
    let manager = ensureCentralManager()
    if manager.state == .unknown || manager.state == .resetting {
      pendingBluetoothStateResults.append(result)
      return
    }
    result(bluetoothStateName(manager.state))
  }

  private func bluetoothStateName(_ state: CBManagerState) -> String {
    switch state {
    case .poweredOn: return "poweredOn"
    case .poweredOff: return "poweredOff"
    case .unauthorized: return "unauthorized"
    case .unsupported: return "unsupported"
    default: return "unknown"
    }
  }

  private func bluetoothAuthorizationName() -> String {
    switch CBManager.authorization {
    case .allowedAlways: return "granted"
    case .notDetermined: return "notDetermined"
    case .denied: return "denied"
    case .restricted: return "restricted"
    @unknown default: return "unknown"
    }
  }

  private func requestBluetoothPermission(result: @escaping FlutterResult) {
    let status = bluetoothAuthorizationName()
    guard status == "notDetermined" else {
      result(status)
      return
    }
    pendingBluetoothPermissionResults.append(result)
    _ = ensureCentralManager()
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    if peripherals[peripheral.identifier] != nil { return }
    // Keep scanning the whole roster while processing a safe number of GATT
    // connections at once; duplicate advertisements fill slots as they free.
    if peripherals.count >= maxConcurrentConnections { return }
    peripherals[peripheral.identifier] = peripheral
    rssiByPeripheral[peripheral.identifier] = RSSI
    peripheral.delegate = self
    central.connect(peripheral, options: nil)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    peripheral.discoverServices([serviceUuid])
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let service = peripheral.services?.first(where: { $0.uuid == serviceUuid }) else {
      centralManager?.cancelPeripheralConnection(peripheral)
      return
    }
    peripheral.discoverCharacteristics(
      [attendanceUuidCharacteristicUuid, confirmationCharacteristicUuid],
      for: service
    )
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard let characteristic = service.characteristics?.first(where: { $0.uuid == attendanceUuidCharacteristicUuid }) else {
      centralManager?.cancelPeripheralConnection(peripheral)
      return
    }
    peripheral.readValue(for: characteristic)
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard error == nil,
          characteristic.uuid == attendanceUuidCharacteristicUuid,
          let value = characteristic.value,
          let uuid = String(data: value, encoding: .utf8)
    else {
      centralManager?.cancelPeripheralConnection(peripheral)
      return
    }

    let normalized = normalizeUuid(uuid)
    guard targetUuids.contains(normalized),
          !handledUuids.contains(normalized),
          !inFlightUuids.contains(normalized)
    else {
      centralManager?.cancelPeripheralConnection(peripheral)
      return
    }
    inFlightUuids.insert(normalized)

    if let service = peripheral.services?.first(where: { $0.uuid == serviceUuid }),
       service.characteristics?.contains(where: { $0.uuid == confirmationCharacteristicUuid }) == true,
       let data = confirmationPayloads[normalized],
       data.count <= peripheral.maximumWriteValueLength(for: .withResponse) {
      var payload: [String: Any] = [
        "uuid": uuid,
        "bluetoothAddress": peripheral.identifier.uuidString,
      ]
      if let rssi = rssiByPeripheral[peripheral.identifier]?.intValue {
        payload["rssi"] = rssi
      }
      pendingDetections[peripheral.identifier] = payload
      pendingUuidByPeripheral[peripheral.identifier] = normalized
      eventSink?([payload])
      scheduleTeacherAckTimeout(for: peripheral, normalizedUuid: normalized)
    } else {
      inFlightUuids.remove(normalized)
      centralManager?.cancelPeripheralConnection(peripheral)
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didWriteValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard characteristic.uuid == confirmationCharacteristicUuid else { return }

    let normalized = pendingUuidByPeripheral.removeValue(forKey: peripheral.identifier)
    pendingDetections.removeValue(forKey: peripheral.identifier)
    if let normalized = normalized {
      teacherAckTimeouts.removeValue(forKey: normalized)?.cancel()
      inFlightUuids.remove(normalized)
      if error == nil {
        handledUuids.insert(normalized)
      }
    }
    centralManager?.cancelPeripheralConnection(peripheral)
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    cleanup(peripheral)
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    cleanup(peripheral)
  }

  private func cleanup(_ peripheral: CBPeripheral) {
    peripherals.removeValue(forKey: peripheral.identifier)
    rssiByPeripheral.removeValue(forKey: peripheral.identifier)
    pendingDetections.removeValue(forKey: peripheral.identifier)
    if let normalized = pendingUuidByPeripheral.removeValue(forKey: peripheral.identifier) {
      teacherAckTimeouts.removeValue(forKey: normalized)?.cancel()
      inFlightUuids.remove(normalized)
    }
  }

  private func confirmAttendance(normalizedUuid: String) -> Bool {
    guard let pending = pendingUuidByPeripheral.first(where: { $0.value == normalizedUuid }),
          let peripheral = peripherals[pending.key],
          let service = peripheral.services?.first(where: { $0.uuid == serviceUuid }),
          let confirmation = service.characteristics?.first(where: { $0.uuid == confirmationCharacteristicUuid }),
          let data = confirmationPayloads[normalizedUuid],
          data.count <= peripheral.maximumWriteValueLength(for: .withResponse)
    else {
      return false
    }

    peripheral.writeValue(data, for: confirmation, type: .withResponse)
    return true
  }

  private func scheduleTeacherAckTimeout(for peripheral: CBPeripheral, normalizedUuid: String) {
    teacherAckTimeouts.removeValue(forKey: normalizedUuid)?.cancel()
    let peripheralId = peripheral.identifier
    let timeout = DispatchWorkItem { [weak self] in
      guard let self = self,
            self.pendingUuidByPeripheral[peripheralId] == normalizedUuid
      else {
        return
      }
      self.centralManager?.cancelPeripheralConnection(peripheral)
    }
    teacherAckTimeouts[normalizedUuid] = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
  }

  private func normalizeUuid(_ uuid: String) -> String {
    uuid.replacingOccurrences(of: "-", with: "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
