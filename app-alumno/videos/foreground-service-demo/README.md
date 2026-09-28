# Demostración visual de asistencia BLE

`simulacion-asistencia-connected-device.mp4` es una simulación de 25 segundos
de la interfaz actual, con datos ficticios. Los estados BLE, la confirmación y
la notificación están identificados como simulados; este archivo **no es una
grabación de una conexión Bluetooth real**.

La secuencia muestra Inicio → Registrar asistencia → verificación del aula →
transmisión BLE → representación de la notificación → confirmación → Historial.

## Regenerar

Desde la raíz de `app-alumno`:

```bash
flutter test --no-pub --dart-define=CAPTURE_FGS_DEMO=true --update-goldens test/foreground_service_demo_capture_test.dart
python3 tool/generate_foreground_service_demo.py
```

El primer comando renderiza widgets Flutter reales con servicios BLE de prueba.
El segundo compone las diapositivas y codifica un MP4 H.264 con FFmpeg. Requiere
Pillow y FFmpeg.

## Selección y texto para Play Console

Tipo: `FOREGROUND_SERVICE_CONNECTED_DEVICE`.

Caso de uso recomendado: **Continuous data transfer to an external device**.
El intercambio es breve: la app anuncia de forma continua un servicio BLE/GATT
durante la sesión de asistencia y transfiere el identificador del alumno y la
confirmación cuando se conecta el dispositivo del profesor. No corresponde a
`Automotive key`.

Texto sugerido para «Describe permission use» (en inglés):

> When a student explicitly taps “Registrar asistencia,” the app verifies the
> classroom beacon if one is configured, then immediately starts a short-lived connectedDevice
> foreground service. The student's phone advertises a BLE GATT service so the
> teacher's device can connect, read the attendance identifier, and write the
> confirmation. An ongoing notification shows that attendance sharing is
> active. The exchange must start immediately because the teacher's roll-call
> window is brief; delaying it can cause the student's phone to miss the scan.
> Pausing or restarting during the GATT exchange would break the connection and
> could lose that confirmation. The service stops after confirmation,
> cancellation, or the 30-second timeout. It is not started automatically.

Para el campo «Video link» de Play Console, Google solicita un enlace accesible
al video de la función. Se prefiere YouTube y también se admite un enlace a un
MP4 en almacenamiento en la nube. Este MP4 local todavía no tiene una URL
pública. La prueba final debe grabarse en Android físico, con el Bluetooth LE y
el dispositivo del profesor funcionando, y mostrar el paso que inicia el
servicio, la notificación activa, la confirmación y el historial.
