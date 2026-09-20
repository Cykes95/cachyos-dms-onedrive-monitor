import QtQuick
import Quickshell
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import qs.Modules.Settings.Widgets

PluginSettings {
    id: settingsRoot
    pluginId: "onedriverMonitor"

    SettingsCard {
        title: "Comportamiento y Monitoreo"
        iconName: "tune"

        SelectionSetting {
            settingKey: "pollSeconds"
            label: "Intervalo de actualización"
            description: "Frecuencia de consulta del estado de los servicios, espacio y logs"
            options: [
                { label: "2 segundos (intensivo)", value: "2" },
                { label: "5 segundos (recomendado)", value: "5" },
                { label: "10 segundos (ahorro)", value: "10" },
                { label: "30 segundos (mínimo)", value: "30" }
            ]
            defaultValue: "5"
        }

        ToggleSetting {
            settingKey: "showCache"
            label: "Mostrar espacio de caché y cuota"
            description: "Calcula y muestra el uso de almacenamiento local y la cuota disponible en la nube"
            defaultValue: true
        }

        ToggleSetting {
            settingKey: "showInactive"
            label: "Mostrar montajes detenidos"
            description: "Muestra las cuentas configuradas en la lista aunque estén desmontadas actualmente"
            defaultValue: true
        }

        ToggleSetting {
            settingKey: "showBarText"
            label: "Mostrar texto en la barra superior"
            description: "Muestra el estado ('Activo', '1/1') junto al icono de la nube en el panel superior"
            defaultValue: true
        }
    }

    SettingsCard {
        title: "Notificaciones"
        iconName: "notifications"

        ToggleSetting {
            settingKey: "notifyStateChanges"
            label: "Notificar incidencias y estado"
            description: "Envía alertas emergentes si un montaje falla, se queda sin conexión o se recupera"
            defaultValue: true
        }
    }

    SettingsCard {
        title: "Integración con Nautilus (Explorador de Archivos)"
        iconName: "folder_shared"

        StyledText {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Integra emblemas visuales de estado (en la nube vs. descargado) y opciones contextuales del ratón (Liberar espacio local / Descargar en este equipo) directamente en el explorador de archivos Nautilus."
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
        }

        ToggleSetting {
            settingKey: "enableNautilus"
            label: "Habilitar integración con Nautilus"
            description: "Muestra los emblemas en archivos y añade las acciones al menú contextual"
            defaultValue: true
        }

        Row {
            spacing: Theme.spacingS

            DankButton {
                text: "Reinstalar / Sincronizar integración"
                iconName: "sync"
                onClicked: {
                    const home = Quickshell.env("HOME") || "";
                    const actionScript = home + "/.config/DankMaterialShell/plugins/OneDriveMonitor/actions.sh";
                    Quickshell.execDetached(["sh", actionScript, "install-nautilus", "--restart"]);
                    ToastService.showInfo("Integración con Nautilus actualizada y reiniciada");
                }
            }

            DankActionButton {
                iconName: "refresh"
                tooltipText: "Reiniciar Nautilus"
                onClicked: {
                    const home = Quickshell.env("HOME") || "";
                    const actionScript = home + "/.config/DankMaterialShell/plugins/OneDriveMonitor/actions.sh";
                    Quickshell.execDetached(["sh", actionScript, "restart-nautilus"]);
                    ToastService.showInfo("Nautilus reiniciado");
                }
            }
        }
    }

    SettingsCard {
        title: "Gestión de Cuentas"
        iconName: "manage_accounts"

        StyledText {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "onedriver permite vincular múltiples cuentas personales, corporativas o educativas asociando cada una a una carpeta local diferente."
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
        }

        Row {
            spacing: Theme.spacingS

            DankButton {
                text: "Añadir o gestionar cuentas"
                iconName: "open_in_new"
                onClicked: {
                    const home = Quickshell.env("HOME") || "";
                    const actionScript = home + "/.config/DankMaterialShell/plugins/OneDriveMonitor/actions.sh";
                    Quickshell.execDetached(["sh", actionScript, "open-launcher"]);
                }
            }

            DankActionButton {
                iconName: "folder"
                tooltipText: "Abrir carpeta de caché de onedriver"
                onClicked: {
                    const home = Quickshell.env("HOME") || "";
                    Quickshell.execDetached(["xdg-open", home + "/.cache/onedriver"]);
                }
            }
        }
    }
}
