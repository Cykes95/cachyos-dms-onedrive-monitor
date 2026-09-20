import QtQuick
import qs.Common

QtObject {
    function check(done) {
        Proc.runCommand(
            "onedriverMonitor.dependencyCheck",
            ["sh", "-c", "missing=''; for c in onedriver systemctl journalctl findmnt xdg-open; do command -v \"$c\" >/dev/null 2>&1 || missing=\"$missing $c\"; done; if [ -n \"$missing\" ]; then echo \"$missing\"; exit 1; fi"],
            (stdout, exitCode) => {
                if (exitCode === 0) {
                    done(null);
                    return;
                }

                const missingList = (stdout || "").trim().split(/\s+/).join(", ");
                done({
                    title: "Dependencias no encontradas",
                    details: "Se requieren las siguientes herramientas en el sistema: " + (missingList || "onedriver") + "."
                });
            }
        );
    }
}
