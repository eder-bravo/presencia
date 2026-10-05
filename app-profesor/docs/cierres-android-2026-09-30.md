# Cierres de Android: diagnóstico y corrección

## Evidencia

Se revisaron `app.log`, `salidas-proceso.txt` y `sistema-app.log` de
`/tmp/presencia-logs-2026-09-30` como datos de diagnóstico.

- El historial registra 10 cierres por ANR, cuatro por quitar la tarea y dos
  por exceso de procesos en caché. Los ANR indican esperas de unos cinco
  segundos para atender eventos de toque o foco.
- El 30 de septiembre a las 12:02:31, Android registra un ANR al volver a la
  actividad. Después mata el proceso al elegir cerrar la aplicación.
- A las 12:06:37 se inicia Impeller con Vulkan. El controlador Mali/MediaTek
  reporta formatos/uso de buffers no soportados. La pantalla cancela dibujos
  esperando el primer frame y a las 12:06:43 el sistema detecta un timeout de
  visualización y solicita un volcado nativo.
- Los archivos adjuntos no contienen las pilas del volcado ni las trazas ANR
  referenciadas en el historial. Por tanto, confirman la falta de respuesta;
  la ruta gráfica es una causa probable que requiere validación en el equipo.
  Los errores de formatos gráficos, por sí solos, no prueban un bloqueo.

## Cambio

`android/app/src/main/AndroidManifest.xml` desactiva Impeller en la aplicación,
incluyendo release, mediante `io.flutter.embedding.android.EnableImpeller=false`.
Flutter utiliza así Skia/OpenGL en Android. Es la opción descrita en la
[documentación oficial de Flutter](https://docs.flutter.dev/perf/impeller#android).
El cambio evita la ruta Vulkan sospechosa durante el arranque y al recrear
la superficie al volver del segundo plano. Mantiene la aceleración por GPU.

Se corrigieron también dos comprobaciones de `app_log_identity_test.dart`:
Hive ordena las claves UUID, por lo que `queue.values.last` no identifica
necesariamente el evento más reciente. Las pruebas buscan ahora el evento
esperado y comprueban su secuencia, manteniendo la verificación contra logs
recursivos y pérdida de eventos.

## Verificación

- `flutter test --no-pub --reporter expanded`: 111 pruebas aprobadas y seis
  pruebas de capturas omitidas por su configuración habitual.
- `dart analyze lib`: sin incidencias. El análisis global informa siete
  advertencias/info preexistentes en scripts de auditoría y pruebas de capturas.
- Release 1.0.2+3 compilada mediante `tool/build_release.py`, con la configuración
  local de ingesta existente. La versión se pasó mediante argumentos; no se
  cambió la versión predeterminada de `pubspec.yaml`.
- Se inspeccionaron los manifiestos empaquetados del APK y del AAB con `aapt2`
  (conversión temporal de los recursos protobuf del módulo base del AAB):
  versión 1.0.2, código 3 y `EnableImpeller=false` en ambos.
  `apksigner verify` confirmó la firma válida del APK y el mismo certificado
  que el APK release local anterior.
- Los hashes y resultados están en
  [cierres-android-verificacion-2026-09-30.json](cierres-android-verificacion-2026-09-30.json).

No había dispositivos conectados en `adb devices -l`. Para confirmar la
corrección en el equipo afectado, probar arranques en frío, navegación, escaneo
de alumnos y varias salidas/regresos del segundo plano con la nueva versión.
Si persiste un ANR, capturar un `adb bugreport` después del fallo para obtener
las pilas del hilo principal y del renderizador; los tres logs originales no
incluyen esas pilas. La nueva versión todavía no se ha publicado ni instalado.
