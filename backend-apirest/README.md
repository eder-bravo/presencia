# backend-apirest

API REST aislada para consumir endpoints internos del Sistema Administrativo
Escolar UAT usando autenticacion ASP.NET por cookies. Cada login crea un
`CookieJar` serializado y cifrado en Redis con TTL; cualquier réplica puede
continuar la sesión sin afinidad y conserva `.ASPXAUTH`, `ASP.NET_SessionId` y
las cookies adicionales que entregue el portal.

## Instalacion

```bash
cd backend-apirest
npm install
cp .env.example .env
npm run dev
```

Por defecto escucha en `http://localhost:3100`.

## Despliegue en Dokploy

El despliegue recomendado usa el Compose integral de microservicios. En
Dokploy configura:

```txt
Root Directory / Base Directory: raiz del repositorio
Build Type: Docker Compose
Compose Path: infra/compose/docker-compose.microservices.yml
```

El dominio se asigna a `frontend-coord:8080`. Nginx reenvía el API al Gateway,
que conserva las rutas públicas y selecciona el servicio propietario. No se
debe asignar un dominio directo a `backend-apirest` ni a otro servicio interno.

Los servicios de dominio, PostgreSQL, Redis y RabbitMQ sólo se conectan a la
red privada. Consulta `../docs/operations/DOKPLOY.md` para variables, orden de
arranque, smoke test, rollback y backups.

Variables recomendadas:

```env
NODE_ENV=production
HOST=0.0.0.0
PORT=3100
UAT_BASE_URL=https://administracionescolar.uat.edu.mx
UAT_ALUMNOS_BASE_URL=https://alumnossur.uat.edu.mx
UAT_HTTP_TIMEOUT_MS=30000
UAT_SESSION_TTL_MINUTES=45
ATTENDANCE_JOB_ENCRYPTION_SECRET=un-secreto-estable-de-al-menos-32-caracteres
DATABASE_URL=postgresql://usuario:password@postgres:5432/presencia_coordination?schema=public
DATABASE_MIGRATION_MAX_ATTEMPTS=10
DATABASE_MIGRATION_RETRY_MS=3000
COORDINATION_WEB_ORIGIN=https://tu-dominio.example
COORDINATION_COOKIE_SECURE=true
IDENTITY_SERVICE_URL=http://identity-service:3200
ACADEMIC_SERVICE_URL=http://academic-service:3300
ATTENDANCE_SERVICE_URL=http://attendance-service:3400
COORDINATION_QUERY_SERVICE_URL=http://coordination-query-service:3500
ATTENDANCE_BACKEND_SERVICE_TOKEN=token-interno-compartido-de-al-menos-32-caracteres
COORDINATOR_EMAIL=coordinacion@uat.edu.mx
COORDINATOR_NAME=Coordinacion Academica
COORDINATOR_PASSWORD=contra123
# Alternativa para varias cuentas:
COORDINATORS_JSON=[{"email":"coord1@uat.edu.mx","name":"Coordinador Uno","password":"clave-segura-123"}]
```

En `DATABASE_URL` usa el hostname interno del servicio PostgreSQL de Dokploy;
`localhost` apuntaria al propio contenedor de la API. Si PostgreSQL es externo,
agrega los parametros SSL exigidos por el proveedor.

Al desplegar una revisión, el Compose realiza en orden:

1. `prisma migrate deploy`, con reintentos mientras PostgreSQL arranca.
2. Aprovisionamiento legado de las cuentas definidas en `COORDINATORS_JSON` o
   en las tres variables `COORDINATOR_*`, seguido por adopción única en Identity.
   Las ejecuciones posteriores no pisan cambios administrados en Identity.
3. Inicio de `backend-apirest` en el puerto configurado, después de Identity,
   Academic, Attendance y Coordination Query.

Si una migracion falla o las credenciales de coordinacion estan incompletas, el
contenedor termina con error y Dokploy conserva los logs del motivo; no inicia
la API sobre un esquema incompleto.

Los archivos `.dockerignore` evitan enviar dependencias, builds y secretos al
daemon de Docker.

## Flujo principal

1. `POST /api/uat/sessions` con usuario y password.
2. Guardar el `sessionId` devuelto por esta API.
3. Enviar `X-UAT-Session-Id: <sessionId>` en consultas posteriores.
4. Consultar horarios/examenes con `Id_Ciclo_Escolar` e `Id_DES`.

El backend ejecuta internamente:

```txt
GET  https://administracionescolar.uat.edu.mx/Login
POST https://administracionescolar.uat.edu.mx/Login/Accesar_Dominio
GET  https://administracionescolar.uat.edu.mx/Login/Validar
GET  https://administracionescolar.uat.edu.mx/Profesor/Consultas/BuscaHorarios
GET  https://administracionescolar.uat.edu.mx/Profesor/Consultas/BuscaExamenes
GET  https://administracionescolar.uat.edu.mx/Profesor/ControlAsistencia/BuscaGruposProfesor
GET  https://administracionescolar.uat.edu.mx/Profesor/ControlAsistencia/BuscaSemanas
GET  https://administracionescolar.uat.edu.mx/Profesor/ControlAsistencia/BuscaAsistenciaGrupo
POST https://administracionescolar.uat.edu.mx/Profesor/ControlAsistencia/GuardaAsistencias
```

## Ejemplos curl

Crear sesion:

```bash
curl -X POST http://localhost:3100/api/uat/sessions \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"CORREO_USUARIO\",\"password\":\"PASSWORD_USUARIO\"}"
```

Consultar horarios:

```bash
curl "http://localhost:3100/api/uat/profesor/consultas/horarios?Id_Ciclo_Escolar=150&Id_DES=12" \
  -H "X-UAT-Session-Id: SESSION_ID"
```

Consultar examenes:

```bash
curl "http://localhost:3100/api/uat/profesor/consultas/examenes?Id_Ciclo_Escolar=150&Id_DES=12" \
  -H "X-UAT-Session-Id: SESSION_ID"
```

Flujo completo en una sola llamada, sin guardar sesion:

```bash
curl -X POST http://localhost:3100/api/uat/profesor/consultas/snapshot \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"CORREO_USUARIO\",\"password\":\"PASSWORD_USUARIO\",\"Id_Ciclo_Escolar\":150,\"Id_DES\":12,\"includeExamenes\":true}"
```

Crear sesion de alumno:

```bash
curl -X POST http://localhost:3100/api/uat/alumnos/sessions \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"correo.alumno@alumnos.uat.edu.mx\",\"password\":\"PASSWORD\",\"idPlanEstudio\":3313,\"attendanceUuid\":\"12345678-1234-4234-9234-123456789abc\",\"deviceBindingId\":\"12345678-1234-4234-9234-123456789abd\",\"platform\":\"android\"}"
```

`idPlanEstudio` es opcional. Si no se envia, la API selecciona la primera
carrera devuelta por `/Home/CarrerasAlumno`.
`attendanceUuid`, `deviceBindingId` y `platform` son obligatorios en cada login.
Attendance Service acepta nuevamente el mismo vínculo, pero rechaza cualquier
cambio de UUID o dispositivo; ese cambio sólo puede realizarlo Coordinación.

Consultar datos de alumno:

```bash
curl http://localhost:3100/api/uat/alumnos/carreras \
  -H "X-UAT-Student-Session-Id: SESSION_ID"

curl http://localhost:3100/api/uat/alumnos/horario \
  -H "X-UAT-Student-Session-Id: SESSION_ID"
```

El backend de alumnos ejecuta internamente:

```txt
GET  https://alumnossur.uat.edu.mx/
POST https://alumnossur.uat.edu.mx/Login/Accesar_Dominio
GET  https://alumnossur.uat.edu.mx/Login/Validar
GET  https://alumnossur.uat.edu.mx/Home/CarrerasAlumno
POST https://alumnossur.uat.edu.mx/Home/SeleccionarCarreraAlumno
GET  https://alumnossur.uat.edu.mx/Alumno/Horario/SpuSelHorarioFichaAlumno
GET  https://alumnossur.uat.edu.mx/Alumno/CalificacionesParciales/SPUSELCalificacionesParciales
GET  https://alumnossur.uat.edu.mx/Alumno/CalificacionesFinales/ConsultaEvaluaciones
```

## Contrato

El contrato OpenAPI esta en:

```txt
docs/openapi.yaml
```

Endpoints incluidos:

```txt
GET    /health
POST   /api/uat/sessions
DELETE /api/uat/sessions/{sessionId}
POST   /api/uat/profesor/sync
GET    /api/uat/profesor/consultas/horarios
GET    /api/uat/profesor/consultas/examenes
POST   /api/uat/profesor/consultas/snapshot
GET    /api/uat/catalogos/niveles-educativos
GET    /api/uat/catalogos/campus
GET    /api/uat/catalogos/des
GET    /api/uat/catalogos/ciclos-escolares
GET    /api/uat/profesor/control-asistencia/grupos
GET    /api/uat/profesor/control-asistencia/semanas
GET    /api/uat/profesor/control-asistencia/asistencia-grupo
POST   /api/uat/profesor/control-asistencia/asistencias
POST   /api/uat/asistencia/guardar
POST   /api/uat/alumnos/sessions
DELETE /api/uat/alumnos/sessions/{sessionId}
GET    /api/uat/alumnos/carreras
POST   /api/uat/alumnos/carreras/seleccionar
GET    /api/uat/alumnos/horario
GET    /api/uat/alumnos/calificaciones/parciales
GET    /api/uat/alumnos/calificaciones/finales
GET    /api/coordinacion/resumen
GET    /api/coordinacion/coordinaciones
GET    /api/coordinacion/profesores
GET    /api/coordinacion/profesores/:teacherId/asignaciones
POST   /api/coordinacion/auth/login
GET    /api/coordinacion/auth/me
POST   /api/coordinacion/auth/logout
GET    /api/coordinacion/reportes/asistencia-semanal
```

## Arquitectura

El servicio quedo organizado por capas:

```txt
src/domain          Tipos UAT y contrato IUatSessionRepository
src/infrastructure  Axios + CookieJar, Redis cifrado, RabbitMQ y clientes internos
src/application     UatService con casos de uso y snapshot
src/presentation    Controladores, hooks Fastify, schemas Zod y rutas
```

## Cosecha incremental para coordinacion

Cada `POST /api/uat/sessions` exitoso publica un evento durable de profesor
autenticado. `POST /api/uat/profesor/sync` permite volver a publicarlo con la
sesión vigente, sin recibir de nuevo la contraseña. El consumidor idempotente
reutiliza la sesión UAT, descubre ciclos/DES y envía snapshots diferenciales a
Academic Service. Academic hace `upsert`, desactiva lo ausente sin borrar
historial y publica los cambios por outbox para Attendance y Coordination Query.

Configura `DATABASE_URL` con la conexion PostgreSQL. Para desarrollo, crea o
actualiza el esquema y genera el cliente con:

```bash
npm run prisma:generate
npm run prisma:migrate
```

En produccion aplica exclusivamente las migraciones versionadas:

```bash
npm run prisma:generate
npm run prisma:deploy
```

Los jobs `uat-migrate` y `staff-account-import` ejecutan migraciones y adoptan
cuentas históricas/configuradas en Identity antes de iniciar réplicas HTTP.

Configura la primera cuenta sin guardar su contraseña en el frontend:

```powershell
$env:COORDINATOR_EMAIL="coordinacion@uat.edu.mx"
$env:COORDINATOR_NAME="Coordinación Académica"
$env:COORDINATOR_PASSWORD="una-clave-segura-de-12-caracteres"
```

Para varias cuentas define `COORDINATORS_JSON` como un arreglo de objetos con
`email`, `name`, `password` y opcionalmente `role`. El job de importación las
crea en Identity sólo si todavía no fueron adoptadas. Después, toda rotación,
baja o cambio de rol se realiza desde el panel de superusuario y no es
sobrescrito por despliegues posteriores.

La SPA vive en `frontend-coord`. En desarrollo usa Vite y proxy a `:3100`; en
producción se sirve desde el contenedor independiente `frontend-coord` bajo
`/coordinacion`.

El listado admite `coordinationId`, `search`, `page` y `pageSize` (maximo 100).
Los contratos completos se encuentran en `docs/openapi.yaml`.

Las rutas protegidas usan el hook `authUatHook`, que lee `X-UAT-Session-Id`,
valida la sesion mediante `UatService` e inyecta `request.uatSession`.

## Flujo de asistencia

Consultar grupos del profesor por ciclo:

```bash
curl "http://localhost:3100/api/uat/profesor/control-asistencia/grupos?Id_Des=12&Id_Ciclo=150&Id_Plantilla=308127" \
  -H "X-UAT-Session-Id: SESSION_ID"
```

Consultar semanas de un grupo:

```bash
curl "http://localhost:3100/api/uat/profesor/control-asistencia/semanas?Id_Grupo=947699" \
  -H "X-UAT-Session-Id: SESSION_ID"
```

Consultar alumnos/asistencia de una semana:

```bash
curl "http://localhost:3100/api/uat/profesor/control-asistencia/asistencia-grupo?Id_Grupo=947699&fec_ini=19%2F01%2F2026&fec_fin=25%2F01%2F2026" \
  -H "X-UAT-Session-Id: SESSION_ID"
```

Guardar asistencias:

```bash
curl -X POST http://localhost:3100/api/uat/profesor/control-asistencia/asistencias \
  -H "Content-Type: application/json" \
  -H "X-UAT-Session-Id: SESSION_ID" \
  -d "{\"ClientRecordId\":\"947699_2026-01-19\",\"Id_Grupo\":947699,\"Fec_Ini\":\"19/01/2026\",\"Asistencia\":[{\"id_alumno\":371591,\"num_pase_lista\":1,\"num_dia\":1,\"sn_asistencia\":true}]}"
```

El BFF registra primero la captura idempotente en Attendance Service y, antes
de responder, persiste en PostgreSQL el job de publicación con la credencial
cifrada. El worker serializa `Asistencia` y la envía después al portal UAT como
`application/x-www-form-urlencoded` contra
`/Profesor/ControlAsistencia/GuardaAsistencias`.

La app captura un estado diario por alumno. Antes de publicar, el worker
consulta `BuscaAsistenciaGrupo` para el grupo y la semana de la captura y usa
`Num_Pl_<día>` para generar los pases `1..N` de cada alumno, conservando su
presencia o falta en todas las horas del día. `Num_Lista` es el número del alumno
en el padrón y no identifica una hora; `Txt_Pl_<día>` sólo contiene pases ya
guardados y no determina cuántos deben enviarse. Si UAT no devuelve el padrón o
el total de pases válido, el job se reintenta sin publicar una lista parcial.
Consulta el [diagnóstico de asistencia con varias horas](../docs/operations/ASISTENCIA_MULTIPLES_HORAS.md).

## Clases compartidas

Academic Service es la autoridad de las clases compartidas. UAT Integration
ya no escribe su proyección académica anterior: publica un único snapshot a
Academic después de consultar grupos, horarios y roster UAT. La tabla histórica
sólo se lee desde `npm run import:shared-classes`, un job idempotente previo al
tráfico. Las altas, cambios y bajas desde Coordinación se envían a Academic y
se proyectan por eventos en Attendance.

## Cola durable de asistencias

Los endpoints de captura existentes persisten el job durable antes de responder
`202 Accepted`. Un worker procesa una lista a la vez por profesor, reintenta
errores transitorios con backoff y recupera jobs interrumpidos. La clave
`ATTENDANCE_JOB_ENCRYPTION_SECRET` cifra las credenciales necesarias para
reautenticar contra UAT; debe conservarse estable entre despliegues. El cliente
reconcilia cada `clientRecordId` mediante
`POST /api/uat/asistencia/registros/estado`, incluso después de reiniciar la app.
La entrega ya no depende de que la sesión temporal continúe en Redis.

## Script CLI opcional

Para probar desde terminal sin levantar el servidor:

```bash
UAT_USER="CORREO_USUARIO" \
UAT_PASS="PASSWORD_USUARIO" \
UAT_ID_CICLO_ESCOLAR=152 \
UAT_ID_DES=12 \
npm run fetch:horarios
```

Para validar ambos portales sin imprimir datos académicos ni ejecutar
`GuardaAsistencias`, usa `npm run smoke:uat:readonly`. Requiere
`UAT_STUDENT_USER`, `UAT_STUDENT_PASS`, `UAT_TEACHER_USER` y
`UAT_TEACHER_PASS` sólo en el entorno del proceso. El resultado se limita a
conteos y diagnóstico de cookies; no guardes credenciales reales en `.env` ni
en archivos versionados.

En PowerShell:

```powershell
$env:UAT_USER="CORREO_USUARIO"
$env:UAT_PASS="PASSWORD_USUARIO"
$env:UAT_ID_CICLO_ESCOLAR="152"
$env:UAT_ID_DES="12"
npm run fetch:horarios
```

## Errores esperados

`UAT_LOGIN_FAILED`: el login devolvio `exito: false`.

`UAT_SESSION_REQUIRED`: falta el header `X-UAT-Session-Id`.

`UAT_SESSION_NOT_FOUND`: la sesion local no existe o expiro.

`UAT_SESSION_EXPIRED`: el portal devolvio HTML/Login en vez de JSON.

`UAT_PORTAL_ERROR`: error de red, timeout, cookies faltantes o respuesta inesperada.

## Notas de seguridad

No guardes credenciales reales en `.env`, scripts versionados ni logs. Las
cookies se cifran antes de persistirse en Redis, expiran según
`UAT_SESSION_TTL_MINUTES` y se revocan al cerrar sesión. Las credenciales
temporales necesarias para una carga UAT pendiente se cifran con una clave
separada y nunca se incluyen en eventos.
