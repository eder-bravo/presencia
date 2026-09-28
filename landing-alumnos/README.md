# Landing de Presencia

Sitio estático para presentar las aplicaciones de alumnos y docentes, responder
preguntas frecuentes y publicar sus documentos legales. Conserva la ruta pública
`/soporte/alumnos/` y sirve la misma portada en `/` y `/soporte/docentes/`.

## Diseño

Rediseño con `design-taste-frontend`: variación 6, movimiento 3 y densidad 4.
La versión anterior usaba una portada dedicada sólo a alumnos, tarjetas
numeradas y una sección de ayuda oscura. La nueva composición usa un tema claro
continuo, naranja de la marca, tipografía Plus Jakarta Sans y capturas reales
como imagen principal. Conserva los enlaces de ayuda y las rutas públicas
existentes de alumnos.

Plus Jakarta Sans se distribuye bajo la
[SIL Open Font License 1.1](https://github.com/tokotype/PlusJakartaSans/blob/master/OFL.txt).

## Rutas

| Página | Ruta |
| --- | --- |
| Landing | `/`, `/soporte/alumnos/`, `/soporte/docentes/` |
| Privacidad de alumnos | `/soporte/alumnos/privacidad/` |
| Términos de alumnos | `/soporte/alumnos/terminos/` |
| Privacidad de docentes | `/soporte/docentes/privacidad/` |
| Términos de docentes | `/soporte/docentes/terminos/` |

La app y la institución pueden manejar datos bajo responsabilidades distintas.
Los textos públicos identifican a Eder Jahir Gonzalez Bravo como responsable de
la operación tecnológica, muestran `Tamaulipas, México` como ubicación general y
ofrecen `ederjgb94@gmail.com` para solicitudes ARCO, siguiendo el patrón del
sitio de Unibus. Antes de publicar, confirmar el canal de atención, el domicilio
legal exigido, la política de conservación y el texto con asesoría jurídica.

## Capturas

Las imágenes de la landing muestran widgets reales de Flutter con datos
ficticios. Las capturas de alumnos se generan desde `HomeScreen` y se guardan en
`assets/alumnos-*.png`:

```bash
cd app-alumno
flutter test --no-pub --dart-define=CAPTURE_LANDING_SCREENSHOTS=true \
  --update-goldens test/landing_capture_test.dart
```

Las capturas docentes se generan desde la pantalla real `GruposPage`; la
segunda captura despliega las tarjetas:

```bash
cd app-profesor
flutter test --no-pub --dart-define=CAPTURE_LANDING_SCREENSHOTS=true \
  --update-goldens test/landing_capture_test.dart
```

Los dos comandos actualizan directamente los PNG de `landing-alumnos/assets/`.
Las capturas de alumnos se exportan a 1440 × 2560 px y las de docentes a
1080 × 2340 px.

## Construcción

Desde la raíz:

```bash
docker build -t presencia-landing landing-alumnos
```

El contenedor escucha en el puerto `8080` y expone `/health/ready`.
Para Dokploy, usa `landing-alumnos` como directorio de contexto y
`Dockerfile` como ruta del archivo de construcción.
