# Recursos para Google Play · Presencia: Alumnos

Estos archivos muestran la interfaz Flutter actual con datos ficticios de una
cuenta estudiantil. Las capturas se renderizan directamente desde `HomeScreen`.

| Archivo | Uso | Dimensiones |
| --- | --- | --- |
| `feature-graphic-1024x500.png` | Gráfico de funciones | 1024 × 500 px |
| `01-inicio-1440x2560.png` | Captura de Inicio | 1440 × 2560 px |
| `02-horario-1440x2560.png` | Captura de Horario | 1440 × 2560 px |
| `03-historial-1440x2560.png` | Captura de Historial | 1440 × 2560 px |
| `04-perfil-1440x2560.png` | Captura de Perfil | 1440 × 2560 px |

Todos los PNG de entrega son RGB, sin transparencia. Las capturas son 9:16 y
están por debajo de 8 MB; el gráfico de funciones está por debajo de 15 MB.

## Regenerar

Desde la raíz del proyecto:

```bash
flutter test --no-pub --dart-define=CAPTURE_PLAY_SCREENSHOTS=true --update-goldens test/play_store_capture_test.dart
python3 tool/generate_play_feature_graphic.py
```

El segundo comando requiere Inkscape y Pillow. `feature-graphic.svg` es la
fuente editable del diseño y utiliza la captura de Inicio recién generada.

## Texto alternativo sugerido

- Gráfico de funciones: "Presencia para alumnos: horario y asistencia en un solo lugar, con vista de la agenda diaria".
- Inicio: "Agenda diaria con clases, asistencias registradas y botón para registrar asistencia".
- Horario: "Horario semanal con clases por día y estado de asistencia".
- Historial: "Historial de asistencias registradas por clase y fecha".
- Perfil: "Perfil estudiantil con programa, ciclo y datos académicos".
