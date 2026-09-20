# OneDrive Monitor (v1.2.0)

DankMaterialShell widget for [onedriver](https://github.com/jstaf/onedriver).

A native, lightweight monitor and manager for Microsoft OneDrive mounts on Linux with full multi-account support and desktop integration.

## Features

- **Soporte Multicuenta Completo**:
  - Detección y visualización simultánea de múltiples cuentas (Personal y Empresa/Educación con detección precisa de tipo vía metadatos locales y distintivos visuales).
  - Integración con el gestor oficial `onedriver-launcher` para añadir y vincular nuevas cuentas en un clic.
  - Acciones por cuenta: Montar/Desmontar, Reiniciar, Abrir carpeta, Alternar autoinicio con el sistema (`enable`/`disable`), Vaciar caché local de archivos y Desvincular cuenta (con confirmación de seguridad y comprobaciones de desmontaje seguro).
  - Acciones por lote: Botones "Montar todas" y "Desmontar todas" en la cabecera cuando hay más de una cuenta.

- **Integración con Nautilus (Gestor de Archivos)**:
  - Emblemas visuales en tiempo real para indicar estado de sincronización:
    - `onedrive-custom-synced`: Archivos/carpetas descargados en local.
    - `onedrive-custom-cloud`: Archivos/carpetas disponibles sólo en la nube.
    - `onedrive-custom-syncing`: Archivos/carpetas en proceso de descarga o sincronización activa.
  - La extensión solo marca un archivo como descargado cuando la base de datos de onedriver
    está lista y su ID coincide con un archivo real de la caché; durante la carga inicial el
    estado queda sin clasificar para evitar falsos positivos al entrar por primera vez en una carpeta.
  - Menú contextual inteligente en Nautilus:
    - "OneDrive: Liberar espacio local" para archivos/carpetas ya sincronizados.
    - "OneDrive: Descargar en este equipo" para archivos/carpetas en la nube (soporte para carpetas con estado mixto).
    - Scripts de fallback compatibles con `nautilus-scripts`.

- **Rendimiento e I/O Optimizado**:
  - Consulta única y eficiente de propiedades `systemctl` y logs de `journalctl`.
  - Caché de metadatos en `$XDG_RUNTIME_DIR/onedriver_dms` para entornos multiusuario.
  - Límite de caducidad forzado (TTL) para recálculo de espacio de disco mediante `mtime`.
  - Opción `--no-cache` para omitir lecturas de disco cuando la visualización de almacenamiento está desactivada.
  - Temporizador *watchdog* para prevenir bloqueos en la interfaz QML durante el sondeo.
  - Prevención de interbloqueos (*deadlocks*) con adquisición ordenada de bloqueos concurrentes por punto de montaje.

- **Integración con DankMaterialShell**:
  - Pastilla para barra superior en orientaciones horizontal y vertical con icono dinámico según el estado global (`cloud_done`, `cloud_sync`, `sync_problem`, `cloud_off`).
  - Mosaico en el Centro de Control (`ccWidget`) para alternar estado con un toque e icono reactivo.
  - Notificaciones nativas mediante `ToastService` ante desconexiones, errores o reconexiones.
  - Historial de actividad de subidas y de descargas iniciadas explícitamente desde
    Nautilus. Las lecturas automáticas para miniaturas, tipo MIME o indexado no se
    presentan como descargas del usuario.
  - Cada descarga manual ocupa una única línea: «Descargando» se reemplaza por el
    resultado verificado («Descargado», «Disponible sin conexión» o error), sin
    duplicar el historial.
  - Carga síncrona optimizada al iniciar la shell sin bloqueos ni retrasos.
  - Diagnóstico completo copiable al portapapeles con un clic.

- **Ajustes Modernos (`Settings.qml`)**:
  - Estructurado con tarjetas nativas `SettingsCard` de DMS.
  - Configuración del intervalo de sondeo (2s a 30s), visualización de caché/cuota y montajes detenidos.
  - Interruptor para habilitar/deshabilitar la integración con Nautilus.
  - Control de notificaciones emergentes de estado.
  - Atajos para abrir el gestor de cuentas o el directorio de caché personalizado.

- **Comandos IPC (`dms ipc call onedriver <función>`)**:
  - `status`: Estado JSON del plugin y montajes.
  - `popout`: Abre el menú desplegable del widget.
  - `refresh`: Fuerza la actualización inmediata del estado.
  - `toggle`: Conmuta el estado de la cuenta principal.
  - `toggleAccount <encoded>`: Conmuta una cuenta concreta.
  - `restart`: Reinicia el servicio de la cuenta principal.
  - `restartAccount <encoded>`: Reinicia una cuenta concreta.
  - `mountAll`: Monta todas las cuentas configuradas.
  - `unmountAll`: Desmonta todas las cuentas activas.
  - `launcher`: Lanza `onedriver-launcher` con variables de entorno para Wayland.
  - `diagnostics`: Copia el informe de diagnóstico al portapapeles.

## Instalación y recarga

### Instalación para cualquier usuario

Descarga o clona la carpeta del proyecto y, desde ella, ejecuta como usuario normal:

```bash
./install.sh
```

El instalador comprueba las dependencias antes de copiar archivos y deja el plugin en
`~/.config/DankMaterialShell/plugins/OneDriveMonitor`. Para actualizar una instalación
existente sin perder una copia recuperable, usa `./install.sh --upgrade`. Para comprobar
un equipo antes de instalar, usa `./install.sh --check`.

Para retirarlo, ejecuta `./uninstall.sh`; mueve el plugin a una copia fechada y elimina
la integración que este plugin añadió a Nautilus.

### Requisitos

El equipo debe tener DankMaterialShell 1.6 o superior, onedriver, Nautilus con
`nautilus-python`/PyGObject y FUSE3 (`fusermount3`). En CachyOS actualizado se
instalan mediante el gestor de paquetes habitual. Al cargar el widget, la
integración de Nautilus se instala automáticamente y Nautilus solo se reinicia si
hay archivos nuevos o actualizados.

La cuenta de Microsoft se autoriza una vez en cada equipo desde el botón de
cuentas del widget; las credenciales no se copian entre ordenadores.

El widget se encuentra en:
```text
~/.config/DankMaterialShell/plugins/OneDriveMonitor/
```

Para recargar el plugin o reiniciar DankMaterialShell:
```bash
dms restart
```
O recarga en caliente de plugins:
```bash
dms ipc call plugins reload onedriverMonitor
```
