# Manual Test - Login Flow

## Credenciales de prueba

Obtén una cuenta temporal mediante el canal seguro del equipo. Nunca escribas
correos personales ni contraseñas reales en este archivo o en los logs.

## Escenarios de Prueba

### ✅ Escenario 1: Login sin JWT (Primera vez)
**Pasos:**
1. Limpiar storage: Eliminar app y reinstalar o usar comando para limpiar Hive
2. Abrir app
3. Debería mostrar pantalla de login (no splash infinito)
4. Hacer clic en campo de email
5. Escribir el correo de la cuenta temporal
6. Hacer clic en campo de contraseña
7. Escribir la contraseña recibida por el canal seguro
8. Hacer clic en "Iniciar Sesión"

**Resultado Esperado:**
- ✅ Campos de texto responden al clic
- ✅ Botón "Iniciar Sesión" se activa cuando ambos campos tienen texto
- ✅ Muestra "Verificando credenciales..."
- ✅ Login exitoso
- ✅ Navega a pantalla de grupos
- ✅ Muestra grupos del profesor
- ✅ JWT se guarda en Hive

### ✅ Escenario 2: Login con JWT guardado (Auto-login)
**Pasos:**
1. Después de completar Escenario 1
2. Cerrar app (no logout)
3. Abrir app nuevamente

**Resultado Esperado:**
- ✅ Muestra splash screen con "Cargando..."
- ✅ Verifica JWT almacenado
- ✅ Si token es válido, auto-login
- ✅ Navega directamente a pantalla de grupos (sin pasar por login)
- ✅ Muestra grupos del profesor

### ✅ Escenario 3: Logout y re-login
**Pasos:**
1. Después de estar autenticado
2. Hacer clic en botón de logout (icono en header)
3. Confirmar logout
4. Debería volver a pantalla de login
5. Volver a hacer login con las credenciales

**Resultado Esperado:**
- ✅ JWT se limpia del storage
- ✅ Navega a login page
- ✅ Puede hacer login nuevamente
- ✅ Nuevo JWT se guarda

### 🔧 Comandos de Debug

#### Limpiar storage de Hive (Flutter)
```bash
# En el emulador/dispositivo, limpiar datos de la app
# Android
adb shell pm clear com.presencia.app_profesor

# iOS
# Settings > General > iPhone Storage > App > Delete App
```

#### Ver logs en tiempo real
```bash
flutter logs
```

#### Hot restart (limpiar estado)
```bash
# En VS Code: Ctrl+Shift+F5 o Cmd+Shift+F5
# En terminal:
flutter run --hot
# Luego presionar: R (mayúscula)
```

## Problemas Conocidos y Soluciones

### ❌ Problema: Campos no responden al clic
**Causa:** Widget tree no se está reconstruyendo correctamente
**Solución:** Hot restart completo

### ❌ Problema: Splash screen infinito
**Causa:** Error en checkStoredSession o router redirect loop
**Solución:** Ver logs con `flutter logs`, verificar errores en checkStoredSession

### ❌ Problema: Login exitoso pero no navega
**Causa:** Router redirect conflicto
**Solución:** Verificar routerProvider y redirect logic

## Logs Esperados

### Sin JWT (primera vez):
```
[INFO] Hive initialized
[INFO] Auth storage initialized
[INFO] App initialization completed
[INFO] Iniciando verificación de sesión almacenada
[INFO] No hay sesión almacenada
[INFO] Verificación de sesión completada
[INFO] Iniciando login del profesor
[INFO] Login exitoso para: [Nombre del profesor]
[INFO] Cargando clases del profesor: [ID]
[INFO] Clases cargadas exitosamente: 6 clases
```

### Con JWT (auto-login):
```
[INFO] Hive initialized
[INFO] Auth storage initialized
[INFO] App initialization completed
[INFO] Iniciando verificación de sesión almacenada
[INFO] Verificando sesión almacenada
[INFO] Sesión válida encontrada para: [Nombre del profesor]
[INFO] Cargando clases del profesor: [ID]
[INFO] Clases cargadas exitosamente: 6 clases
[INFO] Verificación de sesión completada
```
