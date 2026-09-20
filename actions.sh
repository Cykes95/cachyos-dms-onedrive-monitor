#!/bin/sh

# Action helper for OneDrive Monitor DMS plugin
# Manages systemd units, caching, and onedriver lifecycle

home_dir=${HOME:-$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)}
config_file="$home_dir/.config/onedriver/config.yml"
cache_dir="$home_dir/.cache/onedriver"
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

if [ -r "$config_file" ]; then
    configured_cache=$(sed -n 's/^[[:space:]]*cacheDir:[[:space:]]*//p' "$config_file" | head -n 1)
    configured_cache=${configured_cache%"\r"}
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

cmd="$1"
shift 1 2>/dev/null || true

case "$cmd" in
    start)
        unit=$(normalize_unit "$1")
        systemctl --user start "$unit" 2>/dev/null || true
        echo "started $unit"
        exit 0
        ;;
    stop)
        unit=$(normalize_unit "$1")
        systemctl --user stop "$unit" 2>/dev/null || true
        echo "stopped $unit"
        exit 0
        ;;
    restart)
        unit=$(normalize_unit "$1")
        systemctl --user restart "$unit" 2>/dev/null || true
        echo "restarted $unit"
        exit 0
        ;;
    enable)
        unit=$(normalize_unit "$1")
        systemctl --user enable "$unit" 2>/dev/null || true
        echo "enabled $unit"
        exit 0
        ;;
    disable)
        unit=$(normalize_unit "$1")
        systemctl --user disable "$unit" 2>/dev/null || true
        echo "disabled $unit"
        exit 0
        ;;
    toggle-autostart)
        unit=$(normalize_unit "$1")
        state=$(systemctl --user is-enabled "$unit" 2>/dev/null || true)
        case "$state" in
            enabled*)
                systemctl --user disable "$unit" 2>/dev/null || true
                echo "disabled $unit"
                ;;
            *)
                systemctl --user enable "$unit" 2>/dev/null || true
                echo "enabled $unit"
                ;;
        esac
        exit 0
        ;;
    mount-all)
        if [ -d "$cache_dir" ]; then
            for d in "$cache_dir"/*; do
                if [ -d "$d" ] && [ -f "$d/auth_tokens.json" ]; then
                    enc=$(basename "$d")
                    systemctl --user start "onedriver@${enc}.service" 2>/dev/null || true
                fi
            done
        fi
        echo "mount-all triggered"
        exit 0
        ;;
    unmount-all)
        units=$(systemctl --user list-units --all --no-legend --no-pager 'onedriver@*.service' 2>/dev/null \
            | awk '$1 ~ /^onedriver@/ {print $1}')
        for u in $units; do
            systemctl --user stop "$u" 2>/dev/null || true
        done
        echo "unmount-all completed"
        exit 0
        ;;
    clear-cache)
        encoded=$(normalize_encoded "$1")
        unit="onedriver@${encoded}.service"
        was_active=0
        if [ "$(systemctl --user is-active "$unit" 2>/dev/null || true)" = "active" ]; then
            was_active=1
            systemctl --user stop "$unit" 2>/dev/null || true
            sleep 0.5
        fi
        content_dir="$cache_dir/$encoded/content"
        if [ -d "$content_dir" ]; then
            rm -rf "$content_dir"/* 2>/dev/null || true
        fi
        # Remove onedriver.db to compact metadata and reset cache size completely
        rm -f "$cache_dir/$encoded/onedriver.db" 2>/dev/null || true
        # Reset all cached files so monitor immediately recalculates
        rm -f /tmp/onedriver_*_"${encoded}.tmp" 2>/dev/null || true
        if [ "$was_active" -eq 1 ]; then
            systemctl --user start "$unit" 2>/dev/null || true
        fi
        echo "cache cleared for $encoded"
        exit 0
        ;;
    remove-mount)
        encoded=$(normalize_encoded "$1")
        unit="onedriver@${encoded}.service"
        systemctl --user stop "$unit" 2>/dev/null || true
        systemctl --user disable "$unit" 2>/dev/null || true
        rm -rf "$cache_dir/$encoded" 2>/dev/null || true
        rm -f /tmp/onedriver_*_"${encoded}.tmp" 2>/dev/null || true
        echo "removed mount $encoded"
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
        icons_dir="$home_dir/.local/share/icons/hicolor"
        ext_dir="$home_dir/.local/share/nautilus-python/extensions"
        scripts_dir="$home_dir/.local/share/nautilus/scripts"

        mkdir -p "$icons_dir/scalable/emblems" "$icons_dir/48x48/emblems" "$ext_dir" "$scripts_dir"

        if [ -d "$script_dir/assets/emblems" ]; then
            cp -f "$script_dir/assets/emblems"/*.svg "$icons_dir/scalable/emblems/" 2>/dev/null || true
            cp -f "$script_dir/assets/emblems"/*.svg "$icons_dir/48x48/emblems/" 2>/dev/null || true
        fi

        if [ -f "$script_dir/integrations/nautilus/onedrive_extension.py" ]; then
            cp -f "$script_dir/integrations/nautilus/onedrive_extension.py" "$ext_dir/" 2>/dev/null || true
        fi

        if [ -f "$script_dir/integrations/nautilus/OneDrive - Liberar espacio local" ]; then
            cp -f "$script_dir/integrations/nautilus/OneDrive - Liberar espacio local" "$scripts_dir/" 2>/dev/null || true
            chmod +x "$scripts_dir/OneDrive - Liberar espacio local" 2>/dev/null || true
        fi

        if command -v gtk-update-icon-cache >/dev/null 2>&1; then
            gtk-update-icon-cache -f -t "$icons_dir" 2>/dev/null || true
        fi

        # Ensure systemd user drop-in exists so onedriver unmount quirks never show as failures
        systemd_override_dir="$home_dir/.config/systemd/user/onedriver@.service.d"
        mkdir -p "$systemd_override_dir" 2>/dev/null || true
        if [ ! -f "$systemd_override_dir/override.conf" ]; then
            printf '[Service]\nExecStopPost=\nExecStopPost=-/usr/bin/fusermount3 -uz /%%I\n' > "$systemd_override_dir/override.conf" 2>/dev/null || true
            systemctl --user daemon-reload 2>/dev/null || true
        fi

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
        echo "Usage: actions.sh {start|stop|restart|enable|disable|toggle-autostart|mount-all|unmount-all|clear-cache|remove-mount|open-launcher|install-nautilus|uninstall-nautilus|restart-nautilus|status-nautilus} [target]" >&2
        exit 1
        ;;
esac
