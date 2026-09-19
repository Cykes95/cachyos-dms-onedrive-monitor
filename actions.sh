#!/bin/sh
set -e

# Action helper for OneDrive Monitor DMS plugin
# Manages systemd units, caching, and onedriver lifecycle

home_dir=${HOME:-$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)}
config_file="$home_dir/.config/onedriver/config.yml"
cache_dir="$home_dir/.cache/onedriver"

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
        systemctl --user start "$unit"
        echo "started $unit"
        ;;
    stop)
        unit=$(normalize_unit "$1")
        systemctl --user stop "$unit"
        echo "stopped $unit"
        ;;
    restart)
        unit=$(normalize_unit "$1")
        systemctl --user restart "$unit"
        echo "restarted $unit"
        ;;
    enable)
        unit=$(normalize_unit "$1")
        systemctl --user enable "$unit"
        echo "enabled $unit"
        ;;
    disable)
        unit=$(normalize_unit "$1")
        systemctl --user disable "$unit"
        echo "disabled $unit"
        ;;
    toggle-autostart)
        unit=$(normalize_unit "$1")
        state=$(systemctl --user is-enabled "$unit" 2>/dev/null || true)
        case "$state" in
            enabled*)
                systemctl --user disable "$unit"
                echo "disabled $unit"
                ;;
            *)
                systemctl --user enable "$unit"
                echo "enabled $unit"
                ;;
        esac
        ;;
    mount-all)
        # Find all configured caches and start their units
        if [ -d "$cache_dir" ]; then
            for d in "$cache_dir"/*; do
                if [ -d "$d" ] && [ -f "$d/auth_tokens.json" ]; then
                    enc=$(basename "$d")
                    systemctl --user start "onedriver@${enc}.service" || true
                fi
            done
        fi
        echo "mount-all triggered"
        ;;
    unmount-all)
        units=$(systemctl --user list-units --all --no-legend --no-pager 'onedriver@*.service' 2>/dev/null \
            | awk '$1 ~ /^onedriver@/ {print $1}')
        for u in $units; do
            systemctl --user stop "$u" || true
        done
        echo "unmount-all completed"
        ;;
    clear-cache)
        encoded=$(normalize_encoded "$1")
        unit="onedriver@${encoded}.service"
        was_active=0
        if [ "$(systemctl --user is-active "$unit" 2>/dev/null || true)" = "active" ]; then
            was_active=1
            systemctl --user stop "$unit"
        fi
        content_dir="$cache_dir/$encoded/content"
        if [ -d "$content_dir" ]; then
            rm -rf "$content_dir"/* 2>/dev/null || true
        fi
        # Reset cached size file if exists
        rm -f "/tmp/onedriver_cache_${encoded}.tmp" 2>/dev/null || true
        if [ "$was_active" -eq 1 ]; then
            systemctl --user start "$unit"
        fi
        echo "cache cleared for $encoded"
        ;;
    remove-mount)
        encoded=$(normalize_encoded "$1")
        unit="onedriver@${encoded}.service"
        systemctl --user stop "$unit" 2>/dev/null || true
        systemctl --user disable "$unit" 2>/dev/null || true
        rm -rf "$cache_dir/$encoded" 2>/dev/null || true
        rm -f "/tmp/onedriver_cache_${encoded}.tmp" 2>/dev/null || true
        echo "removed mount $encoded"
        ;;
    open-launcher)
        if command -v onedriver-launcher >/dev/null 2>&1; then
            env WEBKIT_DISABLE_DMABUF_RENDERER=1 onedriver-launcher >/dev/null 2>&1 &
            echo "launcher opened"
        else
            echo "onedriver-launcher not found" >&2
            exit 1
        fi
        ;;
    *)
        echo "Usage: actions.sh {start|stop|restart|enable|disable|toggle-autostart|mount-all|unmount-all|clear-cache|remove-mount|open-launcher} [target]" >&2
        exit 1
        ;;
esac
