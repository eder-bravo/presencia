# Video del funcionamiento de asistencia

`funcionamiento-asistencia-vertical.mp4` muestra las pantallas de la app
de profesores en formato vertical 1080 × 1920, sin audio ni textos añadidos.

Recorrido: clases y grupos, Mi asistencia, verificación del salón y entrada,
pase de lista manual, escaneo Bluetooth de alumnos, revisión de los alumnos
detectados, salida del profesor, envío de la lista y calendario de asistencias.

Las vistas y las interacciones pertenecen a los widgets actuales de Flutter.
Se usa una lista ficticia y almacenamiento temporal aislado. Las detecciones
Bluetooth y las respuestas del servidor se simulan para la demostración.

Para regenerarlo desde la raíz de `app-profesor`:

```bash
TZ=America/Mexico_City flutter test --no-pub \
  --dart-define=CAPTURE_ATTENDANCE_VIDEO=true \
  tool/video/capture_attendance_test.dart
python3 tool/video/render_attendance.py
```

Requiere el SDK Flutter con las dependencias del proyecto y FFmpeg.
Las capturas y el recorrido temporal se guardan en `build/attendance_video/`.
