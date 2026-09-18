# Implementacion de Beacons para Asistencia

Documento de referencia de los cambios realizados en la app de profesores y el backend para el flujo de asistencia por beacons.

## Flujo General

1. La app de profesores abre la pantalla de clases sin iniciar ningun escaneo del salon.
2. El profesor entra al detalle de la clase y pulsa `Marcar Entrada`.
3. Solo entonces la app busca el beacon configurado para ese salon.
4. Si lo detecta, registra la entrada del profesor con hora exacta.
5. La deteccion de alumnos tambien se inicia y se detiene mediante su boton dedicado.

La sincronizacion de clases nunca inicia la deteccion del beacon ni crea entradas
del profesor. Las asistencias locales existentes se conservan durante ese proceso.

## App de Profesores

### Android

- Se agrego integracion nativa con Android Beacon Library/AltBeacon.
- Archivo principal: `android/app/src/main/kotlin/com/presencia/app_profesor/AltBeaconPlugin.kt`
- Canales usados:
  - MethodChannel: `com.presencia/altbeacon`
  - EventChannel: `com.presencia/altbeacon_events`
- Formatos soportados:
  - AltBeacon
  - iBeacon
- Se declaro foreground service para escaneo:
  - `location`
  - `connectedDevice`
- Dependencia agregada:

```kotlin
implementation("org.altbeacon:android-beacon-library:2.21.2")
```

### iOS

- Se implemento escaneo nativo con CoreLocation, no AltBeacon.
- Archivo principal: `ios/Runner/IosBeaconPlugin.swift`
- Usa:
  - `CLLocationManager`
  - `CLBeaconIdentityConstraint`
  - `CLBeaconRegion`
- Canales usados, iguales a Android:
  - MethodChannel: `com.presencia/altbeacon`
  - EventChannel: `com.presencia/altbeacon_events`
- `Info.plist` incluye permisos de ubicacion y background modes:
  - `NSLocationWhenInUseUsageDescription`
  - `NSLocationAlwaysAndWhenInUseUsageDescription`
  - `NSBluetoothAlwaysUsageDescription`
  - `UIBackgroundModes`
    - `location`
    - `bluetooth-central`

### Dart

Archivos principales:

- `lib/services/native_altbeacon_channel.dart`
  - Abstrae el canal nativo.
  - Expone `AltBeaconDetection`.
  - Expone `startScanning`, `stopScanning`, `detectionsStream`.

- `lib/services/ble_beacon_verification_service.dart`
  - Usa `NativeAltBeaconChannel`.
  - Se invoca exclusivamente desde los botones `Marcar Entrada` y `Marcar Salida`.
  - No se ejecuta al abrir la app, reanudarla ni sincronizar clases.

- `lib/services/student_attendance_ble_service.dart`
  - Detecta alumnos solo al pulsar el boton dedicado en el detalle de la clase.
  - Usa exclusivamente el servicio GATT conectable expuesto por la app de alumnos.
  - No admite altas manuales ni dispositivos iBeacon externos.

- `lib/shared/models/alumno.dart`
  - Se agrego `beaconUuid`.

### Eliminado

Se removio el stack BLE legacy:

- `android/app/src/main/kotlin/com/presencia/app_profesor/NativeBlePlugin.kt`
- `ios/Runner/NativeBlePlugin.swift`
- `lib/services/native_ble_channel.dart`
- `lib/services/bluetooth_service.dart`
- `lib/services/bluetooth_attendance_service.dart`

Ya no debe usarse el canal:

```text
com.presencia/ble
com.presencia/ble_scan
```

## Backend

### Cambios en Prisma

Archivo: `prisma/schema.prisma`

#### Student

Se agrego:

```prisma
beaconUuid String? @unique @map("beacon_uuid")
```

#### AttendanceRecord

Se agregaron campos para guardar evidencia del beacon del salon:

```prisma
professorEntryAt   DateTime? @map("professor_entry_at")
professorExitAt    DateTime? @map("professor_exit_at")
roomBeaconUuid     String?   @map("room_beacon_uuid")
roomBeaconRssi     Int?      @map("room_beacon_rssi")
roomBeaconDistance Float?    @map("room_beacon_distance")
roomBeaconAddress  String?   @map("room_beacon_address")
```

#### StudentBeaconDetection

Nueva tabla:

```prisma
model StudentBeaconDetection {
  id                 String           @id @default(cuid())
  studentId          String           @map("student_id")
  attendanceRecordId String           @map("attendance_record_id")
  beaconUuid         String           @map("beacon_uuid")
  detectedAt         DateTime         @map("detected_at")
  rssi               Int?
  distance           Float?
  txPower            Int?             @map("tx_power")
  bluetoothAddress   String?          @map("bluetooth_address")
  createdAt          DateTime         @default(now()) @map("created_at")

  @@unique([studentId, attendanceRecordId])
  @@index([beaconUuid])
  @@map("student_beacon_detections")
}
```

Migracion creada:

```text
prisma/migrations/20260701120000_add_beacon_attendance_flow/migration.sql
```

### Asignacion de UUIDs a Alumnos

- Al sincronizar alumnos desde scraper, el backend asigna `beaconUuid` con `randomUUID()`.
- Al consultar `/professors/classes`, si un alumno antiguo no tiene `beaconUuid`, se genera y guarda automaticamente.
- El endpoint `/professors/classes` ahora devuelve `beaconUuid` dentro de cada alumno.

## Endpoints

### GET `/professors/classes`

Devuelve clases del profesor autenticado, beacons de salones y alumnos con `beaconUuid`.

#### Headers

```http
Authorization: Bearer <token>
```

#### Respuesta relevante

```json
{
  "data": [
    {
      "id": "group_cuid",
      "code": "RC.06061.2873.5",
      "groupLetter": "M",
      "period": "2026-1",
      "classroom": "Aula 101",
      "students": [
        {
          "id": "student_cuid",
          "matricula": "123456",
          "beaconUuid": "550e8400-e29b-41d4-a716-446655440000",
          "name": "Alumno Ejemplo",
          "number": 1
        }
      ]
    }
  ],
  "beacons": [
    {
      "id": "beacon_cuid",
      "uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
      "classroom": "Aula 101"
    }
  ],
  "syncInProgress": false
}
```

### POST `/attendance/professor-entry`

Registra entrada del profesor cuando la app detecta el beacon del salon.

#### Headers

```http
Authorization: Bearer <token>
Content-Type: application/json
```

#### Body

```json
{
  "code": "RC.06061.2873.5",
  "groupLetter": "M",
  "period": "2026-1",
  "date": "2026-07-01",
  "detectedAt": "2026-07-01T10:05:23.000",
  "beaconUuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
  "rssi": -61,
  "distance": 1.42,
  "bluetoothAddress": "AA:BB:CC:DD:EE:FF"
}
```

#### Respuesta

```json
{
  "data": {
    "attendanceRecordId": "attendance_record_cuid",
    "groupId": "group_cuid",
    "date": "2026-07-01",
    "professorEntryAt": "2026-07-01T10:05:23.000Z"
  },
  "message": "Entrada del profesor registrada por beacon"
}
```

#### Validaciones

- El grupo se resuelve por:
  - `code`
  - `groupLetter`
  - `period`
  - profesor autenticado
- Si existe beacon configurado para el salon, el backend valida que `beaconUuid` coincida.

### POST `/attendance/student-beacon-detections`

Procesa detecciones de beacons de alumnos y los marca como presentes.

#### Headers

```http
Authorization: Bearer <token>
Content-Type: application/json
```

#### Body

```json
{
  "code": "RC.06061.2873.5",
  "groupLetter": "M",
  "period": "2026-1",
  "date": "2026-07-01",
  "detections": [
    {
      "beaconUuid": "550e8400-e29b-41d4-a716-446655440000",
      "detectedAt": "2026-07-01T10:08:10.000",
      "rssi": -70,
      "distance": 2.4,
      "txPower": -59,
      "bluetoothAddress": "AA:BB:CC:DD:EE:FF",
      "major": 1,
      "minor": 25
    }
  ]
}
```

#### Respuesta

```json
{
  "data": {
    "attendanceRecordId": "attendance_record_cuid",
    "matchedCount": 1,
    "matched": [
      {
        "studentId": "student_cuid",
        "beaconUuid": "550e8400-e29b-41d4-a716-446655440000",
        "detectedAt": "2026-07-01T10:08:10.000"
      }
    ]
  },
  "message": "Detecciones de alumnos procesadas"
}
```

#### Efectos

- Crea o reutiliza el `AttendanceRecord` del grupo y fecha.
- Busca alumnos del grupo por `beaconUuid`.
- Marca cada alumno encontrado como `PRESENT`.
- Guarda evidencia en `student_beacon_detections`.
- Es idempotente por alumno y registro de asistencia:

```text
studentId + attendanceRecordId
```

## Endpoints Existentes Relacionados

### GET `/beacons`

Lista beacons de salones.

### POST `/beacons`

Crea beacon de salon.

```json
{
  "uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
  "classroom": "Aula 101"
}
```

### PUT `/beacons/:id`

Actualiza beacon de salon.

### DELETE `/beacons/:id`

Elimina beacon de salon.

## Notas de Operacion

- El beacon del salon usa AltBeacon nativo en Android y CoreLocation en iOS.
- Flutter consume ese flujo de aula con el canal `NativeAltBeaconChannel`.
- La asistencia de alumnos usa solamente GATT entre la app del alumno y la app del profesor.
- iOS requiere dispositivo fisico para validar tanto Bluetooth GATT como el beacon del salon.
- Para iOS en segundo plano se requiere habilitar Background Modes en Xcode:
  - Location updates
  - Uses Bluetooth LE accessories

## Datos de Validacion Manual

Profesor para probar el flujo:

```text
Codigo: JD-06
Email: constantino.jared.1amp@gmail.com
```

Este profesor debe iniciar sesion, abrir la pantalla de clases y cargar `/professors/classes`.
Con eso la app obtiene los salones, los beacons de salon y los `beaconUuid` de alumnos necesarios para el escaneo.

## Validaciones Realizadas

- `flutter build apk --debug` paso.
- `dart analyze` dirigido a archivos modificados paso.
- `npm run typecheck` en backend paso.
- `xmllint --noout ios/Runner/Info.plist` paso.

No se valido build iOS porque el entorno actual no tiene `xcodebuild`.
