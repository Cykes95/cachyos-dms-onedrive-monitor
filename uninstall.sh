#!/bin/sh
# Uninstall OneDrive Monitor for the current user only.
set -eu

plugin_id="OneDriveMonitor"
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
target_dir="${XDG_CONFIG_HOME:-"$HOME/.config"}/DankMaterialShell/plugins/$plugin_id"

[ "$(id -u)" -ne 0 ] || { echo "No ejecute el desinstalador como root ni con sudo." >&2; exit 1; }
printf 'Se eliminará la integración de Nautilus y %s. ¿Continuar? [y/N] ' "$target_dir"
read answer
case "$answer" in y|Y|yes|YES|si|sí|SI|SÍ) ;; *) echo "Cancelado."; exit 0 ;; esac

if [ -x "$source_dir/actions.sh" ]; then
    "$source_dir/actions.sh" uninstall-nautilus
fi
if [ -d "$target_dir" ]; then
    backup_dir="${target_dir}.removed.$(date +%Y%m%d_%H%M%S)"
    mv "$target_dir" "$backup_dir"
    echo "Plugin retirado. Copia recuperable: $backup_dir"
fi
echo "Recargue DMS para retirar el widget: dms restart"
