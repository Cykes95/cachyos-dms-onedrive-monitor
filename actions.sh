#!/bin/sh
umask 077

# Action helper for OneDrive Monitor DMS plugin
# Manages systemd units, caching, and onedriver lifecycle

home_dir=${HOME:-$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)}
config_file="${XDG_CONFIG_HOME:-$home_dir/.config}/onedriver/config.yml"
cache_dir="${XDG_CACHE_HOME:-$home_dir/.cache}/onedriver"
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    runtime_dir="$XDG_RUNTIME_DIR/onedriver_dms"
else
    runtime_dir="${TMPDIR:-/tmp}/onedriver_dms_${UID:-$(id -u)}"
fi
mkdir -p "$runtime_dir" 2>/dev/null
chmod 700 "$runtime_dir" 2>/dev/null || true

if [ -r "$config_file" ]; then
    configured_cache=$(sed -n 's/^[[:space:]]*cacheDir:[[:space:]]*//p' "$config_file" | head -n 1)
    configured_cache=$(printf '%s' "$configured_cache" | sed 's/[[:space:]]*#.*//')
    configured_cache=$(printf '%s' "$configured_cache" | sed -e 's/^[[:space:]]*["'\'']//' -e 's/["'\''][[:space:]]*$//')
    case "$configured_cache" in
        "~") cache_dir="$home_dir" ;;
        "~/"*) cache_dir="$home_dir/${configured_cache#\~/}" ;;
        /*) cache_dir="$configured_cache" ;;
    esac
fi

locks_dir="${XDG_RUNTIME_DIR:-/run/user/${UID:-$(id -u)}}/onedrive_locks"
mkdir -p "$locks_dir" 2>/dev/null && chmod 700 "$locks_dir" 2>/dev/null || {
    locks_dir="/tmp/onedriver_locks_${UID:-$(id -u)}"
    mkdir -p "$locks_dir" 2>/dev/null && chmod 700 "$locks_dir" 2>/dev/null || true
}

stop_nautilus() {
    pgrep -x nautilus >/dev/null 2>&1 || return 0
    pkill -TERM -x nautilus 2>/dev/null || true
    tries=0
    while pgrep -x nautilus >/dev/null 2>&1 && [ "$tries" -lt 10 ]; do
        sleep 0.2
        tries=$((tries + 1))
    done
    # A wedged Nautilus may not answer `nautilus -q`. This helper is used only
    # for an explicit integration restart, so do not leave the action blocked.
    if pgrep -x nautilus >/dev/null 2>&1; then
        pkill -KILL -x nautilus 2>/dev/null || true
    fi
}

acquire_account_lock() {
    enc="$1"
    lfile="$locks_dir/${enc}.lock"
    exec 9>"$lfile" 2>/dev/null || return 1
    if ! flock -x -w 5 9 2>/dev/null; then
        exec 9>&- 2>/dev/null || true
        return 1
    fi
    return 0
}

release_account_lock() {
    flock -u 9 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
}

trap_cleanup() {
    release_account_lock
    exit 1
}

trap trap_cleanup INT TERM HUP
trap release_account_lock EXIT

normalize_unit() {
    val="$1"
    case "$val" in
        onedriver@*.service) echo "$val" ;;
        onedriver@*) echo "${val}.service" ;;
        *) echo "onedriver@${val}.service" ;;
    esac
}

normalize_encoded() {
    val="$1"
    case "$val" in
        onedriver@*.service)
            val=${val#onedriver@}
            echo "${val%.service}"
            ;;
        onedriver@*)
            echo "${val#onedriver@}"
            ;;
        *)
            echo "$val"
            ;;
    esac
}

is_mounted() {
    mp="$1"
    [ -n "$mp" ] || return 1
    if command -v findmnt >/dev/null 2>&1; then
        findmnt -rn -M "$mp" >/dev/null 2>&1
    elif [ -r /proc/mounts ]; then
        grep -Fqs " $mp " /proc/mounts
    else
        return 1
    fi
}

unmount_safely() {
    mp="$1"
    [ -n "$mp" ] || return 0
    fusermount_bin=$(command -v fusermount3 || command -v fusermount || true)
    [ -n "$fusermount_bin" ] || return 0
    if is_mounted "$mp"; then
        # 1. Intentar desmontaje limpio (-u)
        if ! "$fusermount_bin" -u "$mp" 2>/dev/null; then
            # 2. Si falla por ocupado (Nautilus/archivos abiertos), usar lazy (-uz)
            "$fusermount_bin" -uz "$mp" 2>/dev/null || true
        fi
        for _ in 1 2 3 4 5; do
            if ! is_mounted "$mp"; then break; fi
            sleep 0.2
        done
    fi
}

wait_unit_stopped() {
    u="$1"
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        st=$(systemctl --user is-active "$u" 2>/dev/null || true)
        case "$st" in
            inactive|dead|failed) return 0 ;;
            *) sleep 0.2 ;;
        esac
    done
    return 1
}

validate_encoded() {
    val="$1"
    case "$val" in
        .|..|*/*|*..*|''|*[[:space:]]*)
            echo "Error: identificador de cuenta no válido: $val" >&2
            exit 1
            ;;
    esac
    target_dir="$cache_dir/$val"
    real_cache=$(realpath -m "$cache_dir" 2>/dev/null || realpath "$cache_dir" 2>/dev/null || echo "$cache_dir")
    real_target=$(realpath -m "$target_dir" 2>/dev/null || realpath "$target_dir" 2>/dev/null || echo "$target_dir")
    case "$real_target" in
        "$real_cache"/*) ;;
        *)
            echo "Error: ruta de cuenta fuera del directorio de caché: $val" >&2
            exit 1
            ;;
    esac
    if [ "$real_target" = "$real_cache" ] || [ "$real_target" = "/" ] || [ -z "$val" ]; then
        echo "Error: ruta de cuenta insegura o no permitida: $val" >&2
        exit 1
    fi
}

ensure_systemd_override() {
    fusermount_bin=$(command -v fusermount3 || command -v fusermount || echo /usr/bin/fusermount3)
    systemd_override_dir="${XDG_CONFIG_HOME:-$home_dir/.config}/systemd/user/onedriver@.service.d"
    override_file="$systemd_override_dir/onedriver-monitor.conf"
    # Only remove legacy override.conf if it was created by DMS OneDriveMonitor
    if [ -f "$systemd_override_dir/override.conf" ] && grep -Fqs "Created by DMS OneDriveMonitor" "$systemd_override_dir/override.conf"; then
        rm -f "$systemd_override_dir/override.conf" 2>/dev/null || true
    fi
    needs_reload=0
    if [ ! -f "$override_file" ] || ! grep -Fqs -- "-uz" "$override_file"; then
        mkdir -p "$systemd_override_dir" 2>/dev/null || true
        printf '# Created by DMS OneDriveMonitor\n[Service]\nExecStopPost=\nExecStopPost=-%s -uz /%%I\n' "$fusermount_bin" > "$override_file" 2>/dev/null || true
        needs_reload=1
    fi
    if [ "$needs_reload" -eq 1 ]; then
        systemctl --user daemon-reload 2>/dev/null || true
    fi
}

check_nautilus_prerequisites() {
    missing=""

    for binary in onedriver systemctl findmnt python3 nautilus; do
        if ! command -v "$binary" >/dev/null 2>&1; then
            missing="${missing}${missing:+, }$binary"
        fi
    done

    if ! command -v fusermount3 >/dev/null 2>&1 && ! command -v fusermount >/dev/null 2>&1; then
        missing="${missing}${missing:+, }fusermount3"
    fi

    # The extension imports the 4.1 API explicitly; accepting only 4.0 here
    # would create an apparently successful installation with no emblems.
    if ! python3 -c "import gi; gi.require_version('Nautilus', '4.1'); from gi.repository import Nautilus" >/dev/null 2>&1; then
        missing="${missing}${missing:+, }nautilus-python (API 4.1)"
    fi

    if [ -n "$missing" ]; then
        echo "Error: faltan requisitos para la integración de Nautilus: $missing" >&2
        echo "Instale onedriver, nautilus-python/PyGObject y FUSE3 con el gestor de paquetes antes de continuar." >&2
        return 1
    fi
    return 0
}

cmd="$1"
shift 1 2>/dev/null || true

case "$cmd" in
    start)
        [ -n "$1" ] || { echo "Error: falta el identificador o nombre de unidad" >&2; exit 1; }
        encoded=$(normalize_encoded "$1")
        validate_encoded "$encoded"
        if ! acquire_account_lock "$encoded"; then
            echo "Error: la cuenta $encoded está ocupada por otra operación" >&2
            exit 1
        fi
        ensure_systemd_override
        unit="onedriver@${encoded}.service"
        if out=$(systemctl --user start "$unit" 2>&1); then
            echo "started $unit"
            exit 0
        else
            echo "Error al iniciar $unit: $out" >&2
            exit 1
        fi
        ;;
    stop)
        [ -n "$1" ] || { echo "Error: falta el identificador o nombre de unidad" >&2; exit 1; }
        encoded=$(normalize_encoded "$1")
        validate_encoded "$encoded"
        if ! acquire_account_lock "$encoded"; then
            echo "Error: la cuenta $encoded está ocupada por otra operación" >&2
            exit 1
        fi
        unit="onedriver@${encoded}.service"
        mountpoint=$(systemd-escape --unescape --path "$encoded" 2>/dev/null || true)
        if out=$(systemctl --user stop "$unit" 2>&1); then
            if ! wait_unit_stopped "$unit"; then
                echo "Advertencia: $unit no terminó de detenerse en el tiempo esperado" >&2
            fi
            unmount_safely "$mountpoint"
            echo "stopped $unit"
            exit 0
        else
            echo "Error al detener $unit: $out" >&2
            exit 1
        fi
        ;;
    restart)
        [ -n "$1" ] || { echo "Error: falta el identificador o nombre de unidad" >&2; exit 1; }
        encoded=$(normalize_encoded "$1")
        validate_encoded "$encoded"
        if ! acquire_account_lock "$encoded"; then
            echo "Error: la cuenta $encoded está ocupada por otra operación" >&2
            exit 1
        fi
        ensure_systemd_override
        unit="onedriver@${encoded}.service"
        if out=$(systemctl --user restart "$unit" 2>&1); then
            echo "restarted $unit"
            exit 0
        else
            echo "Error al reiniciar $unit: $out" >&2
            exit 1
        fi
        ;;
    enable)
        [ -n "$1" ] || { echo "Error: falta el identificador o nombre de unidad" >&2; exit 1; }
        encoded=$(normalize_encoded "$1")
        validate_encoded "$encoded"
        if ! acquire_account_lock "$encoded"; then
            echo "Error: la cuenta $encoded está ocupada por otra operación" >&2
            exit 1
        fi
        unit="onedriver@${encoded}.service"
        if out=$(systemctl --user enable "$unit" 2>&1); then
            echo "enabled $unit"
            exit 0
        else
            echo "Error al habilitar inicio automático de $unit: $out" >&2
            exit 1
        fi
        ;;
    disable)
        [ -n "$1" ] || { echo "Error: falta el identificador o nombre de unidad" >&2; exit 1; }
        encoded=$(normalize_encoded "$1")
        validate_encoded "$encoded"
        if ! acquire_account_lock "$encoded"; then
            echo "Error: la cuenta $encoded está ocupada por otra operación" >&2
            exit 1
        fi
        unit="onedriver@${encoded}.service"
        if out=$(systemctl --user disable "$unit" 2>&1); then
            echo "disabled $unit"
            exit 0
        else
            echo "Error al deshabilitar inicio automático de $unit: $out" >&2
            exit 1
        fi
        ;;
    toggle-autostart)
        [ -n "$1" ] || { echo "Error: falta el identificador o nombre de unidad" >&2; exit 1; }
        encoded=$(normalize_encoded "$1")
        validate_encoded "$encoded"
        if ! acquire_account_lock "$encoded"; then
            echo "Error: la cuenta $encoded está ocupada por otra operación" >&2
            exit 1
        fi
        unit="onedriver@${encoded}.service"
        state=$(systemctl --user is-enabled "$unit" 2>/dev/null || true)
        case "$state" in
            enabled*)
                if out=$(systemctl --user disable "$unit" 2>&1); then
                    echo "disabled $unit"
                    exit 0
                else
                    echo "Error al desactivar inicio automático: $out" >&2
                    exit 1
                fi
                ;;
            *)
                if out=$(systemctl --user enable "$unit" 2>&1); then
                    echo "enabled $unit"
                    exit 0
                else
                    echo "Error al activar inicio automático: $out" >&2
                    exit 1
                fi
                ;;
        esac
        ;;
    mount-all)
        ensure_systemd_override
        failed=0
        failed_units=""
        wants_dir="${XDG_CONFIG_HOME:-$home_dir/.config}/systemd/user/default.target.wants"
        units=$(
            {
                if [ -d "$wants_dir" ]; then
                    find "$wants_dir" -maxdepth 1 -name 'onedriver@*.service' 2>/dev/null | sed -n 's/.*\(onedriver@.*\.service\)$/\1/p'
                fi
                if [ -d "$cache_dir" ]; then
                    for d in "$cache_dir"/*; do
                        if [ -d "$d" ] && [ -f "$d/auth_tokens.json" ]; then
                            enc=$(basename "$d")
                            echo "onedriver@${enc}.service"
                        fi
                    done
                fi
            } | sort -u
        )
        for u in $units; do
            u_enc=$(normalize_encoded "$u")
            if ! acquire_account_lock "$u_enc"; then
                failed=1
                failed_units="$failed_units $u(busy)"
                continue
            fi
            if ! systemctl --user start "$u" 2>&1; then
                failed=1
                failed_units="$failed_units $u"
            fi
            release_account_lock
        done
        if [ "$failed" -eq 1 ]; then
            echo "Error al montar unidades:$failed_units" >&2
            exit 1
        fi
        echo "mount-all completed"
        exit 0
        ;;
    unmount-all)
        failed=0
        failed_units=""
        units=$(systemctl --user list-units --all --no-legend --no-pager 'onedriver@*.service' 2>/dev/null \
            | awk '$1 ~ /^onedriver@/ {print $1}')
        for u in $units; do
            u_enc=$(normalize_encoded "$u")
            if ! acquire_account_lock "$u_enc"; then
                failed=1
                failed_units="$failed_units $u(busy)"
                continue
            fi
            if ! systemctl --user stop "$u" 2>&1; then
                failed=1
                failed_units="$failed_units $u"
            fi
            if ! wait_unit_stopped "$u"; then
                failed=1
                failed_units="$failed_units $u(timeout)"
            fi
            mp=$(systemd-escape --unescape --path "$u_enc" 2>/dev/null || true)
            unmount_safely "$mp"
            if [ -n "$mp" ] && is_mounted "$mp"; then
                failed=1
                failed_units="$failed_units $u(fuse_busy)"
            fi
            release_account_lock
        done
        if [ "$failed" -eq 1 ]; then
            echo "Error al desmontar unidades:$failed_units" >&2
            exit 1
        fi
        echo "unmount-all completed"
        exit 0
        ;;
    clear-cache)
        encoded=$(normalize_encoded "$1")
        validate_encoded "$encoded"

        # 1. Adquirir bloqueo exclusivo ANTES de alterar el servicio o el disco
        if ! acquire_account_lock "$encoded"; then
            echo "Error: la cuenta está ocupada por otra operación (Nautilus)" >&2
            exit 1
        fi
        trap release_account_lock EXIT INT TERM

        unit="onedriver@${encoded}.service"
        mountpoint=$(systemd-escape --unescape --path "$encoded" 2>/dev/null || true)

        # 2. Tratar estados activos e intermedios de systemd
        was_active=0
        state=$(systemctl --user is-active "$unit" 2>/dev/null || true)
        case "$state" in
            active|activating|reloading)
                was_active=1
                systemctl --user stop "$unit" 2>/dev/null || true
                if ! wait_unit_stopped "$unit"; then
                    echo "Error: no se pudo detener $unit antes de vaciar la caché" >&2
                    exit 1
                fi
                ;;
            deactivating)
                if ! wait_unit_stopped "$unit"; then
                    echo "Error: la unidad $unit no terminó de detenerse" >&2
                    exit 1
                fi
                ;;
        esac

        # 3. Comprobar que el proceso onedriver esté realmente detenido y no figure en findmnt
        unmount_safely "$mountpoint"
        for _ in 1 2 3 4 5; do
            if [ -n "$mountpoint" ] && is_mounted "$mountpoint"; then
                sleep 0.2
            else
                break
            fi
        done
        if [ -n "$mountpoint" ] && is_mounted "$mountpoint"; then
            echo "Error: el punto de montaje $mountpoint sigue ocupado en findmnt; no se puede vaciar la caché con seguridad" >&2
            if [ "$was_active" -eq 1 ]; then
                systemctl --user start "$unit" 2>/dev/null || true
            fi
            exit 1
        fi

        # 4. Verificar subidas pendientes en onedriver.db antes de purgar
        db_file="$cache_dir/$encoded/onedriver.db"
        core_py="$script_dir/integrations/nautilus/onedrive_core.py"
        if [ ! -f "$core_py" ]; then
            core_py="${XDG_DATA_HOME:-$home_dir/.local/share}/nautilus-python/extensions/onedrive_core.py"
        fi
        if [ ! -f "$core_py" ]; then
            echo "Error: no se encontró onedrive_core.py para verificar la seguridad del vaciado." >&2
            if [ "$was_active" -eq 1 ]; then
                systemctl --user start "$unit" 2>/dev/null || true
            fi
            exit 1
        fi

        if [ -f "$db_file" ]; then
            purge_check_out=$(python3 "$core_py" check-purge "$db_file" 2>&1)
            purge_check_rc=$?
            if [ "$purge_check_rc" -ne 0 ] || [ "$purge_check_out" != "SAFE_TO_PURGE" ]; then
                echo "Error: no es seguro vaciar la caché ($purge_check_out). Se cancela la operación para evitar pérdida de datos." >&2
                if [ "$was_active" -eq 1 ]; then
                    systemctl --user start "$unit" 2>/dev/null || true
                fi
                exit 1
            fi
        fi

        # 5. Purgar ÚNICAMENTE el contenido descargado (content/*), PRESERVANDO onedriver.db
        content_dir="$cache_dir/$encoded/content"
        if [ -d "$content_dir" ]; then
            chmod -R u+w "$content_dir" 2>/dev/null || true
            find "$content_dir" -mindepth 1 -delete 2>/dev/null || \
                find "$content_dir" -mindepth 1 -exec rm -rf {} + 2>/dev/null || \
                rm -rf "$content_dir"/* "$content_dir"/.[!.]* "$content_dir"/..?* 2>/dev/null || true
            if [ "$(ls -A "$content_dir" 2>/dev/null)" ]; then
                echo "Error: no se pudo vaciar completamente el directorio de contenido" >&2
                if [ "$was_active" -eq 1 ]; then
                    systemctl --user start "$unit" 2>/dev/null || true
                fi
                exit 1
            fi
        fi

        # Reset all cached files so monitor immediately recalculates
        rm -f "$runtime_dir"/*_"${encoded}.tmp" /tmp/onedriver_*_"${encoded}.tmp" 2>/dev/null || true

        # 6. Reiniciar el servicio si estaba activo
        if [ "$was_active" -eq 1 ]; then
            systemctl --user reset-failed "$unit" 2>/dev/null || true
            if ! out=$(systemctl --user start "$unit" 2>&1); then
                echo "Advertencia: no se pudo reiniciar $unit tras vaciar la caché: $out" >&2
                exit 1
            fi
        fi
        echo "cache cleared for $encoded"
        exit 0
        ;;
    remove-mount)
        encoded=$(normalize_encoded "$1")
        validate_encoded "$encoded"

        # 1. Adquirir bloqueo exclusivo ANTES de detener o borrar
        if ! acquire_account_lock "$encoded"; then
            echo "Error: la cuenta está ocupada por otra operación (Nautilus)" >&2
            exit 1
        fi
        trap release_account_lock EXIT INT TERM

        unit="onedriver@${encoded}.service"
        mountpoint=$(systemd-escape --unescape --path "$encoded" 2>/dev/null || true)

        systemctl --user stop "$unit" 2>/dev/null || true
        if ! wait_unit_stopped "$unit"; then
            echo "Error: no se pudo detener $unit antes de desvincular" >&2
            exit 1
        fi
        unmount_safely "$mountpoint"
        if [ -n "$mountpoint" ] && is_mounted "$mountpoint"; then
            echo "Error: el punto de montaje $mountpoint sigue ocupado; no se puede desvincular" >&2
            exit 1
        fi

        # 2. Respaldo de seguridad OBLIGATORIO antes de cualquier borrado
        account_dir="$cache_dir/$encoded"
        if [ -d "$account_dir" ]; then
            backup_base="${XDG_DATA_HOME:-$home_dir/.local/share}/onedrive-backup"
            backup_dir="$backup_base/${encoded}_$(date +%Y%m%d_%H%M%S)_$$"

            if ! mkdir -p "$backup_base" 2>/dev/null || [ ! -d "$backup_base" ]; then
                echo "Error: no se pudo crear el directorio de respaldo $backup_base. Operación abortada para proteger los datos." >&2
                exit 1
            fi
            chmod 700 "$backup_base" 2>/dev/null || true

            if ! cp -a "$account_dir" "$backup_dir" 2>/dev/null; then
                rm -rf "$backup_dir" 2>/dev/null || true
                echo "Error: falló la copia de seguridad en $backup_dir. Operación abortada; el directorio original no ha sido modificado." >&2
                exit 1
            fi
            chmod 700 "$backup_dir" 2>/dev/null || true

            if [ -f "$account_dir/auth_tokens.json" ] && [ ! -f "$backup_dir/auth_tokens.json" ]; then
                rm -rf "$backup_dir" 2>/dev/null || true
                echo "Error: verificación del respaldo falló (faltan archivos críticos). Operación abortada; no se eliminó la cuenta." >&2
                exit 1
            fi

            echo "Respaldo de seguridad creado exitosamente en: $backup_dir"
        fi

        if ! systemctl --user disable "$unit" 2>/dev/null; then
            echo "Advertencia: no se pudo deshabilitar inicio automático de $unit" >&2
        fi
        rm -f "${XDG_CONFIG_HOME:-$home_dir/.config}/systemd/user/default.target.wants/$unit" 2>/dev/null || true
        systemctl --user reset-failed "$unit" 2>/dev/null || true
        systemctl --user daemon-reload 2>/dev/null || true
        rm -rf "$cache_dir/$encoded" 2>/dev/null || true
        rm -f "$runtime_dir"/*_"${encoded}.tmp" /tmp/onedriver_*_"${encoded}.tmp" 2>/dev/null || true

        # Comprobar que el directorio de cuenta realmente desapareció
        if [ -d "$cache_dir/$encoded" ]; then
            echo "Error: no se pudo eliminar el directorio de cuenta $cache_dir/$encoded" >&2
            exit 1
        fi

        echo "removed mount $encoded"
        exit 0
        ;;
    open-cache)
        mkdir -p "$cache_dir" 2>/dev/null || true
        xdg-open "$cache_dir" >/dev/null 2>&1 &
        echo "cache opened"
        exit 0
        ;;
    open-launcher)
        if command -v onedriver-launcher >/dev/null 2>&1; then
            env WEBKIT_DISABLE_DMABUF_RENDERER=1 onedriver-launcher >/dev/null 2>&1 &
            echo "launcher opened"
            exit 0
        else
            echo "onedriver-launcher not found" >&2
            exit 1
        fi
        ;;
    install-nautilus)
        check_nautilus_prerequisites || exit 1

        data_home="${XDG_DATA_HOME:-$home_dir/.local/share}"
        config_home="${XDG_CONFIG_HOME:-$home_dir/.config}"
        icons_dir="$data_home/icons/hicolor"
        ext_dir="$data_home/nautilus-python/extensions"
        scripts_dir="$data_home/nautilus/scripts"
        systemd_override_dir="$config_home/systemd/user/onedriver@.service.d"

        mkdir -p "$icons_dir/scalable/emblems" "$icons_dir/48x48/emblems" "$ext_dir" "$scripts_dir" "$systemd_override_dir"

        needs_icon_cache=0
        integration_changed=0

        if [ -d "$script_dir/assets/emblems" ]; then
            for icon in "$script_dir/assets/emblems"/*.svg; do
                [ -f "$icon" ] || continue
                base=$(basename "$icon")
                dest_sc="$icons_dir/scalable/emblems/$base"
                dest_48="$icons_dir/48x48/emblems/$base"
                if [ ! -f "$dest_sc" ] || ! cmp -s "$icon" "$dest_sc"; then
                    cp -f "$icon" "$dest_sc" 2>/dev/null || true
                    needs_icon_cache=1
                    integration_changed=1
                fi
                if [ ! -f "$dest_48" ] || ! cmp -s "$icon" "$dest_48"; then
                    cp -f "$icon" "$dest_48" 2>/dev/null || true
                    needs_icon_cache=1
                    integration_changed=1
                fi
            done
        fi

        src_ext="$script_dir/integrations/nautilus/onedrive_extension.py"
        dest_ext="$ext_dir/onedrive_extension.py"
        if [ -f "$src_ext" ]; then
            if [ ! -f "$dest_ext" ] || ! cmp -s "$src_ext" "$dest_ext"; then
                cp -f "$src_ext" "$dest_ext" 2>/dev/null || true
                integration_changed=1
            fi
        fi

        src_core="$script_dir/integrations/nautilus/onedrive_core.py"
        dest_core="$ext_dir/onedrive_core.py"
        if [ -f "$src_core" ]; then
            if [ ! -f "$dest_core" ] || ! cmp -s "$src_core" "$dest_core"; then
                cp -f "$src_core" "$dest_core" 2>/dev/null || true
                integration_changed=1
            fi
        fi

        for script_name in "OneDrive - Liberar espacio local" "OneDrive - Descargar en este equipo"; do
            src_script="$script_dir/integrations/nautilus/$script_name"
            dest_script="$scripts_dir/$script_name"
            if [ -f "$src_script" ]; then
                if [ ! -f "$dest_script" ] || ! cmp -s "$src_script" "$dest_script"; then
                    cp -f "$src_script" "$dest_script" 2>/dev/null || true
                    chmod +x "$dest_script" 2>/dev/null || true
                    integration_changed=1
                fi
            fi
        done

        if [ "$needs_icon_cache" -eq 1 ] && command -v gtk-update-icon-cache >/dev/null 2>&1; then
            gtk-update-icon-cache -f -t "$icons_dir" 2>/dev/null || true
        fi

        # Ensure systemd user drop-in exists so onedriver unmount quirks never show as failures
        ensure_systemd_override

        case "$1" in
            --restart|-r)
                integration_changed=1
                ;;
        esac

        # A running Nautilus only loads Python extensions at process startup.
        # Restart it on a first install/update, but never on a no-op DMS reload.
        if [ "$integration_changed" -eq 1 ] && pgrep -x nautilus >/dev/null 2>&1; then
            stop_nautilus
            nautilus >/dev/null 2>&1 &
        fi

        echo "nautilus integration installed"
        exit 0
        ;;
    uninstall-nautilus)
        data_home="${XDG_DATA_HOME:-$home_dir/.local/share}"
        config_home="${XDG_CONFIG_HOME:-$home_dir/.config}"
        ext_dir="$data_home/nautilus-python/extensions"
        scripts_dir="$data_home/nautilus/scripts"
        systemd_override_dir="$config_home/systemd/user/onedriver@.service.d"

        rm -f "$ext_dir/onedrive_extension.py" "$ext_dir/onedrive_core.py" 2>/dev/null || true
        rm -f "$scripts_dir/OneDrive - Liberar espacio local" "$scripts_dir/OneDrive - Descargar en este equipo" 2>/dev/null || true
        rm -f "$systemd_override_dir/onedriver-monitor.conf" 2>/dev/null || true
        if [ -f "$systemd_override_dir/override.conf" ] && grep -Fqs "Created by DMS OneDriveMonitor" "$systemd_override_dir/override.conf"; then
            rm -f "$systemd_override_dir/override.conf" 2>/dev/null || true
        fi
        systemctl --user daemon-reload 2>/dev/null || true
        if pgrep -x nautilus >/dev/null 2>&1; then
            stop_nautilus
        fi
        echo "nautilus integration uninstalled"
        exit 0
        ;;
    restart-nautilus)
        was_running=0
        if pgrep -x nautilus >/dev/null 2>&1; then
            was_running=1
            stop_nautilus
        fi
        if [ "$was_running" -eq 1 ]; then
            nautilus >/dev/null 2>&1 &
        fi
        echo "nautilus restarted"
        exit 0
        ;;
    status-nautilus)
        data_home="${XDG_DATA_HOME:-$home_dir/.local/share}"
        ext_dir="$data_home/nautilus-python/extensions"
        if [ -f "$ext_dir/onedrive_extension.py" ]; then
            echo "installed"
        else
            echo "not-installed"
        fi
        exit 0
        ;;
    *)
        echo "Usage: actions.sh {start|stop|restart|enable|disable|toggle-autostart|mount-all|unmount-all|clear-cache|remove-mount|open-cache|open-launcher|install-nautilus|uninstall-nautilus|restart-nautilus|status-nautilus} [target]" >&2
        exit 1
        ;;
esac
