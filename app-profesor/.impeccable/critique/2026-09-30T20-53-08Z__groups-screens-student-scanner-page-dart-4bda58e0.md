---
target: Mejoras sugeridas para detectar alumnos sin modificar la estructura
total_score: 29
max_score: 40
na_heuristics:
p0_count: 0
p1_count: 0
target_identity: "file:/home/jared/Proyectos/presencia/app-profesor/lib/features/groups/screens/student_scanner_page.dart"
target_fingerprint: "sha256:e6cc15690b98dbe179c6faa187dde29c1629e806a25581c23c856e63b93830f0"
target_path: /home/jared/Proyectos/presencia/app-profesor/lib/features/groups/screens/student_scanner_page.dart
timestamp: 2026-09-30T20-53-08Z
slug: groups-screens-student-scanner-page-dart-4bda58e0
closed: true
---
Method: dual-agent (A: /root/impeccable_design_review · B: /root/impeccable_evidence_review)

Revisión de la vista de detectar alumnos con Impeccable. Alcance: sugerir mejoras de acabado conservando el orden, las posiciones, la distribución interna de las tarjetas y el comportamiento. No se modificó código.

La estructura tiene buena base: la secuencia de escaneo, contexto, contador, actividad, resultados y pausa se entiende rápidamente. La identidad UAT se reconoce en el naranja institucional y los neutros cálidos. La mayor oportunidad es mejorar legibilidad y jerarquía, manteniendo esta identidad.

Valoración orientativa de Nielsen a partir de captura y código, sin prueba interactiva completa:

| Heurística | Puntuación | Observación |
|---|---:|---|
| Estado del sistema | 3/4 | Título, contador y puntos claros; actividad continua tras completar el contador. |
| Lenguaje familiar | 3/4 | Contexto docente claro; pausar también vuelve a la pantalla anterior. |
| Control y libertad | 3/4 | Acción inferior visible y salida mediante volver. |
| Consistencia | 3/4 | Tarjetas coherentes; verde de éxito definido separadamente del tema. |
| Prevención de errores | 3/4 | La pausa evita pulsaciones repetidas; registros fuera de esta revisión. |
| Reconocimiento | 4/4 | Nombre, matrícula y confirmación visibles. |
| Eficiencia | 3/4 | Detección automática y lista desplazable. |
| Estética y minimalismo | 3/4 | Algunas confirmaciones y adornos compiten por atención. |
| Recuperación de errores | 2/4 | Orientación sobre Bluetooth y permisos, poco específica. |
| Ayuda contextual | 2/4 | Estados vacío y no disponible explican el siguiente paso. |
| Total | 29/40 | Buena base. |

La carga cognitiva es baja: una acción principal, registros agrupados y contexto persistente. No hay decisiones con más de cuatro alternativas visibles. La confirmación de asistencia tranquiliza; el botón rojo de pausa tiene más intensidad visual de la que necesita una salida normal. Las tarjetas ya tienen sombras discretas y no muestran recortes en la captura de 390 × 844.

Prioridades:

1. [P2] Mejorar contraste del texto verde en modo claro. Asistencia registrada usa #1F9D63 sobre #FBF8F3, con contraste 3.27:1; el contador tiene aproximadamente 2.71:1 sobre su fondo compuesto de referencia. Usar un verde más oscuro para los textos y conservar los fondos suaves. #167A4C ofrece 5.05:1 sobre la tarjeta, pero el contador debe verificarse con su propio fondo. Mantener un verde luminoso apropiado en modo oscuro. Comando sugerido: $impeccable colorize.
2. [P2] Mejorar el contraste del botón activo. Blanco sobre #D64545 alcanza 4.38:1. #CB3D3D conserva el rojo y alcanza aproximadamente 4.91:1. Mantener forma, dimensiones e icono. Como dirección alternativa, un neutro oscuro podría comunicar pausa con menos urgencia; depende de la intención del usuario. Comando sugerido: $impeccable polish.
3. [P3] Afinar jerarquía tipográfica y confirmaciones. Conservar el nombre a 17 y peso fuerte; bajar Asistencia registrada de w800 a w600 y suavizar el fondo del check derecho de 12% a 8–10%. Mantener ambos checks y su ubicación. Comando sugerido: $impeccable typeset.
4. [P3] Suavizar halo y entrada de tarjetas. Reducir la opacidad del halo naranja del icono de 0.30 a aproximadamente 0.20. La fuente tiene entradas de 420 ms con un desplazamiento horizontal amplio: proponer 220–280 ms y recorrido corto conservando la animación. Los puntos siguen separados y en la misma posición. La sensación del movimiento se debe validar en ejecución: la captura solo muestra un instante. Comando sugerido: $impeccable animate.

La referencia de contraste para texto pequeño es 4.5:1: https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html. Los valores se calcularon con los colores de fuente; no constituyen una certificación completa de accesibilidad.

Personas:

- Baja visión: el verde pequeño es la principal dificultad; la matrícula ofrece 6.37:1 y los nombres tienen buena legibilidad.
- Primera vez: materia y grupo dan contexto. Pausar escaneo también cierra la pantalla; Pausar y volver podría explicarlo, si se desea afinar la etiqueta.
- Uso móvil con interrupciones: el botón inferior de 58 y los datos completos facilitan retomar la tarea. Los avatares no necesitan más énfasis que los nombres.

Observaciones menores: las sombras, los bordes y la separación actual de los puntos ya funcionan. Mantener márgenes generales, altura de tarjetas, estructura y orden. El aviso naranja de error presenta contraste bajo según el código, pero no aparece en esta captura: tratarlo en una revisión de estados posterior. El estado deshabilitado de pausa no debe evaluarse como un botón activo. Nombres largos, texto ampliado y modo oscuro no se comprobaron visualmente en esta revisión.

El detector se ejecutó por Assessment B, pero su salida se perdió en un resultado truncado; el padre repitió únicamente ese comando conforme al procedimiento de recuperación. La salida recuperada fue [], código 0. El escaneo no identificó reglas, ubicaciones ni hallazgos automáticos. Esto no valida la renderización ni la semántica nativa de Flutter: los problemas de contraste proceden de la comprobación manual independiente. No se establecieron falsos positivos.

Preguntas para una siguiente pasada: ¿conservar el rojo más oscuro o usar un botón neutro? ¿Priorizar solo los dos ajustes de legibilidad o aplicar los cuatro ajustes de acabado?
