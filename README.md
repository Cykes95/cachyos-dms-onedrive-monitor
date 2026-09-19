# OneDrive Monitor (v0.2.0)

DankMaterialShell widget for [onedriver](https://github.com/jstaf/onedriver).

A native, lightweight monitor and manager for Microsoft OneDrive mounts on Linux with full multi-account support.

## Features

- **Soporte Multicuenta Completo**:
  - Detección y visualización simultánea de múltiples cuentas (Personal y Empresa/Educación con distintivos visuales).
  - Integración con el gestor oficial `onedriver-launcher` para añadir y vincular nuevas cuentas en un clic.
  - Acciones por cuenta: Montar/Desmontar, Reiniciar, Abrir carpeta, Alternar autoinicio con el sistema (`enable`/`disable`), Vaciar caché local de archivos y Desvincular cuenta (con confirmación de seguridad).
  - Acciones por lote: Botones "Montar todas" y "Desmontar todas" en la cabecera cuando hay más de una cuenta.
- **Rendimiento e I/O Optimizado**:
  - Cálculo de tamaño de caché optimizado con caché temporal de 30s para evitar saturación de E/S de disco.
  - Consulta de logs ligera con límite de líneas en `journalctl`.
  - Descarte automático de unidades fantasma o huérfanas de systemd.
- **Integración con DankMaterialShell**:
  - Pastilla para barra superior en orientaciones horizontal y vertical con recuento activo.
  - Mosaico en el Centro de Control (`ccWidget`) para alternar estado con un toque.
  - Notificaciones nativas mediante `ToastService` ante desconexiones, errores o reconexiones.
  - Historial de actividad de subida/descarga de la sesión actual.
  - Diagnóstico completo copiable al portapapeles con un clic.
- **Ajustes Modernos (`Settings.qml`)**:
  - Estructurado con tarjetas nativas `SettingsCard` de DMS.
  - Configuración del intervalo de sondeo (2s a 30s), visualización de caché/cuota y montajes detenidos.
  - Control de notificaciones emergentes de estado.
  - Atajos para abrir el gestor de cuentas o el directorio de caché.
- **Comandos IPC (`dms ipc call onedriver <función>`)**:
  - `status`: Estado JSON del plugin y montajes.
  - `popout`: Abre el menú desplegable del widget.
  - `refresh`: Fuerza la actualización inmediata del estado.
  - `toggle`: Conmuta el estado de la cuenta principal o de todas.
  - `restart`: Reinicia el servicio de la cuenta principal.
  - `mountAll`: Monta todas las cuentas configuradas.
  - `unmountAll`: Desmonta todas las cuentas activas.
  - `launcher`: Lanza `onedriver-launcher` con variables de entorno para Wayland.
  - `diagnostics`: Copia el informe de diagnóstico al portapapeles.

## Instalación y recarga

El widget se encuentra en:
```text
~/.config/DankMaterialShell/plugins/OneDriveMonitor/
```

Para recargar el plugin en DankMaterialShell:
```bash
dms ipc plugin-scan rescan onedriverMonitor
dms ipc plugins reload
```
