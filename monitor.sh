#!/bin/sh

# Read-only discovery helper for the OneDrive Monitor DMS plugin.
# Highly optimized: single-pass systemd status, cached quota & size lookups, zero disk churn.
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

    unit="onedriver@${encoded}.service"
    cache_entry="$cache_dir/$encoded"
    if [ ! -d "$mountpoint" ] && [ ! -d "$cache_entry" ]; then
        return 0
    fi
    token_file="$cache_entry/auth_tokens.json"
    label_file="$mountpoint/.xdg-volume-info"

    label=""
    if [ -r "$label_file" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                Name=*) label="${line#Name=}"; break ;;
            esac
        done < "$label_file"
    fi

    account=""
    if [ -r "$token_file" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                *\"account\":*)
                    account=${line#*\"account\":\"}
                    account=${account%%\"*}
                    break
                    ;;
            esac
        done < "$token_file"
    fi

    [ -n "$label" ] || label="$account"
    [ -n "$label" ] || label="$mountpoint"

    account_type="work"
    case "$account" in
        *@outlook.*|*@hotmail.*|*@live.*|*@msn.*|*@passport.*)
            account_type="personal"
            ;;
    esac

    # Optimization: Query ActiveState, SubState and UnitFileState in a single systemctl fork
    active="inactive"
    sub_state="dead"
    enabled="disabled"
    while IFS='=' read -r k v; do
        case "$k" in
            ActiveState) active="$v" ;;
            SubState) sub_state="$v" ;;
            UnitFileState)
                case "$v" in
                    enabled*) enabled="enabled" ;;
                    *) enabled="disabled" ;;
                esac
                ;;
        esac
    done <<PROP_EOF
$(systemctl --user show "$unit" --property=ActiveState,SubState,UnitFileState 2>/dev/null)
PROP_EOF

    mounted=0
    if command -v findmnt >/dev/null 2>&1; then
        if findmnt -rn -t fuse.onedriver,fuse -o TARGET "$mountpoint" >/dev/null 2>&1; then
            mounted=1
        fi
    elif [ -r /proc/mounts ] && grep -Fqs " $mountpoint " /proc/mounts; then
        mounted=1
    fi

    # Optimization: Cache size lookup with mtime verification & 30-second TTL (max 300s TTL ceiling)
    cache_bytes=0
    cache_size_file="/tmp/onedriver_cache_${encoded}.tmp"
    cur_mtime=$(stat -c %Y "$cache_entry/content" 2>/dev/null || echo 0)
    cur_db_sz=$(stat -c %s "$cache_entry/onedriver.db" 2>/dev/null || echo 0)
    need_du=1

    if [ -r "$cache_size_file" ]; then
        read -r last_ts last_mtime last_db_sz cached_val < "$cache_size_file" 2>/dev/null || true
        if [ -n "$last_ts" ] && [ -n "$cached_val" ]; then
            # Mandatory TTL ceiling: must recalculate after 300s regardless of mtime
            if [ "$((now - last_ts))" -lt 300 ]; then
                if [ "$((now - last_ts))" -lt 30 ] || { [ "$last_mtime" = "$cur_mtime" ] && [ "$last_db_sz" = "$cur_db_sz" ]; }; then
                    cache_bytes="$cached_val"
                    need_du=0
                fi
            fi
        fi
    fi
    if [ "$need_du" -eq 1 ] && [ -d "$cache_entry" ]; then
        cache_bytes=$(du -sb "$cache_entry" 2>/dev/null | awk 'NR == 1 {print $1}')
        case "$cache_bytes" in
            ''|*[!0-9]*) cache_bytes=0 ;;
            *) printf '%s %s %s %s\n' "$now" "$cur_mtime" "$cur_db_sz" "$cache_bytes" > "$cache_size_file" 2>/dev/null || true ;;
        esac
    fi

    # Optimization: Single stat -f call with 60-second TTL
    total_bytes=0
    free_bytes=0
    if [ "$mounted" -eq 1 ]; then
        quota_cache_file="/tmp/onedriver_quota_${encoded}.tmp"
        read_quota=1
        if [ -r "$quota_cache_file" ]; then
            read -r q_ts q_tot q_free < "$quota_cache_file" 2>/dev/null || true
            if [ -n "$q_ts" ] && [ "$((now - q_ts))" -lt 60 ] && [ -n "$q_tot" ]; then
                total_bytes="$q_tot"
                free_bytes="$q_free"
                read_quota=0
            fi
        fi
        if [ "$read_quota" -eq 1 ]; then
            quota_stats=$(stat -f -c '%S %b %a' "$mountpoint" 2>/dev/null || echo "0 0 0")
            read -r q_s q_b q_a <<Q_EOF
$quota_stats
Q_EOF
            case "$q_s:$q_b:$q_a" in
                *[!0-9:]*|:*|*::*) total_bytes=0; free_bytes=0 ;;
                *) total_bytes=$((q_s * q_b)); free_bytes=$((q_s * q_a))
                   printf '%s %s %s\n' "$now" "$total_bytes" "$free_bytes" > "$quota_cache_file" 2>/dev/null || true
                   ;;
            esac
        fi
    fi

    # Optimization: Cache journalctl activity for 10s when active
    activity=""
    if [ "$active" = "active" ]; then
        act_cache_file="/tmp/onedriver_act_${encoded}.tmp"
        read_act=1
        if [ -r "$act_cache_file" ]; then
            read -r last_act_ts last_act < "$act_cache_file" 2>/dev/null || true
            if [ -n "$last_act_ts" ] && [ "$((now - last_act_ts))" -lt 10 ]; then
                activity="$last_act"
                read_act=0
            fi
        fi
        if [ "$read_act" -eq 1 ]; then
            activity=$(journalctl --user -u "$unit" --since "5 minutes ago" -n 25 --no-pager --quiet -o cat 2>/dev/null \
                | grep -Ei 'uploading|uploaded|download|offline|online|retry|failed|error' \
                | tail -n 1 \
                | tr '\t\r\n' ' ' \
                | sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' \
                | sed 's/[[:space:]][[:space:]]*/ /g')
            printf '%s %s\n' "$now" "$activity" > "$act_cache_file" 2>/dev/null || true
        fi
    fi

    # Optimization: Count files by content directory mtime
    cached_files_count=0
    content_dir="$cache_entry/content"
    if [ -d "$content_dir" ]; then
        cnt_cache_file="/tmp/onedriver_cnt_${encoded}.tmp"
        dir_mtime=$(stat -c %Y "$content_dir" 2>/dev/null || echo 0)
        recount=1
        if [ -r "$cnt_cache_file" ]; then
            read -r last_mtime last_cnt < "$cnt_cache_file" 2>/dev/null || true
            if [ "$last_mtime" = "$dir_mtime" ] && [ -n "$last_cnt" ]; then
                cached_files_count="$last_cnt"
                recount=0
            fi
        fi
        if [ "$recount" -eq 1 ]; then
            cached_files_count=$(find "$content_dir" -maxdepth 1 -type f 2>/dev/null | wc -l || echo 0)
            printf '%s %s\n' "$dir_mtime" "$cached_files_count" > "$cnt_cache_file" 2>/dev/null || true
        fi
    fi

    # Clean any accidental tabs/newlines in text fields
    clean_label=$(printf '%s' "$label" | tr '\t\r\n' ' ')
    clean_account=$(printf '%s' "$account" | tr '\t\r\n' ' ')

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$unit" "$encoded" "$mountpoint" "$clean_label" "$clean_account" \
        "$active" "$sub_state" "$enabled" "$mounted" "$cache_bytes" \
        "$activity" "$total_bytes" "$free_bytes" "$account_type" "$cached_files_count"
}

# Discover units from loaded units, enabled unit files, and systemd wants directory
loaded_units=$(systemctl --user list-units --all --no-legend --no-pager 'onedriver@*.service' 2>/dev/null \
    | awk '$1 ~ /^onedriver@/ {print $1}' \
    | sed -n 's/^onedriver@\(.*\)\.service$/\1/p')

wants_units=""
if [ -d "$home_dir/.config/systemd/user/default.target.wants" ]; then
    wants_units=$(find "$home_dir/.config/systemd/user/default.target.wants" -maxdepth 1 -name 'onedriver@*.service' 2>/dev/null \
        | sed -n 's/.*onedriver@\(.*\)\.service$/\1/p')
fi

# Stream discovery cleanly without printf %b to preserve systemd \x2d escape sequences
{
    [ -n "$loaded_units" ] && printf '%s\n' "$loaded_units"
    [ -n "$wants_units" ] && printf '%s\n' "$wants_units"
    if [ -d "$cache_dir" ]; then
        for d in "$cache_dir"/*; do
            if [ -d "$d" ] && [ -f "$d/auth_tokens.json" ]; then
                basename "$d"
            fi
        done
    fi
} | sed '/^[[:space:]]*$/d' \
  | sort -u \
  | while IFS= read -r encoded; do emit_mount "$encoded"; done
