import QtQuick
import qs.Common

QtObject {
    function check(done) {
        Proc.runCommand(
            "onedriverMonitor.dependencyCheck",
            ["sh", "-c", "command -v onedriver >/dev/null && command -v systemctl >/dev/null && command -v journalctl >/dev/null && command -v findmnt >/dev/null && command -v xdg-open >/dev/null"],
            (stdout, exitCode) => {
                if (exitCode === 0) {
                    done(null);
                    return;
                }

                done({
                    title: "OneDrive Monitor necesita onedriver",
                    details: "Instala onedriver y vuelve a activar el plugin."
                });
            }
        );
    }
}
