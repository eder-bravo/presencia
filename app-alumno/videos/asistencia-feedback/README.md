# Video de asistencia y feedback

`asistencia-y-feedback.mp4` muestra el recorrido del alumno en la interfaz
actual: Inicio → Registrar asistencia → verificación del aula → envío al
profesor → «Se tomó correctamente la asistencia» → clase registrada → Historial.

Video vertical de 14,17 segundos, 1080 × 1920, 24 fps, H.264, sin audio. Captura
continua de widgets Flutter reales, incluyendo animaciones, contador, apertura
y cierre del panel y cambios de estado. Los toques se indican con un círculo.

Usa un alumno ficticio y eventos Bluetooth simulados, identificados dentro del
video. No registra una conexión Bluetooth física ni crea asistencias reales.

## Regenerar

Desde la raíz de `app-alumno`, con Flutter, Pillow y FFmpeg disponibles:

```bash
flutter test --no-pub --dart-define=CAPTURE_ATTENDANCE_VIDEO=true --update-goldens test/attendance_feedback_video_capture_test.dart
python3 tool/generate_attendance_feedback_video.py
```

`vista-previa.jpg` permite revisar los momentos principales. Los fotogramas
intermedios y `timeline.json` son archivos generados y se excluyen de Git.
