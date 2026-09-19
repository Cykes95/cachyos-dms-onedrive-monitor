import QtQuick
import qs.Common
import qs.Modules.Plugins

PluginSettings {
    pluginId: "onedriverMonitor"

    SelectionSetting {
        settingKey: "pollSeconds"
        label: "Intervalo de actualización"
        description: "Cada cuánto se consulta el estado de los montajes y sus logs"
        options: [
            { label: "2 segundos", value: "2" },
            { label: "5 segundos", value: "5" },
            { label: "10 segundos", value: "10" },
            { label: "30 segundos", value: "30" }
        ]
        defaultValue: "5"
    }

    ToggleSetting {
        settingKey: "showCache"
        label: "Mostrar uso de caché"
        description: "Muestra cuánto espacio local usa cada montaje"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showInactive"
        label: "Mostrar montajes detenidos"
        description: "Incluye cuentas configuradas aunque estén desmontadas"
        defaultValue: true
    }
}
