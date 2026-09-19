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

emit_mount() {
    encoded=$1
    [ -n "$encoded" ] || return 0

    mountpoint=$(systemd-escape --unescape --path "$encoded" 2>/dev/null || true)
    case "$mountpoint" in
        /*) ;;
        *) return 0 ;;
    esac

    unit="onedriver@${encoded}.service"
    cache_entry="$cache_dir/$encoded"
    token_file="$cache_entry/auth_tokens.json"
    label_file="$mountpoint/.xdg-volume-info"

    label=$(sed -n 's/^Name=//p' "$label_file" 2>/dev/null | head -n 1)
    account=$(sed -n 's/.*"account":"\([^"]*\)".*/\1/p' "$token_file" 2>/dev/null | head -n 1)
    [ -n "$label" ] || label="$account"
    [ -n "$label" ] || label="$mountpoint"

    active=$(systemctl --user is-active "$unit" 2>/dev/null || true)
    sub_state=$(systemctl --user show "$unit" --property=SubState --value 2>/dev/null || true)
    enabled=$(systemctl --user is-enabled "$unit" 2>/dev/null || true)
    filesystem=$(findmnt -M "$mountpoint" --noheadings --output FSTYPE 2>/dev/null || true)
    mounted=0
    case "$filesystem" in
        fuse*|onedriver) mounted=1 ;;
    esac

    cache_bytes=$(du -sb "$cache_entry" 2>/dev/null | awk 'NR == 1 {print $1}')
    case "$cache_bytes" in
        ''|*[!0-9]*) cache_bytes=0 ;;
    esac

    quota_block=$(stat -f -c '%S' "$mountpoint" 2>/dev/null || echo 0)
    quota_blocks=$(stat -f -c '%b' "$mountpoint" 2>/dev/null || echo 0)
    quota_free_blocks=$(stat -f -c '%a' "$mountpoint" 2>/dev/null || echo 0)
    case "$quota_block:$quota_blocks:$quota_free_blocks" in
        *[!0-9:]*|:*|*::*) total_bytes=0; free_bytes=0 ;;
        *) total_bytes=$((quota_block * quota_blocks)); free_bytes=$((quota_block * quota_free_blocks)) ;;
    esac

    activity=$(journalctl --user -u "$unit" --since "5 minutes ago" --no-pager --quiet -o cat 2>/dev/null \
        | grep -Ei 'uploading|uploaded|download|offline|online|retry|failed|error' \
        | tail -n 1 \
        | tr '\t\r\n' ' ' \
        | sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' \
        | sed 's/[[:space:]][[:space:]]*/ /g')

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$unit" "$encoded" "$mountpoint" "$label" "$account" \
        "$active" "$sub_state" "$enabled" "$mounted" "$cache_bytes" \
        "$activity" "$total_bytes" "$free_bytes"
}

# A mount can be known either because its unit is currently loaded or because
# its onedriver cache still contains its auth_tokens.json file.
unit_names=$(systemctl --user list-units --all --no-legend --no-pager 'onedriver@*.service' 2>/dev/null \
    | awk '$1 ~ /^onedriver@/ {print $1}' \
    | sed -n 's/^onedriver@\(.*\)\.service$/\1/p')

cache_names=$(find "$cache_dir" -mindepth 1 -maxdepth 1 -type d -name '*auth*' -prune -o \
    -mindepth 1 -maxdepth 1 -type d -exec sh -c '
        for d do [ -f "$d/auth_tokens.json" ] && basename "$d"; done
    ' sh {} + 2>/dev/null)

printf '%s\n%s\n' "$unit_names" "$cache_names" \
    | sed '/^[[:space:]]*$/d' \
    | sort -u \
    | while IFS= read -r encoded; do emit_mount "$encoded"; done
