#!/bin/sh

# Action helper for OneDrive Monitor DMS plugin
# Manages systemd units, caching, and onedriver lifecycle

home_dir=${HOME:-$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)}
config_file="$home_dir/.config/onedriver/config.yml"
cache_dir="$home_dir/.cache/onedriver"
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

runtime_dir="${XDG_RUNTIME_DIR:-/tmp}/onedriver_dms"
mkdir -p "$runtime_dir" 2>/dev/null || runtime_dir="/tmp"

if [ -r "$config_file" ]; then
    configured_cache=$(sed -n 's/^[[:space:]]*cacheDir:[[:space:]]*//p' "$config_file" | head -n 1)
    configured_cache=${configured_cache%"\r"}
    configured_cache=$(printf '%s' "$configured_cache" | tr -d "\"'" )
    case "$configured_cache" in
        "~") cache_dir="$home_dir" ;;
        "~/"*) cache_dir="$home_dir/${configured_cache#~/}" ;;
        /*) cache_dir="$configured_cache" ;;
    esac
fi

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

validate_encoded() {
    val="$1"
    case "$val" in
        */*|*..*|''|*[[:space:]]*)
            echo "Error: identificador de cuenta no válido: $val" >&2
            exit 1
            ;;
    esac
}

ensure_systemd_override() {
    fusermount_bin=$(command -v fusermount3 || command -v fusermount || echo /usr/bin/fusermount3)
    systemd_override_dir="$home_dir/.config/systemd/user/onedriver@.service.d"
    if [ ! -f "$systemd_override_dir/override.conf" ]; then
        mkdir -p "$systemd_override_dir" 2>/dev/null || true
        printf '[Service]\nExecStopPost=\nExecStopPost=-%s -uz /%%I\n' "$fusermount_bin" > "$systemd_override_dir/override.conf" 2>/dev/null || true
        systemctl --user daemon-reload 2>/dev/null || true
    fi
}

cmd="$1"
shift 1 2>/dev/null || true

case "$cmd" in
    start)
        ensure_systemd_override
        unit=$(normalize_unit "$1")
        if out=$(systemctl --user start "$unit" 2>&1); then
            echo "started $unit"
            exit 0
        else
            echo "Error al iniciar $unit: $out" >&2
            exit 1
        fi
        ;;
    stop)
        unit=$(normalize_unit "$1")
        if out=$(systemctl --user stop "$unit" 2>&1); then
            echo "stopped $unit"
            exit 0
        else
            echo "Error al detener $unit: $out" >&2
            exit 1
        fi
        ;;
    restart)
        ensure_systemd_override
        unit=$(normalize_unit "$1")
        if out=$(systemctl --user restart "$unit" 2>&1); then
            echo "restarted $unit"
            exit 0
        else
            echo "Error al reiniciar $unit: $out" >&2
            exit 1
        fi
        ;;
    enable)
        unit=$(normalize_unit "$1")
        if out=$(systemctl --user enable "$unit" 2>&1); then
            echo "enabled $unit"
            exit 0
        else
            echo "Error al habilitar inicio automático de $unit: $out" >&2
            exit 1
        fi
        ;;
    disable)
        unit=$(normalize_unit "$1")
        if out=$(systemctl --user disable "$unit" 2>&1); then
            echo "disabled $unit"
            exit 0
        else
            echo "Error al deshabilitar inicio automático de $unit: $out" >&2
            exit 1
        fi
        ;;
    toggle-autostart)
        unit=$(normalize_unit "$1")
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
        if [ -d "$cache_dir" ]; then
            for d in "$cache_dir"/*; do
                if [ -d "$d" ] && [ -f "$d/auth_tokens.json" ]; then
                    enc=$(basename "$d")
                    u="onedriver@${enc}.service"
                    if ! systemctl --user start "$u" 2>&1; then
                        failed=1
                        failed_units="$failed_units $u"
                    fi
                fi
            done
        fi
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
            if ! systemctl --user stop "$u" 2>&1; then
                failed=1
                failed_units="$failed_units $u"
            fi
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
        unit="onedriver@${encoded}.service"
        was_active=0
        if [ "$(systemctl --user is-active "$unit" 2>/dev/null || true)" = "active" ]; then
            was_active=1
            systemctl --user stop "$unit" 2>/dev/null || true
            for _ in 1 2 3 4 5 6 7 8 9 10; do
                st=$(systemctl --user is-active "$unit" 2>/dev/null || true)
                [ "$st" != "active" ] && [ "$st" != "deactivating" ] && break
                sleep 0.2
            done
            if [ "$(systemctl --user is-active "$unit" 2>/dev/null || true)" = "active" ]; then
                echo "Error: no se pudo detener $unit antes de vaciar la caché" >&2
                exit 1
            fi
        fi
        content_dir="$cache_dir/$encoded/content"
        if [ -d "$content_dir" ]; then
            find "$content_dir" -mindepth 1 -delete 2>/dev/null || rm -rf "$content_dir"/* 2>/dev/null || true
        fi
        # Remove onedriver.db to compact metadata and reset cache size completely
        rm -f "$cache_dir/$encoded/onedriver.db" 2>/dev/null || true
        # Reset all cached files so monitor immediately recalculates
        rm -f "$runtime_dir"/*_"${encoded}.tmp" /tmp/onedriver_*_"${encoded}.tmp" 2>/dev/null || true
        if [ "$was_active" -eq 1 ]; then
            if ! systemctl --user start "$unit" 2>/dev/null; then
                echo "Advertencia: no se pudo reiniciar $unit tras vaciar la caché" >&2
                exit 1
            fi
        fi
        echo "cache cleared for $encoded"
        exit 0
        ;;
    remove-mount)
        encoded=$(normalize_encoded "$1")
        validate_encoded "$encoded"
        unit="onedriver@${encoded}.service"
        mountpoint=$(systemd-escape --unescape --path "$encoded" 2>/dev/null || true)
        systemctl --user stop "$unit" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            st=$(systemctl --user is-active "$unit" 2>/dev/null || true)
            [ "$st" != "active" ] && [ "$st" != "deactivating" ] && break
            sleep 0.2
        done
        if [ "$(systemctl --user is-active "$unit" 2>/dev/null || true)" = "active" ]; then
            echo "Error: no se pudo detener $unit antes de desvincular" >&2
            exit 1
        fi
        systemctl --user disable "$unit" 2>/dev/null || true
        fusermount_bin=$(command -v fusermount3 || command -v fusermount || true)
        if [ -n "$mountpoint" ] && [ -n "$fusermount_bin" ]; then
            "$fusermount_bin" -uz "$mountpoint" 2>/dev/null || true
        fi
        rm -rf "$cache_dir/$encoded" 2>/dev/null || true
        rm -f "$runtime_dir"/*_"${encoded}.tmp" /tmp/onedriver_*_"${encoded}.tmp" 2>/dev/null || true
        echo "removed mount $encoded"
        exit 0
        ;;
    open-cache)
        if [ -d "$cache_dir" ]; then
            xdg-open "$cache_dir" >/dev/null 2>&1 &
            echo "cache opened"
            exit 0
        else
            echo "cache directory not found: $cache_dir" >&2
            exit 1
        fi
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
        icons_dir="$home_dir/.local/share/icons/hicolor"
        ext_dir="$home_dir/.local/share/nautilus-python/extensions"
        scripts_dir="$home_dir/.local/share/nautilus/scripts"
        systemd_override_dir="$home_dir/.config/systemd/user/onedriver@.service.d"

        mkdir -p "$icons_dir/scalable/emblems" "$icons_dir/48x48/emblems" "$ext_dir" "$scripts_dir" "$systemd_override_dir"

        needs_icon_cache=0

        if [ -d "$script_dir/assets/emblems" ]; then
            for icon in "$script_dir/assets/emblems"/*.svg; do
                [ -f "$icon" ] || continue
                base=$(basename "$icon")
                dest_sc="$icons_dir/scalable/emblems/$base"
                dest_48="$icons_dir/48x48/emblems/$base"
                if [ ! -f "$dest_sc" ] || ! cmp -s "$icon" "$dest_sc"; then
                    cp -f "$icon" "$dest_sc" 2>/dev/null || true
                    needs_icon_cache=1
                fi
                if [ ! -f "$dest_48" ] || ! cmp -s "$icon" "$dest_48"; then
                    cp -f "$icon" "$dest_48" 2>/dev/null || true
                    needs_icon_cache=1
                fi
            done
        fi

        src_ext="$script_dir/integrations/nautilus/onedrive_extension.py"
        dest_ext="$ext_dir/onedrive_extension.py"
        if [ -f "$src_ext" ]; then
            if [ ! -f "$dest_ext" ] || ! cmp -s "$src_ext" "$dest_ext"; then
                cp -f "$src_ext" "$dest_ext" 2>/dev/null || true
            fi
        fi

        src_script="$script_dir/integrations/nautilus/OneDrive - Liberar espacio local"
        dest_script="$scripts_dir/OneDrive - Liberar espacio local"
        if [ -f "$src_script" ]; then
            if [ ! -f "$dest_script" ] || ! cmp -s "$src_script" "$dest_script"; then
                cp -f "$src_script" "$dest_script" 2>/dev/null || true
                chmod +x "$dest_script" 2>/dev/null || true
            fi
        fi

        if [ "$needs_icon_cache" -eq 1 ] && command -v gtk-update-icon-cache >/dev/null 2>&1; then
            gtk-update-icon-cache -f -t "$icons_dir" 2>/dev/null || true
        fi

        # Ensure systemd user drop-in exists so onedriver unmount quirks never show as failures
        ensure_systemd_override

        case "$1" in
            --restart|-r)
                if pgrep -x nautilus >/dev/null 2>&1; then
                    nautilus -q 2>/dev/null || true
                fi
                ;;
        esac

        echo "nautilus integration installed"
        exit 0
        ;;
    uninstall-nautilus)
        ext_dir="$home_dir/.local/share/nautilus-python/extensions"
        scripts_dir="$home_dir/.local/share/nautilus/scripts"
        rm -f "$ext_dir/onedrive_extension.py" 2>/dev/null || true
        rm -f "$scripts_dir/OneDrive - Liberar espacio local" 2>/dev/null || true
        if pgrep -x nautilus >/dev/null 2>&1; then
            nautilus -q 2>/dev/null || true
        fi
        echo "nautilus integration uninstalled"
        exit 0
        ;;
    restart-nautilus)
        if pgrep -x nautilus >/dev/null 2>&1; then
            nautilus -q 2>/dev/null || true
        fi
        echo "nautilus restarted"
        exit 0
        ;;
    status-nautilus)
        ext_dir="$home_dir/.local/share/nautilus-python/extensions"
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
