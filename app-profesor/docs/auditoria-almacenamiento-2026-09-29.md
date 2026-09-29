# Auditoría de almacenamiento de la app de profesores

Fecha: 29 de septiembre de 2026. Alcance: crecimiento del almacenamiento en el teléfono, persistencia local, cachés y mecanismos de limpieza del código disponible en este proyecto.

**Hallazgo inicial, antes del arreglo:** existía un ciclo de generación de logs que se mantenía por sí mismo cuando había un profesor almacenado. La cola de logs no tiene límite de bytes, cantidad o antigüedad y solo borra eventos confirmados por el servidor. Esa combinación permitía crecimiento continuo del almacenamiento sin interacción del profesor cuando la entrega fallaba o no alcanzaba el ritmo de producción.

**Estado actual:** el ciclo fue corregido y se recompilaron APK y AAB con la clave correcta. La prueba con el transporte real de Flutter confirmó que una confirmación del servidor elimina la copia local. Los apartados 1–8 documentan la investigación anterior al arreglo; la sección 9 describe los cambios y las validaciones finales. La retención máxima de logs y la limpieza de asistencias siguen como mejoras pendientes.

El fallo está reproducido con las clases reales. Su contribución exacta al teléfono reportado queda pendiente de medir: `adb devices -l` no encontró dispositivos y no se verificó qué versión está instalada. No hay evidencia de una curva matemáticamente exponencial; sí de generación continua sin límite de retención.

**Actualización tras verificar el servidor:** el 29 de septiembre a las 00:47 de Ciudad de México se confirmó que la clave de desarrollo presente en los APK/AAB locales recibe `401 INVALID_APP_LOG_KEY`. La clave del despliegue sí permite guardar eventos y confirmar duplicados. Véase la sección 8 y el [resultado de la verificación](/home/jared/Proyectos/presencia/app-profesor/docs/auditoria-almacenamiento/ingestion_verification_result.json).

## 1. Hallazgo principal: los logs generan más logs — prioridad crítica

La secuencia es:

```text
AppLogService.record()
  → consulta userIdentifierProvider
  → AuthStorageService.getProfesor()
  → Logger.debug('Datos del profesor recuperados')
  → AppLogService.instance.record()
  → vuelve a comenzar
```

El callback se configura en [main.dart:58](/home/jared/Proyectos/presencia/app-profesor/lib/main.dart:58). La lectura del profesor escribe un DEBUG en [auth_storage_service.dart:105](/home/jared/Proyectos/presencia/app-profesor/lib/services/auth_storage_service.dart:105), y `Logger.debug` persiste ese evento sin comprobar el modo de compilación en [utils.dart:35](/home/jared/Proyectos/presencia/app-profesor/lib/core/utils/utils.dart:35).

El servicio consulta al profesor dentro de cada escritura en [app_log_service.dart:125](/home/jared/Proyectos/presencia/app-profesor/lib/services/app_log_service.dart:125). `_writeTail` serializa las escrituras, pero no evita que cada una programe otra. No es necesario que el profesor siga usando la pantalla para que se produzcan eventos. Tampoco depende de que la app se compile en debug.

Con servidor disponible puede haber envío y borrado simultáneo, pero continúan las escrituras y solicitudes innecesarias. Sin confirmaciones, todos los eventos nuevos se acumulan en disco. Al eliminar la identidad almacenada, esta ruta concreta deja de producir el DEBUG, pero los logs acumulados no se borran por cerrar sesión.

### Reproducción controlada

Se inicializaron Hive y `AuthStorageService` con un profesor ficticio; se utilizó `AppLogService.instance` y el mismo callback de identidad que usa la app. Se desactivó el envío para aislar la escritura y representar la retención sin confirmaciones. Un corte exclusivo de la prueba impidió llamar al getter después de 1,000 lecturas; producción no tiene ese corte.

| Medida | Resultado |
| --- | ---: |
| Evento inicial externo | 1 (`app.started`) |
| DEBUG producidos por la propia cadena | 1,000 |
| Total de eventos almacenados | 1,001 |
| Archivo Hive de la cola | 731,719 bytes, aproximadamente 0.732 MB |
| Archivo después de `compact()` | 731,719 bytes |
| Tiempo de la reproducción en este equipo de desarrollo | 324 ms |

El tiempo es una medición de escritorio y **no permite atribuir MB/minuto al teléfono**. Compactar no ayuda con estos eventos: siguen siendo registros vigentes pendientes de entrega.

## 2. Cola de diagnóstico sin retención máxima — prioridad alta

En [app_log_service.dart:22](/home/jared/Proyectos/presencia/app-profesor/lib/services/app_log_service.dart:22) se definen un lote de 50 eventos y un presupuesto de 800,000 bytes por lote. **Esos valores no limitan el archivo local.** Hay recortes de tamaño por campo, pero ninguna cuota total ni vencimiento.

La única eliminación de eventos está en [app_log_service.dart:233](/home/jared/Proyectos/presencia/app-profesor/lib/services/app_log_service.dart:233): borra IDs reconocidos explícitamente por el servidor. Si hay falta de conexión, error HTTP, respuesta inválida o ninguna confirmación, conserva la cola y reintenta. El temporizador consulta cada cinco segundos y los fallos aplican espera creciente hasta unos treinta segundos, más variación aleatoria.

Además:

- Cerrar sesión no limpia esta cola.
- `DatabaseService.clearAll()` la excluye expresamente: [database_service.dart:63](/home/jared/Proyectos/presencia/app-profesor/lib/services/database_service.dart:63). No se encontró una llamada productiva a este método.
- El botón de borrar asistencias tampoco la toca.
- La conservación de logs durante la limpieza está exigida por una prueba existente, por lo que una política de retención requiere ajustar ese contrato de forma deliberada.
- En cada lote, `flush()` recorre, copia y ordena toda la cola antes de seleccionar hasta 50 eventos: [app_log_service.dart:210](/home/jared/Proyectos/presencia/app-profesor/lib/services/app_log_service.dart:210). Una cola muy grande aumenta también el trabajo de CPU y la memoria temporal al intentar vaciarla.

### Configuración que puede impedir el vaciado

`env.production.json` no contiene `PRESENCIA_LOG_INGESTION_KEY`. El código utiliza entonces el valor de desarrollo definido en [api_constants.dart:99](/home/jared/Proyectos/presencia/app-profesor/lib/core/constants/api_constants.dart:99), y el arranque habilita de todas formas el servicio de logs.

La verificación posterior confirmó el rechazo real de la clave de desarrollo y su presencia en los artefactos release locales. La clave real del despliegue no aparece en sus bibliotecas nativas. Por tanto, esos artefactos tienen un problema de configuración de ingesta; sigue pendiente comprobar si el teléfono afectado usa exactamente alguno de ellos.

## 3. Qué se guarda y cuándo se elimina

Hive se inicializa con `Hive.initFlutter()`, que en la dependencia instalada utiliza `getApplicationDocumentsDirectory()`. Son datos persistentes de la app. No están guardados en el directorio temporal de caché del sistema; por ello, el botón de Android para borrar solo caché no es la limpieza de estas bases. Android distingue ambos directorios en su [documentación de almacenamiento privado](https://developer.android.com/training/data-storage/app-specific); el destino de documentos está descrito también en [path_provider](https://pub.dev/documentation/path_provider/latest/path_provider/getApplicationDocumentsDirectory.html).

| Almacén | Contenido | Actualización y límite | Limpieza actual |
| --- | --- | --- | --- |
| `presencia_app_log_queue_v1` | INFO, DEBUG, errores, contexto, stack traces e identidad del evento | Se agrega un registro con ID nuevo por evento; sin cuota total ni caducidad | Solo eventos confirmados por el servidor; sobrevive al logout y a `clearAll()` |
| `presencia_app_log_metadata_v1` | Identificador de instalación y secuencia | Claves fijas; contador reemplazado | Sobrevive a la limpieza de sesión; volumen lógico pequeño |
| `auth`: profesor y sesión auxiliar | Perfil, indicadores de sincronización | Claves fijas | Perfil e indicadores se eliminan al cerrar sesión |
| `auth`: `grupos_data` y ciclo | Grupos, horarios, alumnos y URLs de fotos | Se reemplaza la lista completa; no se agrega un historial por descarga | Logout o eliminación de grupos; una actualización exitosa reemplaza las clases y elimina las desasignadas |
| `auth`: `beacons_data` | Configuraciones de aulas y beacons | Se reemplaza el conjunto, normalizado por aula cuando hay identificador | Logout; reemplazo con nuevas configuraciones |
| `auth`: `student_device_bindings_data` | Vínculos de matrícula a dispositivo/UUID | Mapa por matrícula; se reemplazan las consultadas y se conservan otras, sin caducidad por ciclo | Logout; eliminación de vínculos ausentes solo dentro de las matrículas consultadas |
| `asistencias` | Listas por clase/fecha, marcas de alumnos, horas, snapshot de envío y detecciones BLE | Actualiza por ID; nuevos días/clases añaden registros. Sin caducidad o cuota | Borrado manual; existe limpieza de sincronizadas, pero no tiene llamadas productivas |
| Almacén seguro | Token y credencial UAT | Claves fijas en Keychain/Keystore | Se eliminan al cerrar sesión; no es un historial creciente |
| Preferencias | Tema; en `auth`, último correo, tolerancia y ID del dispositivo | Claves fijas | Algunas se conservan tras logout; tamaño pequeño |
| `professors`, `students`, `groups`, `attendance` | Cajas genéricas heredadas | Se abren al iniciar; no se encontraron escrituras de negocio actuales mediante `DatabaseService` | `clearAll()` podría limpiarlas; instalaciones antiguas requieren medir sus archivos |
| Fotos en `Image.network` | Imágenes de alumnos | Se usa la caché de imágenes de Flutter en memoria; no se encontró un gestor de descargas de fotos a disco en el código de la app | Gestión de memoria de Flutter; no explica por sí sola una base persistente que crece |

El avatar se carga en [student_scanner_page.dart:698](/home/jared/Proyectos/presencia/app-profesor/lib/features/groups/screens/student_scanner_page.dart:698). [NetworkImage](https://api.flutter.dev/flutter/painting/NetworkImage-class.html) documenta su participación en la caché de imágenes. No se detectó en el código revisado una colección persistente de capturas o archivos multimedia descargados.

## 4. Asistencias sin limpieza automática — prioridad media

`marcarComoSincronizada()` conserva el registro y agrega/reemplaza el snapshot de alumnos; no elimina la asistencia: [asistencia_local_service.dart:145](/home/jared/Proyectos/presencia/app-profesor/lib/services/asistencia_local_service.dart:145).

`limpiarSincronizadas()` está implementado en [asistencia_local_service.dart:182](/home/jared/Proyectos/presencia/app-profesor/lib/services/asistencia_local_service.dart:182), pero la búsqueda de llamadas en `lib/` encontró únicamente su declaración. No hay una tarea de retención por antigüedad. El logout solo limpia la sesión y no esta caja: [profesor_auth_provider.dart:433](/home/jared/Proyectos/presencia/app-profesor/lib/features/authentication/providers/profesor_auth_provider.dart:433).

Guardar un cambio del mismo día reemplaza el registro por ID; por sí solo no agrega una nueva asistencia por cada detección. El historial sí aumenta al registrar nuevas clases/fechas.

El botón “Borrar asistencias guardadas” llama a `limpiarTodo()`, que vacía **toda** la caja de asistencias: [grupos_page.dart:2117](/home/jared/Proyectos/presencia/app-profesor/lib/features/groups/screens/grupos_page.dart:2117). El diálogo afirma que solo afecta a las aún no enviadas, lo que no coincide con esa implementación. Esta acción puede eliminar trabajo pendiente y **no resuelve la acumulación de logs**.

## 5. Reescritura de vínculos y compactación — prioridad media

Mientras corresponde actualizar los alumnos en primer plano, se consultan los vínculos cada treinta segundos: [grupo_detail_page.dart:2095](/home/jared/Proyectos/presencia/app-profesor/lib/features/groups/screens/grupo_detail_page.dart:2095). Una respuesta exitosa actualiza `updatedAt` y serializa de nuevo el mapa de vínculos: [auth_storage_service.dart:417](/home/jared/Proyectos/presencia/app-profesor/lib/services/auth_storage_service.dart:417). Se escribe incluso si los vínculos funcionales son iguales.

También se preservan matrículas fuera de la consulta actual; no se encontró una purga explícita de todos los vínculos de alumnos que dejaron de pertenecer a los grupos del ciclo.

Hive 2.2.3, la versión instalada, **sí compacta automáticamente**. Su estrategia se activa cuando existen más de 60 entradas obsoletas y su relación con las entradas actuales supera 0.15. La app no especifica una estrategia distinta ni compactación explícita. Por tanto, hay crecimiento físico transitorio entre compactaciones; no es correcto atribuirlo a una ausencia total de compactación.

### Mediciones con datos ficticios

Fixture: seis grupos de cincuenta alumnos, 300 vínculos y 360 registros de asistencia (180 sincronizados con snapshot y 180 pendientes). No son datos ni mediciones del teléfono.

| Medida | Bytes / registros |
| --- | ---: |
| `auth.hive`, una actualización de vínculos | 108,318 bytes |
| `auth.hive`, treinta actualizaciones | 1,828,980 bytes |
| `auth.hive`, sesenta actualizaciones | 3,608,973 bytes |
| `auth.hive`, sesenta y dos actualizaciones, después de compactación automática | 108,318 bytes |
| `asistencias.hive`, 360 asistencias del fixture | 751,200 bytes |
| Asistencias conservadas después del logout | 360 |
| Asistencias después de invocar explícitamente `limpiarSincronizadas()` | 180 pendientes |

Esto diferencia dos fenómenos: las versiones antiguas de una clave pueden recuperarse mediante compactación; miles de logs distintos pendientes siguen ocupando espacio porque la app los considera válidos.

## 6. Correcciones recomendadas, en orden

1. **Romper la cadena de logs.** La obtención de identidad usada por telemetría debe ser una lectura sin efectos secundarios. Añadir protección frente a reentrada y una prueba que ejecute el callback real y compruebe que la cola permanece estable en reposo. Quitar el DEBUG persistente de esta lectura elimina el disparador normal; la protección evita reincidencias por otras rutas, incluidos errores al leer la identidad.
2. **Definir una cuota de telemetría y recuperar lo ya acumulado.** Como punto de partida para acordar: máximo 10 MiB, 10,000 eventos o siete días, lo que se alcance primero, priorizando errores y contando los descartes. Aplicar la política también a instalaciones con una cola grande. Son valores propuestos, no límites actuales. No trasladar esta política de descarte a las asistencias pendientes.
3. **Validar la configuración de ingesta.** No iniciar una cola remota ilimitada con una clave ausente o de ejemplo. Verificar el resultado real de `/api/app-logs/batches` en el despliegue y mostrar el estado del envío sin registrar nuevos errores mediante la misma ruta recursiva. Desactivar DEBUG persistente en release y reducir mensajes repetidos de INFO.
4. **Hacer eficiente el vaciado.** Evitar ordenar y copiar todos los eventos por cada lote de 50; procesar una selección acotada y conservar garantías de confirmación e idempotencia.
5. **Retención segura de asistencias confirmadas.** Acordar un plazo, por ejemplo treinta días, y eliminar solo registros confirmados y sin cambios posteriores pendientes. Las no enviadas deben seguir protegidas. Alinear el texto y comportamiento del botón de borrado con su alcance real.
6. **Evitar reescrituras de vínculos idénticos y retirar vínculos obsoletos.** Comparar los campos funcionales, no usar el mero cambio de `updatedAt` como razón para reescribir toda la colección, y depurar por grupos/ciclo activos cuando haya una respuesta completa válida.
7. **Añadir un desglose de almacenamiento en la app.** Bytes de logs, asistencias pendientes, asistencias confirmadas y catálogos; fecha de último envío y botón específico para limpiar diagnóstico/caché reconstruible sin borrar asistencias pendientes.

## 7. Validación y límites de la auditoría

- Dos pruebas diagnósticas con datos ficticios confirmaron la cadena de logs, su tamaño, la compactación de catálogos y la conservación de asistencias. Se guardan junto al informe. Tras el arreglo, `log_chain_probe_test.dart` se actualizó para comprobar que la cola queda estable; `log_chain_result.json` conserva la medición original y `log_chain_fixed_result.json` la posterior.
- Pasaron **17 pruebas existentes** de logs, preservación durante limpieza, asistencias, vínculos, caché de grupos y lotes de asistencia.
- Las pruebas de logs existentes utilizan instancias `forTesting()` sin el callback real de identidad; por eso no detectan el ciclo formado con `Logger` y `AppLogService.instance`.
- No hubo teléfono conectado. Falta medir los archivos del contenedor de la instalación afectada y verificar la versión instalada para atribuir porcentajes reales a cada categoría.
- No se modificó código productivo ni se borraron datos de la aplicación. Se añadieron este informe, las dos pruebas diagnósticas y los resultados de su ejecución. La verificación posterior de recepción insertó un único evento ficticio en el servidor, descrito en la sección 8.

Desde la raíz del proyecto, las reproducciones se ejecutan con:

```bash
flutter test --no-pub docs/auditoria-almacenamiento/log_chain_probe_test.dart --reporter expanded
flutter test --no-pub docs/auditoria-almacenamiento/storage_inventory_probe_test.dart --reporter expanded
```

Para repetir la validación existente:

```bash
flutter test --no-pub test/services/app_log_service_test.dart test/services/database_service_log_preservation_test.dart test/services/asistencia_local_service_test.dart test/services/student_binding_cache_test.dart test/features/authentication/providers/profesor_groups_cache_test.dart test/services/attendance_batch_service_test.dart --reporter expanded
```

La comprobación sobre el teléfono debe separar tamaño de instalación, datos de usuario y caché del sistema, y registrar bytes y cantidad de entradas de cada caja con la app estable. En Android, el acceso directo al contenedor mediante `run-as` requiere una build depurable; si la instalada es release, se necesita instrumentación de diagnóstico dentro de la app. **Borrar datos o reinstalar antes de resguardar asistencias pendientes puede perder trabajo y eliminar la evidencia del problema.**

## 8. Verificación real del servidor y las compilaciones

Comprobación del 29 de septiembre de 2026, aproximadamente 06:47 UTC / 00:47 de Ciudad de México, contra `https://dashboarduat.presenciauat.fit`.

| Comprobación | Resultado observado |
| --- | --- |
| `GET /health/ready` | HTTP 200; dependencia `appLogs` con `ok: true` y estado 200 |
| Ingesta usando la clave de desarrollo de la app | HTTP 401, `INVALID_APP_LOG_KEY`, “Cliente de logs no autorizado” |
| Ingesta con la clave de despliegue y cuerpo vacío deliberadamente inválido | HTTP 400, `VALIDATION_ERROR`; pasó la autenticación y llegó a la validación del lote |
| Un evento ficticio válido con la clave de despliegue | HTTP 202, `inserted: 1`, `duplicates: 0`, y el ID incluido en `acceptedEventIds` |
| Repetición del mismo evento | HTTP 200, `inserted: 0`, `duplicates: 1`, y el mismo ID confirmado |

El evento de auditoría se llama `audit.log_ingestion_check`, tiene aplicación `PROFESSOR`, versión `storage-audit` e ID `0cd278ea-4e27-4039-a826-c71c705cb29c`. No contiene nombres, correos ni datos de alumnos/profesores. Hubo una sola inserción; el reintento confirmó la deduplicación. El endpoint devolvió `committedAt: 2026-09-29T06:47:34.139Z` para la inserción inicial.

El código del servidor persiste mediante `createMany()` y después consulta los IDs presentes antes de devolverlos: [prisma-log.repository.ts:8](/home/jared/Proyectos/presencia/services/app-log-service/src/infrastructure/prisma-log.repository.ts:8). La respuesta observada y la confirmación posterior como duplicado verifican la recepción y persistencia por el contrato público. No se consultaron logs privados de usuarios ni se verificó su visibilidad en la interfaz de Super Usuario.

### Evidencia en los artefactos

Se inspeccionaron las bibliotecas `libapp.so` para ARM, ARM64 y x86_64 de estos archivos:

- [APK release local](/home/jared/Proyectos/presencia/app-profesor/build/app/outputs/flutter-apk/app-release.apk), modificado el 18 de septiembre.
- [AAB release local](/home/jared/Proyectos/presencia/app-profesor/build/app/outputs/bundle/release/app-release.aab), modificado el 28 de septiembre.

En ambos aparece la clave de desarrollo y no aparece la clave configurada en el archivo local del despliegue. Se guardaron sus hashes SHA-256 en el resultado JSON para identificar qué artefactos se revisaron. No se publicaron claves ni se cambiaron secretos del servidor.

El archivo `env.production.json` no define `PRESENCIA_LOG_INGESTION_KEY`, no hay `env.local.json` en esta copia de la app, y el comando de App Bundle del README únicamente aporta el archivo público y `USE_MOCK=false`. La configuración del servidor sí contiene `APP_LOG_INGESTION_KEY`; esa clave fue la que funcionó en la prueba. La documentación de operación exige que ambas coincidan: [APP_LOGS.md:81](/home/jared/Proyectos/presencia/docs/operations/APP_LOGS.md:81).

### Qué falta

1. Corregir primero la generación recursiva de logs; habilitar la entrega por sí sola trasladaría el volumen excesivo al servidor, cuya base de logs tampoco tiene eliminación automática.
2. Inyectar en una nueva compilación `PRESENCIA_LOG_INGESTION_KEY` con el mismo valor de `APP_LOG_INGESTION_KEY` del despliegue. Usar un archivo local ignorado por Git o secretos de CI/CD; no agregar la clave al archivo público versionado.
3. Añadir una validación de compilación release que detecte ausencia o uso de la clave de ejemplo, y configurar versión/build reales en la telemetría.
4. Distribuir la actualización conservando los datos existentes. Después comprobar que la cola previa del teléfono disminuye al recibir confirmaciones del servidor. El funcionamiento del servicio quedó comprobado; la entrega de los eventos históricos de ese teléfono aún no.

No se generó ni distribuyó una nueva versión en esta verificación. No hace falta crear otra ruta de recepción ni sustituir la clave correcta del servidor: el problema confirmado está en la clave que incorporan las compilaciones locales inspeccionadas.

## 9. Arreglo y compilaciones verificadas

Después de recibir la clave del usuario se confirmó, sin imprimirla, que coincidía con la configuración de despliegue ya validada. Se creó `env.local.json` con permisos `0600`; Git lo ignora. No se agregó la clave al código, documentación o archivos públicos de configuración.

Cambios productivos:

- Se eliminó el DEBUG que escribía `AuthStorageService.getProfesor()` en cada lectura correcta.
- Se añadió una protección en `AppLogService.record()` mientras se consulta el callback de identidad. También evita la cadena cuando el getter intenta registrar un error por datos locales corruptos. La protección se restablece en `finally`; los eventos independientes siguen guardándose.
- Se agregó [tool/build_release.py](/home/jared/Proyectos/presencia/app-profesor/tool/build_release.py). Valida que exista una clave distinta de los valores de ejemplo y pasa configuración a Flutter mediante un archivo temporal privado. Incluye versión/build reales y autenticación real. El README indica este comando tanto para APK como para AAB.

No se modificaron las asistencias ni se descartaron logs acumulados. Se conserva el borrado de logs únicamente después de confirmación del servidor. La política de cuotas/antigüedad todavía no está implementada.

Validación:

- **19 pruebas existentes y de regresión aprobadas**, incluyendo callback real, datos de identidad corruptos, callback que genera logs, excepción en callback, concurrencia y preservación de asistencias.
- Análisis estático de los archivos Dart modificados y su prueba: **sin problemas**.
- Repetición de la medición de la cola: **1 evento, 0 DEBUG autogenerados, 772 bytes**, frente a 1,001 eventos y 731,719 bytes antes del arreglo. Son datos ficticios, no el teléfono.
- El transporte real `HttpAppLogTransport`, usando la configuración local, reenvió el UUID ficticio ya existente. El servidor lo confirmó y `AppLogService.flush()` redujo la cola temporal **de 1 a 0**. No se agregó otro evento al servidor. Para esta prueba en vivo se desactivó el reemplazo automático de HTTP de Flutter Test, que de otro modo simula respuestas 400 sin hacer red.
- APK y AAB release **1.0.0+1** compilados correctamente. En las bibliotecas ARM, ARM64 y x86_64 de ambos se comprobó la presencia de la clave correcta y la ausencia de la clave de desarrollo, sin mostrar sus valores.
- Firma del APK verificada con `apksigner`.
- Los hashes y resultados finales están en [fixed_release_verification_result.json](/home/jared/Proyectos/presencia/app-profesor/docs/auditoria-almacenamiento/fixed_release_verification_result.json). Los artefactos locales reemplazan los anteriores; sus hashes antiguos permanecen en `ingestion_verification_result.json`.

Archivos generados:

- [APK actualizado](/home/jared/Proyectos/presencia/app-profesor/build/app/outputs/flutter-apk/app-release.apk).
- [AAB actualizado](/home/jared/Proyectos/presencia/app-profesor/build/app/outputs/bundle/release/app-release.aab).

No se instalaron en el teléfono ni se publicaron en Google Play. Falta verificar la reducción de la cola histórica del dispositivo tras instalar la actualización conservando los datos. Para una nueva publicación en la tienda se debe seleccionar un número de compilación superior al último publicado.
