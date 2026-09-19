#!/bin/sh

# Read-only discovery helper for the OneDrive Monitor DMS plugin.
# Output is tab-separated and intentionally contains no credentials or tokens.

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

now=$(date +%s 2>/dev/null || echo 0)

emit_mount() {
    encoded=$1
    [ -n "$encoded" ] || return 0

    mountpoint=$(systemd-escape --unescape --path "$encoded" 2>/dev/null || true)
    case "$mountpoint" in
        /*) ;;
        *) return 0 ;;
    esac

    # Filter out ghost/orphaned units that have neither a mount directory nor a cache entry
    unit="onedriver@${encoded}.service"
    cache_entry="$cache_dir/$encoded"
    if [ ! -d "$mountpoint" ] && [ ! -d "$cache_entry" ]; then
        return 0
    fi
    token_file="$cache_entry/auth_tokens.json"
    label_file="$mountpoint/.xdg-volume-info"

    label=$(sed -n 's/^Name=//p' "$label_file" 2>/dev/null | head -n 1)
    account=$(sed -n 's/.*"account":"\([^"]*\)".*/\1/p' "$token_file" 2>/dev/null | head -n 1)
    [ -n "$label" ] || label="$account"
    [ -n "$label" ] || label="$mountpoint"

    account_type="work"
    case "$account" in
        *@outlook.*|*@hotmail.*|*@live.*|*@msn.*|*@passport.*)
            account_type="personal"
            ;;
    esac

    active=$(systemctl --user is-active "$unit" 2>/dev/null || true)
    sub_state=$(systemctl --user show "$unit" --property=SubState --value 2>/dev/null || true)
    enabled=$(systemctl --user is-enabled "$unit" 2>/dev/null || true)
    case "$enabled" in
        enabled*) enabled="enabled" ;;
        *) enabled="disabled" ;;
    esac

    filesystem=$(findmnt -M "$mountpoint" --noheadings --output FSTYPE 2>/dev/null || true)
    mounted=0
    case "$filesystem" in
        fuse*|onedriver) mounted=1 ;;
    esac

    # Cache size check optimization: avoid running du -sb on every poll tick
    cache_bytes=0
    cache_size_file="/tmp/onedriver_cache_${encoded}.tmp"
    if [ -r "$cache_size_file" ]; then
        read -r last_ts cached_val < "$cache_size_file" 2>/dev/null || true
        if [ -n "$last_ts" ] && [ "$((now - last_ts))" -lt 30 ] && [ -n "$cached_val" ]; then
            cache_bytes="$cached_val"
        fi
    fi
    if [ "$cache_bytes" -eq 0 ] && [ -d "$cache_entry" ]; then
        cache_bytes=$(du -sb "$cache_entry" 2>/dev/null | awk 'NR == 1 {print $1}')
        case "$cache_bytes" in
            ''|*[!0-9]*) cache_bytes=0 ;;
            *) printf '%s %s\n' "$now" "$cache_bytes" > "$cache_size_file" 2>/dev/null || true ;;
        esac
    fi

    quota_block=$(stat -f -c '%S' "$mountpoint" 2>/dev/null || echo 0)
    quota_blocks=$(stat -f -c '%b' "$mountpoint" 2>/dev/null || echo 0)
    quota_free_blocks=$(stat -f -c '%a' "$mountpoint" 2>/dev/null || echo 0)
    case "$quota_block:$quota_blocks:$quota_free_blocks" in
        *[!0-9:]*|:*|*::*) total_bytes=0; free_bytes=0 ;;
        *) total_bytes=$((quota_block * quota_blocks)); free_bytes=$((quota_block * quota_free_blocks)) ;;
    esac

    # journalctl optimization: limit to last 25 lines
    activity=$(journalctl --user -u "$unit" --since "5 minutes ago" -n 25 --no-pager --quiet -o cat 2>/dev/null \
        | grep -Ei 'uploading|uploaded|download|offline|online|retry|failed|error' \
        | tail -n 1 \
        | tr '\t\r\n' ' ' \
        | sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' \
        | sed 's/[[:space:]][[:space:]]*/ /g')

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$unit" "$encoded" "$mountpoint" "$label" "$account" \
        "$active" "$sub_state" "$enabled" "$mounted" "$cache_bytes" \
        "$activity" "$total_bytes" "$free_bytes" "$account_type"
}

# Discover units from loaded units, enabled unit files, and systemd wants directory
loaded_units=$(systemctl --user list-units --all --no-legend --no-pager 'onedriver@*.service' 2>/dev/null \
    | awk '$1 ~ /^onedriver@/ {print $1}' \
    | sed -n 's/^onedriver@\(.*\)\.service$/\1/p')

file_units=$(systemctl --user list-unit-files --no-legend --no-pager 'onedriver@*.service' 2>/dev/null \
    | awk '$1 ~ /^onedriver@.+\.service/ {print $1}' \
    | sed -n 's/^onedriver@\(.*\)\.service$/\1/p')

wants_units=""
if [ -d "$home_dir/.config/systemd/user/default.target.wants" ]; then
    wants_units=$(find "$home_dir/.config/systemd/user/default.target.wants" -maxdepth 1 -name 'onedriver@*.service' 2>/dev/null \
        | sed -n 's/.*onedriver@\(.*\)\.service$/\1/p')
fi

# Discover configured mounts directly from cache directories containing auth_tokens.json
# (Safely avoiding directories like CacheStorage and WebKitCache without pruning valid paths)
cache_units=""
if [ -d "$cache_dir" ]; then
    for d in "$cache_dir"/*; do
        if [ -d "$d" ] && [ -f "$d/auth_tokens.json" ]; then
            cache_units="${cache_units}$(basename "$d")\n"
        fi
    done
fi

printf '%s\n%s\n%s\n%b\n' "$loaded_units" "$file_units" "$wants_units" "$cache_units" \
    | sed '/^[[:space:]]*$/d' \
    | sort -u \
    | while IFS= read -r encoded; do emit_mount "$encoded"; done
