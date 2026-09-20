#!/bin/sh
# Install OneDrive Monitor for the current user. Never run this script with sudo.
set -eu
umask 077

plugin_id="OneDriveMonitor"
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
config_home=${XDG_CONFIG_HOME:-"$HOME/.config"}
plugins_dir="$config_home/DankMaterialShell/plugins"
target_dir="$plugins_dir/$plugin_id"
upgrade=0

usage() {
    cat <<'EOF'
Usage: ./install.sh [--upgrade] [--check]

Installs OneDrive Monitor for the current user only.
  --check    Check prerequisites without copying files.
  --upgrade  Replace an existing installation after creating a timestamped backup.
EOF
}

package_hint() {
    if command -v pacman >/dev/null 2>&1; then
        echo "CachyOS/Arch: sudo pacman -S onedriver nautilus python-nautilus python-gobject fuse3"
    elif command -v apt >/dev/null 2>&1; then
        echo "Debian/Ubuntu: sudo apt install onedriver nautilus nautilus-python python3-gi fuse3"
    elif command -v dnf >/dev/null 2>&1; then
        echo "Fedora: sudo dnf install onedriver nautilus nautilus-python python3-gobject fuse3"
    elif command -v zypper >/dev/null 2>&1; then
        echo "openSUSE: instale onedriver, nautilus, nautilus-python, python3-gobject y fuse3."
    else
        echo "Instale onedriver, Nautilus, nautilus-python/PyGObject y FUSE3 con su gestor de paquetes."
    fi
}

check_requirements() {
    missing=""
    for binary in dms onedriver nautilus python3 systemctl findmnt tar; do
        command -v "$binary" >/dev/null 2>&1 || missing="${missing}${missing:+, }$binary"
    done
    if ! command -v fusermount3 >/dev/null 2>&1 && ! command -v fusermount >/dev/null 2>&1; then
        missing="${missing}${missing:+, }fusermount3"
    fi
    if ! python3 -c "import gi; gi.require_version('Nautilus', '4.1'); from gi.repository import Nautilus" >/dev/null 2>&1; then
        missing="${missing}${missing:+, }nautilus-python (API 4.1)"
    fi
    if [ -n "$missing" ]; then
        echo "Faltan requisitos: $missing" >&2
        package_hint >&2
        return 1
    fi
    echo "Requisitos comprobados: OK"
}

mode="install"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --upgrade) upgrade=1 ;;
        --check) mode="check" ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

[ "$(id -u)" -ne 0 ] || { echo "No ejecute el instalador como root ni con sudo." >&2; exit 1; }
[ -f "$source_dir/plugin.json" ] || { echo "No se encuentra plugin.json junto al instalador." >&2; exit 1; }
check_requirements
[ "$mode" = "check" ] && exit 0

if [ -e "$target_dir" ] && [ "$upgrade" -ne 1 ]; then
    echo "Ya existe $target_dir. Use --upgrade para actualizar y conservar una copia de seguridad." >&2
    exit 1
fi

mkdir -p "$plugins_dir"
stage_dir=$(mktemp -d "$plugins_dir/.${plugin_id}.stage.XXXXXX")
cleanup() { [ -d "$stage_dir" ] && find "$stage_dir" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM

# Preserve executable bits and exclude development-only files from the user install.
tar --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' -C "$source_dir" -cf - . | tar -C "$stage_dir" -xf -

if [ -e "$target_dir" ]; then
    backup_dir="${target_dir}.backup.$(date +%Y%m%d_%H%M%S)"
    mv "$target_dir" "$backup_dir"
    echo "Copia de seguridad creada: $backup_dir"
fi
mv "$stage_dir" "$target_dir"
trap - EXIT HUP INT TERM

echo "OneDrive Monitor instalado en: $target_dir"
echo "Recargue DMS con: dms ipc call plugins reload onedriverMonitor"
echo "Después, autorice su cuenta de Microsoft desde el botón «Gestionar cuentas»."
