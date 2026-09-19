import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    property var popoutService: null
    property var mounts: []
    property bool refreshInFlight: false
    property string lastError: ""
    property string lastRefresh: ""
    property bool hasInitialSnapshot: false
    property var activityHistory: []

    readonly property int pollIntervalMs: {
        const seconds = Number((pluginData && pluginData.pollSeconds) || 5);
        return Math.max(2000, Math.min(30000, (isNaN(seconds) ? 5 : seconds) * 1000));
    }
    readonly property bool showCache: !pluginData || pluginData.showCache === undefined || pluginData.showCache === true || pluginData.showCache === "true"
    readonly property bool showInactive: !pluginData || pluginData.showInactive === undefined || pluginData.showInactive === true || pluginData.showInactive === "true"
    readonly property string monitorPath: {
        const home = Quickshell.env("HOME") || "";
        return home ? home + "/.config/DankMaterialShell/plugins/OneDriveMonitor/monitor.sh" : "";
    }
    readonly property var visibleMounts: {
        if (showInactive)
            return mounts;
        return mounts.filter(mount => mount.active === "active" || mount.mounted === "1");
    }
    readonly property int activeCount: mounts.filter(mount => mount.active === "active" && mount.mounted === "1").length
    readonly property int transferCount: mounts.filter(mount => activityKind(mount) === "upload" || activityKind(mount) === "download").length
    readonly property bool hasProblem: mounts.some(mount => mount.active === "failed" || activityKind(mount) === "error" || activityKind(mount) === "offline")
    readonly property string summary: {
        if (mounts.length === 0)
            return "Sin montajes";
        if (hasProblem)
            return "Revisar estado";
        if (transferCount > 0)
            return transferCount === 1 ? "Transferencia activa" : transferCount + " transferencias";
        return activeCount + "/" + mounts.length + " montajes activos";
    }
    readonly property string barText: mounts.length === 0 ? "—" : activeCount + "/" + mounts.length

    function activityKind(mount) {
        const activity = ((mount && mount.activity) || "").toLowerCase();
        if (/upload|subiendo|uploaded|upload completed/.test(activity))
            return "upload";
        if (/download|descargando|download completed/.test(activity))
            return "download";
        if (/offline|read-only|solo lectura/.test(activity))
            return "offline";
        if (/error|failed|failure|falló|failed/.test(activity))
            return "error";
        return "idle";
    }

    function activityIcon(mount) {
        switch (activityKind(mount)) {
        case "upload": return "cloud_upload";
        case "download": return "cloud_download";
        case "offline": return "cloud_off";
        case "error": return "error_outline";
        default: return mount && mount.active === "active" && mount.mounted === "1" ? "cloud_done" : "cloud_off";
        }
    }

    function activityColor(mount) {
        switch (activityKind(mount)) {
        case "upload":
        case "download": return Theme.primary;
        case "offline": return Theme.warning;
        case "error": return Theme.error;
        default: return mount && mount.active === "active" && mount.mounted === "1" ? Theme.success : Theme.surfaceVariantText;
        }
    }

    function mountStatus(mount) {
        const kind = activityKind(mount);
        if (mount.active === "failed")
            return "Servicio con errores";
        if (kind === "offline")
            return "Sin conexión · solo lectura";
        if (mount.active === "active" && mount.mounted === "1") {
            if (kind === "upload") return "Subiendo cambios";
            if (kind === "download") return "Descargando contenido";
            if (mount.subState && mount.subState !== "running") return mount.subState;
            return "Conectado";
        }
        if (mount.active === "activating" || mount.subState === "start")
            return "Montando…";
        return "Desmontado";
    }

    function formatBytes(value) {
        let bytes = Number(value || 0);
        if (!isFinite(bytes) || bytes <= 0)
            return "0 B";
        const units = ["B", "KB", "MB", "GB", "TB"];
        let unit = 0;
        while (bytes >= 1024 && unit < units.length - 1) {
            bytes /= 1024;
            unit++;
        }
        return (unit === 0 ? Math.round(bytes) : bytes.toFixed(bytes >= 100 ? 0 : 1)) + " " + units[unit];
    }

    function quotaText(mount) {
        const total = Number((mount && mount.totalBytes) || 0);
        const free = Number((mount && mount.freeBytes) || 0);
        if (!isFinite(total) || total <= 0 || !isFinite(free))
            return "";
        return "Libre " + formatBytes(free) + " / " + formatBytes(total);
    }

    function openSettings() {
        root.closePopout();
        PopoutService.openSettingsWithTab("plugins");
    }

    function copyDiagnostics() {
        const lines = mounts.map(mount => {
            return [mount.label || mount.path, mountStatus(mount), mount.path, mount.activity || "sin actividad"].join(" · ");
        });
        const report = ["OneDrive Monitor", "Actualizado: " + (lastRefresh || "—")].concat(lines).join("\n");
        Quickshell.execDetached(["dms", "cl", "copy", report]);
        ToastService.showInfo("Informe copiado al portapapeles");
    }

    function updateActivityHistory(result, previous) {
        if (!hasInitialSnapshot)
            return;
        let next = activityHistory.slice();
        result.forEach(mount => {
            const old = previous.find(item => item.encoded === mount.encoded);
            const kind = activityKind(mount);
            if (mount.activity && kind !== "idle" && (!old || old.activity !== mount.activity)) {
                next.unshift({
                    label: mount.label || mount.path,
                    text: mount.activity,
                    time: Qt.formatTime(new Date(), "hh:mm:ss"),
                    kind: kind
                });
            }
        });
        activityHistory = next.slice(0, 8);
    }

    function notifyStateChanges(result, previous) {
        if (!hasInitialSnapshot)
            return;
        result.forEach(mount => {
            const old = previous.find(item => item.encoded === mount.encoded);
            if (!old)
                return;
            if (mount.active === "failed" && old.active !== "failed") {
                ToastService.showError("OneDrive", (mount.label || mount.path) + " ha fallado");
            } else if (activityKind(mount) === "offline" && activityKind(old) !== "offline") {
                ToastService.showWarning("OneDrive", (mount.label || mount.path) + " está offline");
            } else if (activityKind(old) === "offline" && activityKind(mount) === "idle") {
                ToastService.showInfo("OneDrive", (mount.label || mount.path) + " vuelve a estar online");
            }
        });
    }

    function refresh() {
        if (refreshInFlight || !monitorPath)
            return;
        refreshInFlight = true;
        monitorProcess.running = true;
    }

    function refreshAfterAction() {
        refreshDelay.restart();
    }

    function runAction(mount, verb) {
        if (!mount || actionProcess.running)
            return;
        actionProcess.unit = mount.unit;
        actionProcess.verb = verb;
        actionProcess.running = true;
    }

    function toggleMount(mount) {
        runAction(mount, mount.active === "active" ? "stop" : "start");
    }

    function togglePrimaryMount() {
        if (mounts.length > 0)
            toggleMount(mounts[0]);
    }

    function openMount(mount) {
        if (mount && mount.path)
            Quickshell.execDetached(["xdg-open", mount.path]);
    }

    function parseStatus(output) {
        const result = [];
        const previous = mounts.slice();
        const lines = (output || "").trim().split("\n");
        for (const line of lines) {
            if (!line.trim())
                continue;
            const fields = line.split("\t");
            if (fields.length < 11)
                continue;
            result.push({
                unit: fields[0],
                encoded: fields[1],
                path: fields[2],
                label: fields[3] || fields[2],
                account: fields[4] || "",
                active: fields[5] || "inactive",
                subState: fields[6] || "",
                enabled: fields[7] || "disabled",
                mounted: fields[8] || "0",
                cacheBytes: fields[9] || "0",
                activity: fields[10] || "",
                totalBytes: fields[11] || "0",
                freeBytes: fields[12] || "0"
            });
        }
        result.sort((a, b) => (a.label || a.path).localeCompare(b.label || b.path));
        updateActivityHistory(result, previous);
        notifyStateChanges(result, previous);
        mounts = result;
        hasInitialSnapshot = true;
        lastRefresh = Qt.formatTime(new Date(), "hh:mm:ss");
    }

    Component.onCompleted: refresh()

    Timer {
        interval: root.pollIntervalMs
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Timer {
        id: refreshDelay
        interval: 700
        repeat: false
        onTriggered: root.refresh()
    }

    Process {
        id: monitorProcess
        command: root.monitorPath ? ["sh", root.monitorPath] : ["true"]

        stdout: StdioCollector {
            id: monitorOutput
            waitForEnd: true
        }

        stderr: StdioCollector {
            id: monitorError
            waitForEnd: true
        }

        onExited: exitCode => {
            root.refreshInFlight = false;
            if (exitCode === 0) {
                root.lastError = "";
                root.parseStatus(monitorOutput.text);
            } else {
                root.lastError = (monitorError.text || "No se pudo consultar onedriver").trim().split("\n")[0];
            }
        }
    }

    Process {
        id: actionProcess
        property string unit: ""
        property string verb: ""
        command: ["systemctl", "--user", verb, unit]

        stdout: StdioCollector { id: actionOutput; waitForEnd: true }
        stderr: StdioCollector { id: actionError; waitForEnd: true }

        onExited: exitCode => {
            if (exitCode !== 0) {
                const message = (actionError.text || actionOutput.text || "").trim().split("\n")[0];
                ToastService.showError("OneDrive", message || ("No se pudo ejecutar " + verb));
            } else {
                ToastService.showInfo(verb === "restart" ? "Montaje reiniciado" : (verb === "start" ? "Montaje activado" : "Montaje detenido"));
            }
            root.refreshAfterAction();
        }
    }

    IpcHandler {
        target: "onedriver"

        function popout(): string {
            root.triggerPopout();
            return "opened";
        }

        function refresh(): string {
            root.refresh();
            return root.summary;
        }

        function toggle(): string {
            root.togglePrimaryMount();
            return root.summary;
        }

        function restart(): string {
            if (root.mounts.length > 0)
                root.runAction(root.mounts[0], "restart");
            return "restarting";
        }

        function diagnostics(): string {
            root.copyDiagnostics();
            return "copied";
        }

        function status(): string {
            return JSON.stringify({
                summary: root.summary,
                mounts: root.mounts.length,
                lastError: root.lastError,
                monitorPath: root.monitorPath
            });
        }
    }

    ccWidgetIcon: "cloud_sync"
    ccWidgetPrimaryText: "OneDrive"
    ccWidgetSecondaryText: root.summary
    ccWidgetIsActive: root.activeCount > 0
    ccWidgetIsToggle: true
    onCcWidgetToggled: root.togglePrimaryMount()

    popoutWidth: 480
    popoutHeight: 560
    pillRightClickAction: () => root.openSettings()

    horizontalBarPill: Component {
        Item {
            implicitWidth: barContent.implicitWidth
            implicitHeight: root.widgetThickness
            width: implicitWidth
            height: implicitHeight

            Row {
                id: barContent
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                DankIcon {
                    name: root.transferCount > 0 ? "cloud_sync" : "cloud"
                    size: Theme.iconSizeSmall
                    color: root.hasProblem ? Theme.warning : Theme.widgetIconColor
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: root.barText
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeSmall
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    verticalBarPill: Component {
        Item {
            implicitWidth: root.widgetThickness
            implicitHeight: barContent.implicitHeight
            width: implicitWidth
            height: implicitHeight

            Column {
                id: barContent
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                DankIcon {
                    name: root.transferCount > 0 ? "cloud_sync" : "cloud"
                    size: Theme.iconSizeSmall
                    color: root.hasProblem ? Theme.warning : Theme.widgetIconColor
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                StyledText {
                    text: root.barText
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeSmall
                    rotation: 90
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }
    }

    popoutContent: Component {
        PopoutComponent {
            headerText: "OneDrive"
            detailsText: root.lastError ? root.lastError : root.summary
            showCloseButton: true

            Column {
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: Theme.spacingM

                Item {
                    width: parent.width
                    height: 32

                    StyledText {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.lastRefresh ? "Actualizado " + root.lastRefresh : "Consultando…"
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingXS

                        DankActionButton {
                            iconName: "refresh"
                            iconColor: Theme.surfaceVariantText
                            buttonSize: 28
                            tooltipText: "Actualizar estado"
                            onClicked: root.refresh()
                        }

                        DankActionButton {
                            iconName: "settings"
                            iconColor: Theme.surfaceVariantText
                            buttonSize: 28
                            tooltipText: "Ajustes de extensiones"
                            onClicked: root.openSettings()
                        }

                        DankActionButton {
                            iconName: "content_copy"
                            iconColor: Theme.surfaceVariantText
                            buttonSize: 28
                            tooltipText: "Copiar diagnóstico"
                            onClicked: root.copyDiagnostics()
                        }
                    }
                }

                Flickable {
                    width: parent.width
                    height: Math.max(80, root.popoutHeight - 150)
                    contentWidth: width
                    contentHeight: cards.implicitHeight
                    clip: true

                    Column {
                        id: cards
                        width: parent.width
                        spacing: Theme.spacingS

                        Repeater {
                            model: root.visibleMounts

                            delegate: Item {
                                required property var modelData
                                property var mount: modelData
                                width: cards.width
                                height: mount.activity ? 164 : 144

                                StyledRect {
                                    anchors.fill: parent
                                    radius: Theme.cornerRadius
                                    color: Theme.surfaceContainerHigh

                                    Column {
                                        anchors.fill: parent
                                        anchors.margins: Theme.spacingM
                                        spacing: Theme.spacingXS

                                        Row {
                                            width: parent.width
                                            spacing: Theme.spacingS

                                            DankIcon {
                                                name: root.activityIcon(mount)
                                                size: Theme.iconSize
                                                color: root.activityColor(mount)
                                                anchors.verticalCenter: parent.verticalCenter
                                            }

                                            Column {
                                                width: parent.width - 86
                                                spacing: 1

                                                StyledText {
                                                    width: parent.width
                                                    text: mount.label || mount.path
                                                    color: Theme.surfaceText
                                                    font.pixelSize: Theme.fontSizeMedium
                                                    font.weight: Font.DemiBold
                                                    elide: Text.ElideRight
                                                }

                                                StyledText {
                                                    width: parent.width
                                                    text: root.mountStatus(mount)
                                                    color: root.activityColor(mount)
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    elide: Text.ElideRight
                                                }
                                            }
                                        }

                                        StyledText {
                                            width: parent.width
                                            text: mount.path
                                            color: Theme.surfaceVariantText
                                            font.pixelSize: Theme.fontSizeSmall
                                            elide: Text.ElideMiddle
                                        }

                                        StyledText {
                                            visible: !!mount.activity
                                            width: parent.width
                                            text: mount.activity
                                            color: Theme.surfaceVariantText
                                            font.pixelSize: Theme.fontSizeSmall
                                            elide: Text.ElideRight
                                        }

                                        Row {
                                            width: parent.width
                                            spacing: Theme.spacingS

                                            StyledText {
                                                visible: root.showCache || !!root.quotaText(mount)
                                                text: root.showCache
                                                      ? "Caché " + root.formatBytes(mount.cacheBytes)
                                                        + (root.quotaText(mount) ? " · " + root.quotaText(mount) : "")
                                                      : root.quotaText(mount)
                                                color: Theme.surfaceVariantText
                                                font.pixelSize: Theme.fontSizeSmall
                                                width: parent.width
                                                elide: Text.ElideRight
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                        }

                                        Row {
                                            anchors.right: parent.right
                                            spacing: Theme.spacingS

                                            DankButton {
                                                text: mount.active === "active" ? "Desmontar" : "Montar"
                                                onClicked: root.toggleMount(mount)
                                            }

                                            DankActionButton {
                                                iconName: "restart_alt"
                                                iconColor: Theme.surfaceVariantText
                                                buttonSize: 28
                                                tooltipText: "Reiniciar montaje"
                                                onClicked: root.runAction(mount, "restart")
                                            }

                                            DankActionButton {
                                                iconName: "folder_open"
                                                iconColor: Theme.surfaceVariantText
                                                buttonSize: 28
                                                tooltipText: "Abrir carpeta"
                                                onClicked: root.openMount(mount)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Item {
                            visible: root.visibleMounts.length === 0
                            width: cards.width
                            height: 100

                            Column {
                                anchors.centerIn: parent
                                spacing: Theme.spacingS

                                DankIcon {
                                    name: "cloud_off"
                                    size: Theme.iconSizeLarge
                                    color: Theme.surfaceVariantText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }

                                StyledText {
                                    text: "No hay montajes de onedriver configurados"
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }
                            }
                        }

                        Column {
                            visible: root.activityHistory.length > 0
                            width: cards.width
                            spacing: Theme.spacingXS

                            StyledText {
                                text: "Actividad reciente"
                                color: Theme.surfaceText
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.DemiBold
                            }

                            Repeater {
                                model: root.activityHistory.slice(0, 4)

                                delegate: Item {
                                    required property var modelData
                                    width: cards.width
                                    height: 28

                                    Row {
                                        anchors.fill: parent
                                        spacing: Theme.spacingS

                                        StyledText {
                                            text: modelData.time
                                            color: Theme.surfaceVariantText
                                            font.pixelSize: Theme.fontSizeSmall
                                            width: 48
                                        }

                                        StyledText {
                                            text: modelData.label + " · " + modelData.text
                                            color: Theme.surfaceText
                                            font.pixelSize: Theme.fontSizeSmall
                                            width: parent.width - 48 - Theme.spacingS
                                            elide: Text.ElideRight
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
