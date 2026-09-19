# OneDrive Monitor

DankMaterialShell widget for [onedriver](https://github.com/jstaf/onedriver).

This first version is designed to be portable between machines:

- It discovers the user's onedriver mounts automatically.
- It never stores account names, mount paths or tokens in plugin settings.
- It reads service state and recent user-journal messages locally.
- It controls only the current user's systemd services.
- Preferences are stored by DankMaterialShell per user.

## Features

- Active, stopped, failed and offline mount status.
- Recent upload/download/error activity from onedriver logs.
- Short activity history for the current session.
- Cache size per mount.
- Filesystem free-space information when onedriver exposes it.
- Mount, unmount and restart actions.
- Open mountpoint in the default file manager.
- State-change notifications and a copyable diagnostic report.
- Optional display of inactive configured mounts.
- Automatic support for multiple accounts/mountpoints.
- DMS IPC commands for status, refresh, toggle, restart and diagnostics.

## Limitations

onedriver does not expose a public transfer-status API. Progress is therefore
best-effort and is inferred from its journal messages. The widget does not read
or display access/refresh tokens.

## Install locally

Copy this directory to:

```text
~/.config/DankMaterialShell/plugins/OneDriveMonitor/
```

Then scan/reload plugins:

```bash
dms ipc plugin-scan scan
dms ipc plugin-scan rescan onedriverMonitor
```
