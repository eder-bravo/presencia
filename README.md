# Presencia

Monorepo del proyecto de asistencia UAT.

## Estructura

```txt
presencia/
|- app-alumno/
|- app-profesor/
|- backend/
|- backend-apirest/
|- frontend-coord/
|- packages/
|- services/
`- infra/
```

## Arquitectura

- [Descripción general del proyecto](docs/PROYECTO.md)
- [Plan de migración a microservicios](docs/architecture/PLAN_MIGRACION_MICROSERVICIOS.md)
- [Auditoría de finalización y evidencia](docs/architecture/AUDITORIA_FINALIZACION_2026-08-03.md)
- [Modo demo aislado](docs/operations/MODO_DEMO.md)
- [Cuentas aisladas para App Review](docs/operations/APP_REVIEW.md)

## backend-apirest

`backend-apirest` es el backend puente/ACL entre `app-profesor` y el portal
UAT. No reemplaza al sistema escolar original; consume por HTTP la API/sitio de
`https://administracionescolar.uat.edu.mx` usando sesion ASP.NET basada en
cookies.

## Arquitectura implementada

El punto público único es `api-gateway`. La migración conserva las rutas de las
apps y separa datos en bases PostgreSQL independientes:

- `identity-service`: identidades y sesiones revocables;
- `academic-service`: profesores, alumnos, horarios, grupos, roster y clases compartidas;
- `attendance-service`: asistencia, permisos proyectados y vinculación matrícula/celular/UUID;
- `coordination-query-service`: dashboard y reportes reconstruibles;
- `app-log-service`: ingesta idempotente y consulta de logs móviles append-only;
- `backend-apirest`: integración y anticorrupción con los portales UAT;
- `demo-portal-service`: sustituto privado de ambos portales cuando el despliegue activa el modo demo;
- RabbitMQ: eventos durables con reintentos/DLQ;
- Redis: sesiones UAT compartidas, rate limiting y caché efímera.

UAT Integration conserva salida HTTPS mediante una red de egreso dedicada,
sin publicar puertos. La red privada de datos continúa aislada de Internet.

Los backends anteriores permanecen como fachadas de compatibilidad sólo donde
los clientes aún necesitan el contrato histórico. Los nuevos servicios son los
propietarios de los flujos críticos y la migración de rutas es reversible.

## Despliegue en Dokploy

El Compose integral está en
`infra/compose/docker-compose.microservices.yml`.

Configuracion recomendada:

```txt
Build Type: Docker Compose
Compose Path: infra/compose/docker-compose.microservices.yml
Root Directory / Base Directory: raiz del repositorio
```

Asigna el dominio web únicamente a `frontend-coord`, puerto `8080`; Nginx envía
`/api` al Gateway. No asignes dominios a servicios internos.

Ambos contenedores se conectan a la red externa `dokploy-network`, necesaria
para que Traefik enrute los dominios y para alcanzar servicios administrados
por Dokploy, como PostgreSQL, mediante su hostname interno.

Copia y sustituye `infra/compose/.env.dokploy.example`. La guía completa,
validación de secretos, smoke test, rollback y backups está en
[docs/operations/DOKPLOY.md](docs/operations/DOKPLOY.md).
Los SLO, alertas Prometheus y procedimientos de incidentes están en
[docs/operations/RUNBOOK_INCIDENTES.md](docs/operations/RUNBOOK_INCIDENTES.md).
La cola offline, el contrato, la privacidad y la operación de logs se describen
en [docs/operations/APP_LOGS.md](docs/operations/APP_LOGS.md).
La ingesta móvil tiene un contrato OpenAPI independiente en
[docs/openapi/app-log-service.yaml](docs/openapi/app-log-service.yaml).
Para presentar las apps sin datos institucionales, usa un proyecto aislado y
sigue [docs/operations/MODO_DEMO.md](docs/operations/MODO_DEMO.md).

Para el primer coordinador usa:

```env
COORDINATOR_EMAIL=coordinacion@uat.edu.mx
COORDINATOR_NAME=Coordinacion Academica
COORDINATOR_PASSWORD=contra123
```

Para varios coordinadores usa `COORDINATORS_JSON`. En el primer despliegue el
job `staff-account-import` adopta esas cuentas en Identity. Después administra
altas, roles, bloqueos y rotación de contraseñas desde el panel de superusuario;
los despliegues posteriores no sobrescriben esos cambios.

## Verificación local

```bash
npm ci
npm run verify
npm run typecheck --prefix backend-apirest
npm test --prefix backend-apirest
npm run typecheck --prefix backend
npm test --prefix backend -- --run
npm run typecheck --prefix frontend-coord
npm test --prefix frontend-coord
cd app-alumno && flutter analyze && flutter test
cd ../app-profesor && flutter analyze && flutter test
```

El workflow de CI también levanta el Compose completo con secretos efímeros y
ejecuta las sondas públicas a través del mismo Nginx usado en Dokploy. Antes de
levantar el stack valida también ambos clientes Flutter.

La app del profesor no persiste la contraseña UAT: elimina la clave heredada de
Hive y sólo mantiene una copia efímera en memoria durante el proceso activo.
Los identificadores de sesión se guardan en el almacén seguro nativo
(Android Keystore/iOS Keychain) y las instalaciones existentes migran y eliminan
automáticamente los tokens heredados de Hive.

## Integraciones

- `app-profesor` y `app-alumno` consumen el dominio público del Gateway.
- UAT Integration consume los portales de maestros y alumnos de la UAT.
- `app-alumno` obtiene perfil y horario por REST después del login obligatorio,
  sin bloquear el flujo de asistencia mientras actualiza los datos académicos.
- El dashboard de coordinación autoriza cambios de celular revocando el vínculo
  actual; el nuevo UUID sólo se registra en el siguiente login estudiantil.
- El panel de superusuario también permite registrar manualmente la matrícula y
  el UUID de un beacon emulado en iOS; Attendance lo vincula de forma auditada
  al mismo padrón utilizado por el pase automático.
- En la lista de alumnos de cada grupo, la app del profesor muestra el alta por
  UUID sólo para matrículas aún no vinculadas. Attendance comprueba que el
  profesor sea titular o sustituto autorizado y no permite reemplazar vínculos
  activos desde esta ruta.
- Durante el pase automático, los vínculos manuales sin identidad de dispositivo
  se detectan como iBeacon estándar (para emuladores externos de iPhone); los
  vínculos creados por `app-alumno` conservan el escaneo y la confirmación GATT.

## Referencias

- `backend-apirest/README.md`
- `backend-apirest/docs/openapi.yaml`
- `docs/operations/DOKPLOY.md`
