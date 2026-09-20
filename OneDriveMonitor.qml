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
    property string lastActionError: ""
    property string lastRefresh: ""
    property bool hasInitialSnapshot: false
    property var activityHistory: []
    property var pendingUnits: ({})
    property bool popoutVisible: false

    readonly property int pollIntervalMs: {
        if (popoutVisible)
            return 2500;
        if (transferCount > 0)
            return 4000;
        const seconds = Number((pluginData && pluginData.pollSeconds) || 10);
        return Math.max(5000, Math.min(60000, (isNaN(seconds) ? 10 : seconds) * 1000));
    }
    readonly property bool showCache: !pluginData || pluginData.showCache === undefined || pluginData.showCache === true || pluginData.showCache === "true"
    readonly property bool showInactive: !pluginData || pluginData.showInactive === undefined || pluginData.showInactive === true || pluginData.showInactive === "true"
    readonly property bool notifyStateChanges: !pluginData || pluginData.notifyStateChanges === undefined || pluginData.notifyStateChanges === true || pluginData.notifyStateChanges === "true"
    readonly property bool enableNautilus: !pluginData || pluginData.enableNautilus === undefined || pluginData.enableNautilus === true || pluginData.enableNautilus === "true"

    onEnableNautilusChanged: {
        if (!actionsPath) return;
        if (enableNautilus) {
            Quickshell.execDetached(["sh", actionsPath, "install-nautilus", "--restart"]);
        } else {
            Quickshell.execDetached(["sh", actionsPath, "uninstall-nautilus"]);
        }
    }

    readonly property string monitorPath: {
        const home = Quickshell.env("HOME") || "";
        return home ? home + "/.config/DankMaterialShell/plugins/OneDriveMonitor/monitor.sh" : "";
    }
    readonly property string actionsPath: {
        const home = Quickshell.env("HOME") || "";
        return home ? home + "/.config/DankMaterialShell/plugins/OneDriveMonitor/actions.sh" : "";
    }

    readonly property var visibleMounts: {
        if (showInactive)
            return mounts;
        return mounts.filter(mount => mount.active === "active" || mount.mounted === "1");
    }

    readonly property int activeCount: mounts.filter(mount => mount.active === "active" && mount.mounted === "1").length
    readonly property int transferCount: mounts.filter(mount => activityKind(mount) === "upload" || activityKind(mount) === "download").length
    readonly property bool hasProblem: mounts.some(mount => mount.active === "failed" || activityKind(mount) === "error" || activityKind(mount) === "offline")
    readonly property bool allActive: mounts.length > 0 && activeCount === mounts.length

    readonly property string summary: {
        if (mounts.length === 0)
            return "Sin cuentas vinculadas";
        if (hasProblem)
            return "Revisar estado";
        if (transferCount > 0)
            return transferCount === 1 ? "Transferencia activa" : transferCount + " transferencias";
        if (mounts.length === 1)
            return mountStatus(mounts[0]);
        return activeCount + "/" + mounts.length + " cuentas activas";
    }

    readonly property string barText: {
        if (mounts.length === 0)
            return "—";
        if (mounts.length === 1)
            return (mounts[0].active === "active" && mounts[0].mounted === "1") ? "Activo" : "Detenido";
        return activeCount + "/" + mounts.length;
    }

    function activityKind(mount) {
        const activity = ((mount && mount.activity) || "").toLowerCase();
        if (/upload|subiendo|uploaded|upload completed/.test(activity))
            return "upload";
        if (/download|descargando|download completed/.test(activity))
            return "download";
        if (/offline|read-only|solo lectura/.test(activity))
            return "offline";
        if (/error|failed|failure|falló/.test(activity))
            return "error";
        return "idle";
    }

    function activityIcon(mount) {
        switch (activityKind(mount)) {
        case "upload": return "cloud_upload";
        case "download": return "cloud_download";
        case "offline": return "cloud_off";
        case "error": return "error_outline";
        default:
            if (mount && mount.active === "active" && mount.mounted === "1") {
                return mount.accountType === "work" ? "business" : "cloud_done";
            }
            return "cloud_off";
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
        if (!mount) return "";
        const pending = pendingUnits[mount.encoded];
        if (pending) {
            if (pending === "starting") return "Iniciando servicio…";
            if (pending === "stopping") return "Deteniendo servicio…";
            if (pending === "restarting") return "Reiniciando…";
            if (pending === "clearing") return "Vaciando caché…";
            if (pending === "removing") return "Desvinculando…";
            return "Procesando…";
        }

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
        return "Nube: " + formatBytes(free) + " libres de " + formatBytes(total);
    }

    function openSettings() {
        root.closePopout();
        PopoutService.openSettingsWithTab("plugins");
    }

    function copyDiagnostics() {
        const lines = mounts.map(mount => {
            return [
                mount.label || mount.path,
                mount.accountType === "work" ? "Empresa/Educación" : "Personal",
                mountStatus(mount),
                "Inicio auto: " + (mount.enabled === "enabled" ? "activado" : "desactivado"),
                mount.path,
                "Caché: " + formatBytes(mount.cacheBytes) + " (" + (mount.cachedFilesCount || 0) + " archivos descargados)",
                mount.activity || "sin actividad reciente"
            ].join(" · ");
        });
        let reportParts = [
            "=== OneDrive Monitor Diagnostic Report ===",
            "Fecha: " + new Date().toLocaleString(),
            "Total cuentas: " + mounts.length + " (Activas: " + activeCount + ")",
            "Integración Nautilus: " + (root.enableNautilus ? "Habilitada" : "Deshabilitada")
        ];
        if (root.lastError) {
            reportParts.push("Error de sondeo: " + root.lastError);
        }
        if (root.lastActionError) {
            reportParts.push("Error de última acción: " + root.lastActionError);
        }
        reportParts.push("------------------------------------------");
        const report = reportParts.concat(lines).join("\n");

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

    function notifyStateChangesCheck(result, previous) {
        if (!hasInitialSnapshot || !notifyStateChanges)
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
        if (!mount || !actionsPath || actionProcess.running)
            return;

        const p = Object.assign({}, pendingUnits);
        p[mount.encoded] = verb === "start" ? "starting" : (verb === "stop" ? "stopping" : (verb === "restart" ? "restarting" : (verb === "clear-cache" ? "clearing" : (verb === "remove-mount" ? "removing" : "processing"))));
        pendingUnits = p;

        actionProcess.verb = verb;
        actionProcess.target = mount.encoded;
        actionProcess.command = ["sh", actionsPath, verb, mount.encoded];
        actionProcess.running = true;
    }

    function runBatchAction(verb) {
        if (!actionsPath || actionProcess.running)
            return;
        actionProcess.verb = verb;
        actionProcess.target = "";
        actionProcess.command = ["sh", actionsPath, verb];
        actionProcess.running = true;
    }

    function toggleMount(mount) {
        if (!mount) return;
        runAction(mount, mount.active === "active" ? "stop" : "start");
    }

    function toggleAutostart(mount) {
        if (!mount) return;
        runAction(mount, "toggle-autostart");
    }

    function clearCache(mount) {
        if (!mount) return;
        runAction(mount, "clear-cache");
    }

    function removeMount(mount) {
        if (!mount) return;
        runAction(mount, "remove-mount");
    }

    function openLauncher() {
        if (actionsPath) {
            Quickshell.execDetached(["sh", actionsPath, "open-launcher"]);
        }
    }

    function togglePrimaryMount() {
        if (mounts.length === 0) {
            openLauncher();
        } else if (mounts.length === 1) {
            toggleMount(mounts[0]);
        } else {
            if (activeCount > 0) {
                runBatchAction("unmount-all");
            } else {
                runBatchAction("mount-all");
            }
        }
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
                freeBytes: fields[12] || "0",
                accountType: fields[13] || "work",
                cachedFilesCount: Number(fields[14] || 0)
            });
        }
        result.sort((a, b) => (a.label || a.path).localeCompare(b.label || b.path));
        updateActivityHistory(result, previous);
        notifyStateChangesCheck(result, previous);
        mounts = result;
        pendingUnits = ({});
        hasInitialSnapshot = true;
        lastRefresh = Qt.formatTime(new Date(), "hh:mm:ss");
    }

    Component.onCompleted: {
        refresh();
        if (enableNautilus && actionsPath) {
            Quickshell.execDetached(["sh", actionsPath, "install-nautilus"]);
        }
    }

    Timer {
        interval: root.pollIntervalMs
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Timer {
        id: refreshDelay
        interval: 600
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
        property string verb: ""
        property string target: ""
        command: ["true"]

        stdout: StdioCollector { id: actionOutput; waitForEnd: true }
        stderr: StdioCollector { id: actionError; waitForEnd: true }

        onExited: exitCode => {
            if (exitCode !== 0) {
                const message = (actionError.text || actionOutput.text || "").trim().split("\n")[0];
                root.lastActionError = "Fallo en acción '" + actionProcess.verb + "': " + (message || ("código " + exitCode));
                ToastService.showError("OneDrive", message || ("Error al ejecutar " + actionProcess.verb));
            } else {
                root.lastActionError = "";
                switch (actionProcess.verb) {
                case "start":
                    ToastService.showInfo("OneDrive", "Montaje activado");
                    break;
                case "stop":
                    ToastService.showInfo("OneDrive", "Montaje detenido");
                    break;
                case "restart":
                    ToastService.showInfo("OneDrive", "Montaje reiniciado");
                    break;
                case "toggle-autostart":
                    ToastService.showInfo("OneDrive", "Inicio automático actualizado");
                    break;
                case "clear-cache":
                    ToastService.showInfo("OneDrive", "Caché local vaciada con éxito");
                    break;
                case "remove-mount":
                    ToastService.showInfo("OneDrive", "Cuenta desvinculada del sistema");
                    break;
                case "mount-all":
                    ToastService.showInfo("OneDrive", "Montando todas las cuentas…");
                    break;
                case "unmount-all":
                    ToastService.showInfo("OneDrive", "Todas las cuentas desmontadas");
                    break;
                default:
                    break;
                }
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

        function mountAll(): string {
            root.runBatchAction("mount-all");
            return "mounting-all";
        }

        function unmountAll(): string {
            root.runBatchAction("unmount-all");
            return "unmounting-all";
        }

        function launcher(): string {
            root.openLauncher();
            return "opened launcher";
        }

        function diagnostics(): string {
            root.copyDiagnostics();
            return "copied";
        }

        function status(): string {
            return JSON.stringify({
                summary: root.summary,
                mounts: root.mounts.length,
                activeCount: root.activeCount,
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

    popoutWidth: 500
    popoutHeight: 580
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
            Component.onCompleted: {
                root.popoutVisible = true;
                root.refresh();
            }
            Component.onDestruction: {
                root.popoutVisible = false;
            }
            headerText: "OneDrive"
            detailsText: root.lastError ? root.lastError : root.summary
            showCloseButton: true

            Column {
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: Theme.spacingM

                // Header toolbar: Status timestamp and Action Buttons
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

                        // Batch Action: Mount/Unmount All when 2 or more accounts exist
                        DankActionButton {
                            visible: root.mounts.length > 1
                            iconName: root.allActive ? "cloud_off" : "cloud_done"
                            iconColor: root.allActive ? Theme.warning : Theme.primary
                            buttonSize: 28
                            tooltipText: root.allActive ? "Desmontar todas las cuentas" : "Montar todas las cuentas"
                            onClicked: root.allActive ? root.runBatchAction("unmount-all") : root.runBatchAction("mount-all")
                        }

                        // Add / Manage Accounts via onedriver-launcher
                        DankActionButton {
                            iconName: "person_add"
                            iconColor: Theme.primary
                            buttonSize: 28
                            tooltipText: "Añadir o gestionar cuentas (onedriver-launcher)"
                            onClicked: root.openLauncher()
                        }

                        // Manual Refresh
                        DankActionButton {
                            iconName: "refresh"
                            iconColor: Theme.surfaceVariantText
                            buttonSize: 28
                            tooltipText: "Actualizar estado ahora"
                            onClicked: root.refresh()
                        }

                        // Copy Diagnostics
                        DankActionButton {
                            iconName: "content_copy"
                            iconColor: Theme.surfaceVariantText
                            buttonSize: 28
                            tooltipText: "Copiar diagnóstico completo"
                            onClicked: root.copyDiagnostics()
                        }

                        // Open Settings
                        DankActionButton {
                            iconName: "settings"
                            iconColor: Theme.surfaceVariantText
                            buttonSize: 28
                            tooltipText: "Ajustes de la extensión"
                            onClicked: root.openSettings()
                        }
                    }
                }

                // Mount Cards Scrollable Area
                Flickable {
                    width: parent.width
                    height: Math.max(100, root.popoutHeight - 160)
                    contentWidth: width
                    contentHeight: cards.implicitHeight
                    clip: true

                    Column {
                        id: cards
                        width: parent.width
                        spacing: Theme.spacingS

                        // Accounts List
                        Repeater {
                            model: root.visibleMounts

                            delegate: Item {
                                id: cardItem
                                required property var modelData
                                property var mount: modelData
                                property bool confirmDelete: false

                                width: cards.width
                                implicitHeight: cardBg.implicitHeight
                                height: implicitHeight

                                StyledRect {
                                    id: cardBg
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    radius: Theme.cornerRadius
                                    color: Theme.surfaceContainerHigh
                                    implicitHeight: cardContent.implicitHeight + (Theme.spacingM * 2)

                                    Column {
                                        id: cardContent
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        anchors.margins: Theme.spacingM
                                        spacing: Theme.spacingS

                                        // Row 1: Icon, Account Details & Autostart Toggle
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
                                                width: parent.width - 70
                                                spacing: 3
                                                anchors.verticalCenter: parent.verticalCenter

                                                StyledText {
                                                    width: parent.width
                                                    text: mount.label || mount.path
                                                    color: Theme.surfaceText
                                                    font.pixelSize: Theme.fontSizeMedium
                                                    font.weight: Font.DemiBold
                                                    elide: Text.ElideRight
                                                    maximumLineCount: 1
                                                }

                                                Row {
                                                    width: parent.width
                                                    spacing: Theme.spacingS

                                                    StyledText {
                                                        text: root.mountStatus(mount)
                                                        color: root.activityColor(mount)
                                                        font.pixelSize: Theme.fontSizeSmall
                                                        elide: Text.ElideRight
                                                        anchors.verticalCenter: parent.verticalCenter
                                                    }

                                                    // Badge for Account Type placed next to Conectado / Estado
                                                    StyledRect {
                                                        radius: 4
                                                        color: mount.accountType === "work" ? Theme.primaryContainer : Theme.surfaceContainerHighest
                                                        implicitWidth: badgeText.implicitWidth + 8
                                                        implicitHeight: 18
                                                        anchors.verticalCenter: parent.verticalCenter

                                                        StyledText {
                                                            id: badgeText
                                                            anchors.centerIn: parent
                                                            text: mount.accountType === "work" ? "Educación / Empresa" : "Personal"
                                                            color: mount.accountType === "work" ? Theme.primary : Theme.surfaceVariantText
                                                            font.pixelSize: Theme.fontSizeSmall - 2
                                                            font.weight: Font.Medium
                                                        }
                                                    }
                                                }
                                            }

                                            // Autostart on boot button
                                            DankActionButton {
                                                iconName: mount.enabled === "enabled" ? "bolt" : "power_settings_new"
                                                iconColor: mount.enabled === "enabled" ? Theme.primary : Theme.surfaceVariantText
                                                buttonSize: 26
                                                tooltipText: mount.enabled === "enabled" ? "Inicio automático activado (clic para desactivar)" : "Inicio automático desactivado (clic para activar)"
                                                onClicked: root.toggleAutostart(mount)
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                        }

                                        // Row 2: Local Mountpoint path
                                        StyledText {
                                            width: parent.width
                                            text: mount.path
                                            color: Theme.surfaceVariantText
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            elide: Text.ElideMiddle
                                        }

                                        // Row 3: Cache size and Cloud Quota
                                        Row {
                                            visible: root.showCache || !!root.quotaText(mount)
                                            width: parent.width
                                            spacing: Theme.spacingS

                                            StyledText {
                                                text: {
                                                    let parts = [];
                                                    if (root.showCache) {
                                                        let cText = "Caché local: " + root.formatBytes(mount.cacheBytes);
                                                        if (mount.cachedFilesCount !== undefined && mount.cachedFilesCount >= 0) {
                                                            cText += " (" + mount.cachedFilesCount + " " + (mount.cachedFilesCount === 1 ? "archivo descargado)" : "archivos descargados)");
                                                        }
                                                        parts.push(cText);
                                                    }
                                                    const q = root.quotaText(mount);
                                                    if (q) {
                                                        parts.push(q);
                                                    }
                                                    return parts.join("  ·  ");
                                                }
                                                color: Theme.surfaceVariantText
                                                font.pixelSize: Theme.fontSizeSmall
                                                width: parent.width
                                                elide: Text.ElideRight
                                            }
                                        }

                                        // Row 4: Live Activity string if available
                                        Row {
                                            visible: !!mount.activity
                                            width: parent.width
                                            spacing: Theme.spacingXS

                                            DankIcon {
                                                name: "sync"
                                                size: 14
                                                color: Theme.primary
                                                anchors.verticalCenter: parent.verticalCenter
                                            }

                                            StyledText {
                                                text: mount.activity
                                                color: Theme.surfaceVariantText
                                                font.pixelSize: Theme.fontSizeSmall
                                                width: parent.width - 20
                                                elide: Text.ElideRight
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                        }

                                        // Row 5: Action Buttons or Confirmation Bar
                                        Item {
                                            width: parent.width
                                            height: 32

                                            // Default action buttons
                                            Row {
                                                visible: !cardItem.confirmDelete
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
                                                    tooltipText: "Abrir carpeta en el gestor de archivos"
                                                    onClicked: root.openMount(mount)
                                                }

                                                DankActionButton {
                                                    iconName: "cleaning_services"
                                                    iconColor: Theme.surfaceVariantText
                                                    buttonSize: 28
                                                    tooltipText: "Vaciar archivos de la caché local (sin perder la cuenta)"
                                                    onClicked: root.clearCache(mount)
                                                }

                                                DankActionButton {
                                                    iconName: "delete_outline"
                                                    iconColor: Theme.error
                                                    buttonSize: 28
                                                    tooltipText: "Desvincular cuenta del equipo"
                                                    onClicked: cardItem.confirmDelete = true
                                                }
                                            }

                                            // In-place confirmation for removing the account
                                            Row {
                                                visible: cardItem.confirmDelete
                                                anchors.right: parent.right
                                                spacing: Theme.spacingS

                                                StyledText {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: "¿Desvincular esta cuenta?"
                                                    color: Theme.error
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    font.weight: Font.Medium
                                                }

                                                DankButton {
                                                    text: "Sí, desvincular"
                                                    onClicked: {
                                                        cardItem.confirmDelete = false;
                                                        root.removeMount(mount);
                                                    }
                                                }

                                                DankActionButton {
                                                    iconName: "close"
                                                    buttonSize: 28
                                                    tooltipText: "Cancelar"
                                                    onClicked: cardItem.confirmDelete = false
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Empty State View when no mounts are configured
                        StyledRect {
                            visible: root.visibleMounts.length === 0
                            width: cards.width
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh
                            implicitHeight: emptyCol.implicitHeight + Theme.spacingM * 2

                            Column {
                                id: emptyCol
                                anchors.centerIn: parent
                                spacing: Theme.spacingM
                                width: parent.width - 32

                                DankIcon {
                                    name: "cloud_off"
                                    size: Theme.iconSizeLarge
                                    color: Theme.surfaceVariantText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                }

                                Column {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    spacing: 4
                                    width: parent.width

                                    StyledText {
                                        text: "No hay cuentas de OneDrive configuradas"
                                        color: Theme.surfaceText
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.DemiBold
                                        horizontalAlignment: Text.AlignHCenter
                                        width: parent.width
                                    }

                                    StyledText {
                                        text: "Vincula tu cuenta personal o de empresa/estudio usando onedriver."
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall
                                        horizontalAlignment: Text.AlignHCenter
                                        width: parent.width
                                        wrapMode: Text.WordWrap
                                    }
                                }

                                DankButton {
                                    text: "Vincular nueva cuenta"
                                    iconName: "add"
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    onClicked: root.openLauncher()
                                }
                            }
                        }

                        // Recent Activity Log
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
