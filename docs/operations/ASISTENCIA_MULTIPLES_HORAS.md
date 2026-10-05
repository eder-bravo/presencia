# Asistencia de alumnos con varias horas el mismo día

Diagnóstico realizado el 4 de octubre de 2026 mediante consultas de lectura
al portal institucional. La cuenta y contraseña se usaron sólo durante los
procesos de consulta; no se guardaron en archivos ni se ejecutó
`GuardaAsistencias` sobre datos reales.

## Cómo funciona la integración

1. `UatPortalClient.authenticate` consulta `/Login`, envía el formulario a
   `/Login/Accesar_Dominio` y valida `/Login/Validar` conservando las cookies
   ASP.NET. La sesión operativa se cifra en Redis.
2. La cosecha del profesor descubre ciclo y DES, consulta `BuscaGruposProfesor`
   y `BuscaHorarios`, carga semanas con `BuscaSemanas` y obtiene alumnos con
   `BuscaAsistenciaGrupo`. Publica un snapshot a Academic Service.
3. La app mantiene una captura por grupo, fecha y alumno. El pase BLE y el pase
   manual modifican el mismo estado diario. El envío llega al contrato
   `/api/uat/asistencia/guardar` o su alias de control de asistencia.
4. `AsistenciaController` valida la captura mediante Attendance Service y
   persiste un job durable. La cola conserva el estado diario; el número 1 en
   este snapshot es un marcador de compatibilidad con las apps existentes.
5. `AttendanceUploadWorker` reautentica, consulta los pases programados para
   esa semana, prepara todas las horas y publica el formulario contra
   `/Profesor/ControlAsistencia/GuardaAsistencias`.

## Evidencia del caso reportado

Ciclo consultado: **152, 2026 - 3 OTOÑO**. DES: **12**.
Semana: **28/09/2026–04/10/2026**.

| Grupo UAT | Materia / letra | Día y horario | Pases programados por alumno | Resultado observado |
| --- | --- | --- | --- | --- |
| 971840 | Fundamentos de Programación / Ñ | Lunes y martes 18:00–20:00 | 2 | UAT expone ambos pases |
| 971840 | Fundamentos de Programación / Ñ | Miércoles 18:00–19:00 | 1 | UAT expone un pase |
| 968398 | Programación Avanzada / K | Viernes 12:00–16:00 | 4 | Sólo estaba guardado el pase 1 |
| 968407 | Programación Avanzada / M | Viernes 16:00–20:00 | 4 | La semana aparecía sin captura |

El portal devuelve `Num_Pl_Viernes = 4` y, para el grupo K, valores de
`Txt_Pl_Viernes` como `1,1` y `1,0`: un par **pase, presencia** para el pase 1,
sin pares para los pases 2, 3 y 4. El JavaScript institucional
`/Areas/Profesor/Scripts/ControlAsistencia.js` crea exactamente
`Num_Pl_<día>` casillas por alumno, numeradas desde 1, y envía
`id_alumno`, `num_pase_lista`, `num_dia` y `sn_asistencia` por casilla.

No se debe usar el número de lista del alumno (`Num_Lista`) como pase ni
calcular el total a partir de `Txt_Pl_<día>`, que contiene únicamente lo ya
guardado. Tampoco es necesario inferir horas a partir de la duración del
horario: UAT entrega el total que espera para ese alumno, grupo, semana y día.

## Causa y corrección

La app genera una entrada diaria por alumno con `num_pase_lista = 1` y
`AttendanceUploadService` normalizaba a ese mismo valor. El worker enviaba
directamente ese snapshot a UAT. Un bloque de cuatro horas terminaba con una
única entrada por alumno.

El worker ahora consulta `BuscaAsistenciaGrupo` usando `Fec_Ini` y el fin de
esa misma semana. `expandDailyAttendances` replica el estado de cada alumno a
los pases `1..Num_Pl_<día>` y conserva el día seleccionado. Un alumno presente
recibe presencia en todos sus pases; un alumno ausente recibe falta en todos
sus pases. No se agregan capturas de otros grupos, días o alumnos.

Si falla la lectura, falta un alumno o el total de pases no es un entero
positivo, el worker reintenta sin llamar a `GuardaAsistencias` ni marcar el job
como completado. Se conserva el límite y el backoff de la cola existente.

También se corrigió la cosecha académica: un `Map` por `Id_Grupo` conservaba
sólo la última fila de `BuscaHorarios`. Ahora se agrupan todas las filas del
grupo y se reúnen los bloques por día, eliminando horarios repetidos.

## Validación

- Typecheck, suite completa de pruebas de `backend-apirest` y compilación.
- Pruebas de publicación para 1, 2, 4 y 9 pases, conservando presencia y falta.
- Cobertura de los siete días, respuestas incompletas, fallo del portal,
  duplicados, estados contradictorios y semanas que cruzan mes/año.
- Pruebas de la cosecha con cuatro filas de horario del mismo grupo.
- Preparación en memoria con los datos reales, sin envío a UAT:
  - grupo 971840: 30 alumnos → 60 entradas el lunes, 60 el martes y 30 el miércoles;
  - grupo 968398: 25 alumnos → 100 entradas el viernes, pases 1, 2, 3 y 4;
  - grupo 968407: 23 alumnos → 92 entradas el viernes, pases 1, 2, 3 y 4.

## Despliegue e histórico

La corrección requiere desplegar `backend-apirest`; no cambia el contrato
HTTP, no necesita migración de base de datos ni una nueva app del profesor.
Aplica a jobs nuevos y pendientes, incluidos los creados por apps que mandan
pase 1. Las capturas ya completadas no se reprocesan automáticamente.

Este diagnóstico no modifica asistencias anteriores. Regularizar el histórico
requiere revisar las capturas locales/Attendance y los pases UAT de cada fecha,
y preparar una operación explícita de conciliación. Reenviar una captura
idéntica ya completada puede ser deduplicado por el contrato existente.
