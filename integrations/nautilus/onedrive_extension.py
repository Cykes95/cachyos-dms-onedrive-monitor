#!/usr/bin/env python3
"""
OneDrive Nautilus Extension
- Displays cloud and synced emblems (onedrive-custom-cloud / onedrive-custom-synced)
- Provides context menu to "Liberar espacio local" and safe file-only downloads
- Powered by onedrive_core (transactional bbolt B+ tree parser, remote size checks, active FUSE detection)
"""

import os
import sys
import time
import threading
import subprocess
import unicodedata
import urllib.parse
import weakref
import gi

gi.require_version('Nautilus', '4.1')
from gi.repository import Nautilus, GObject, GLib, Gio

# Ensure onedrive_core can be imported whether installed or run from source tree
_this_dir = os.path.dirname(os.path.abspath(__file__))
if _this_dir not in sys.path:
    sys.path.insert(0, _this_dir)

try:
    import onedrive_core
except ImportError:
    _alt_dir = os.path.expanduser("~/.local/share/nautilus-python/extensions")
    if _alt_dir not in sys.path:
        sys.path.insert(0, _alt_dir)
    import onedrive_core

def _notify(title: str, message: str, icon: str = "onedrive-custom-cloud"):
    try:
        subprocess.Popen(["notify-send", "-a", "OneDrive", "-i", icon, title, message])
    except Exception:
        pass


def _publish_manual_download_activity(encoded: str, operation_id: str, state: str, name: str):
    """Publish a bounded, user-initiated download event for the DMS widget.

    OneDriver's journal cannot identify the FUSE client that opened a file: a
    thumbnailer produces exactly the same download messages as the explicit
    Nautilus menu action.  This private runtime file is therefore the only
    source used by the widget for download activity.
    """
    if not encoded or "/" in encoded or encoded in (".", ".."):
        return
    if state not in ("downloading", "completed", "available", "partial", "failed"):
        return
    if not operation_id or not all(c.isalnum() or c in "_-" for c in operation_id):
        return

    runtime_base = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    runtime_dir = os.path.join(runtime_base, "onedriver_dms")
    try:
        os.makedirs(runtime_dir, mode=0o700, exist_ok=True)
        os.chmod(runtime_dir, 0o700)
        event_path = os.path.join(runtime_dir, f"manual_activity_{encoded}.tmp")
        safe_name = urllib.parse.quote(str(name), safe="")
        payload = f"v1\t{int(time.time())}\t{state}\t{operation_id}\t{safe_name}\n"
        temp_path = f"{event_path}.{os.getpid()}.{threading.get_ident()}"
        fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            with os.fdopen(fd, "w", encoding="ascii") as event_file:
                event_file.write(payload)
            os.replace(temp_path, event_path)
        except Exception:
            try:
                os.unlink(temp_path)
            except OSError:
                pass
    except OSError:
        # Activity reporting is optional; never make a manual download fail for it.
        pass


def _download_activity_label(items: list) -> str:
    if len(items) == 1:
        rel_path = items[0][6] or items[0][1]
        return os.path.basename(rel_path.rstrip("/")) or rel_path
    return f"{len(items)} elementos"

class OneDriveExtension(GObject.GObject, Nautilus.InfoProvider, Nautilus.MenuProvider):
    def __init__(self):
        super().__init__()
        self._sync_lock = threading.Lock()
        self._active_files_lock = threading.Lock()
        self._active_files = {}  # file_path -> Nautilus.FileInfo
        self._pending_updates_lock = threading.Lock()
        self._pending_updates = {}  # handle -> (closure, provider, handle, file, file_path, mp, mount_info)
        self.cache_base = onedrive_core.get_cache_base()
        self.mounts = {}
        self.last_mount_check = 0
        self.syncing_paths = set()
        self._refresh_mounts()
        try:
            GLib.timeout_add_seconds(5, self._periodic_check)
        except Exception:
            pass

    def _register_active_file(self, file_path: str, file_info: Nautilus.FileInfo):
        with self._active_files_lock:
            self._active_files[file_path] = file_info
            if len(self._active_files) > 4000:
                for k in list(self._active_files.keys())[:2000]:
                    del self._active_files[k]

    def _invalidate_active_files_for_mount(self, mp: str):
        with self._active_files_lock:
            targets = [f for path, f in self._active_files.items() if path == mp or path.startswith(mp + "/")]
        for f in targets:
            try:
                f.invalidate_extension_info()
            except Exception:
                pass

    def _on_content_dir_changed(self, monitor, file, other_file, event_type, mount_info):
        if event_type in (
            Gio.FileMonitorEvent.CHANGES_DONE_HINT,
            Gio.FileMonitorEvent.CREATED,
            Gio.FileMonitorEvent.DELETED,
            Gio.FileMonitorEvent.ATTRIBUTE_CHANGED
        ):
            if file:
                name = file.get_basename() or ""
                if name.startswith(("temp-", ".tmp", ".fuse_hidden")) or name.endswith((".tmp", "~")):
                    return

            with mount_info["lock"]:
                mount_info["content_dirty"] = True
                timer_id = mount_info.get("reload_timer_id")
                if timer_id:
                    GLib.source_remove(timer_id)
                mount_info["reload_timer_id"] = GLib.timeout_add(150, self._trigger_content_reload, mount_info)

    def _trigger_content_reload(self, mount_info):
        with mount_info["lock"]:
            mount_info["reload_timer_id"] = None
        self._load_db_if_needed(mount_info, force_content=True, invalidate_all_active=True)
        return False

    def _periodic_check(self):
        try:
            self._refresh_mounts()
            for mp, info in list(self.mounts.items()):
                self._load_db_if_needed(info)
        except Exception:
            pass
        return True

    def _refresh_mounts(self):
        now = time.monotonic()
        if now - self.last_mount_check < 10.0 and self.mounts:
            return
        self.last_mount_check = now

        if not os.path.isdir(self.cache_base):
            self.mounts.clear()
            return

        active_fuse_mounts = onedrive_core.get_active_fuse_mounts()
        discovered_mps = set()

        try:
            entries = os.listdir(self.cache_base)
        except OSError:
            entries = []

        for entry in entries:
            if entry in ("CacheStorage", "WebKitCache"):
                continue
            entry_path = os.path.join(self.cache_base, entry)
            token_file = os.path.join(entry_path, "auth_tokens.json")
            if os.path.isdir(entry_path) and os.path.isfile(token_file):
                mp = onedrive_core.unescape_systemd(entry)
                # Verify that the mountpoint exists and is an ACTIVE FUSE mount (B7)
                if os.path.isdir(mp) and (mp in active_fuse_mounts):
                    discovered_mps.add(mp)
                    if mp in self.mounts:
                        # Update existing dictionary in-place to prevent stranding workers (B3)
                        m = self.mounts[mp]
                        m["mp"] = mp
                        m["cache_dir"] = entry_path
                        m["db_path"] = os.path.join(entry_path, "onedriver.db")
                        m["content_dir"] = os.path.join(entry_path, "content")
                        m["encoded"] = entry
                    else:
                        m = {
                            "mp": mp,
                            "cache_dir": entry_path,
                            "db_path": os.path.join(entry_path, "onedriver.db"),
                            "content_dir": os.path.join(entry_path, "content"),
                            "encoded": entry,
                            "snapshot": None,
                            "db_ready": False,
                            "loading_db": False,
                            "content_dirty": False,
                            "mtime": 0,
                            "content_mtime": 0,
                            "last_error_time": 0,
                            "txid": 0,
                            "pending_invalidation": set(),
                            "lock": threading.Lock()
                        }
                        self.mounts[mp] = m
                        # Preload snapshot immediately on discovery (takes only 15ms)
                        # so the very first update_file_info call has data!
                        self._load_db_if_needed(m)

                    if "monitor" not in m and os.path.isdir(m["content_dir"]):
                        try:
                            gf = Gio.File.new_for_path(m["content_dir"])
                            mon = gf.monitor_directory(Gio.FileMonitorFlags.NONE, None)
                            mon.connect("changed", self._on_content_dir_changed, m)
                            m["monitor"] = mon
                        except Exception:
                            pass

        # Remove unmounted or deleted accounts
        for stale_mp in list(self.mounts.keys()):
            if stale_mp not in discovered_mps:
                stale_info = self.mounts.pop(stale_mp, None)
                if stale_info and "monitor" in stale_info:
                    try:
                        stale_info["monitor"].cancel()
                    except Exception:
                        pass

    def _load_db_if_needed(self, mount_info: dict, file_or_files=None, force=False, force_content=False, force_db=False, invalidate_all_active=False):
        mp = mount_info.get("mountpoint", mount_info.get("mp", ""))
        db_path = mount_info["db_path"]
        content_dir = mount_info["content_dir"]

        with mount_info["lock"]:
            if not os.path.isfile(db_path) or os.path.getsize(db_path) == 0:
                mount_info["db_ready"] = False
                return

            now = time.time()
            if not (force or force_content or force_db) and (now - mount_info.get("last_error_time", 0) < 3.0):
                # Backoff after recent error to prevent busy loops
                return

            try:
                db_mtime = os.path.getmtime(db_path)
            except OSError:
                return

            try:
                content_mtime = os.path.getmtime(content_dir) if os.path.isdir(content_dir) else 0
            except OSError:
                content_mtime = 0

            need_db_reload = force or force_db or (db_mtime > mount_info.get("mtime", 0)) or not mount_info.get("db_ready")
            need_content_refresh = force or force_content or (content_mtime > mount_info.get("content_mtime", 0))

            if not need_db_reload and not need_content_refresh:
                return

            if mount_info["loading_db"]:
                mount_info["content_dirty"] = True
                # Only register interested FileInfo when a load is actively occurring
                if file_or_files:
                    if isinstance(file_or_files, (list, set, tuple)):
                        mount_info["pending_invalidation"].update(f for f in file_or_files if isinstance(f, Nautilus.FileInfo))
                    elif isinstance(file_or_files, Nautilus.FileInfo):
                        mount_info["pending_invalidation"].add(file_or_files)
                return

            # Synchronous fast-path on initial load:
            # Read metadata only (content_dir=None, NO hash computation, no freeze)
            # so the very first Nautilus render receives emblems immediately!
            if mount_info.get("snapshot") is None:
                try:
                    snapshot = onedrive_core.read_bbolt_db(db_path, None)
                    if snapshot and snapshot.get("read_success"):
                        mount_info["snapshot"] = snapshot
                        mount_info["mtime"] = db_mtime
                        mount_info["content_mtime"] = 0
                        mount_info["txid"] = snapshot.get("txid", 0)
                        mount_info["db_ready"] = True
                        mount_info["last_error_time"] = 0
                        need_db_reload = False
                        need_content_refresh = True
                except Exception:
                    pass

            mount_info["loading_db"] = True
            mount_info["content_dirty"] = False
            if file_or_files:
                if isinstance(file_or_files, (list, set, tuple)):
                    mount_info["pending_invalidation"].update(f for f in file_or_files if isinstance(f, Nautilus.FileInfo))
                elif isinstance(file_or_files, Nautilus.FileInfo):
                    mount_info["pending_invalidation"].add(file_or_files)

        def worker():
            nonlocal need_db_reload, need_content_refresh
            while True:
                with mount_info["lock"]:
                    mount_info["content_dirty"] = False
                    current_snap = mount_info.get("snapshot")

                snapshot = None
                error_occurred = False

                try:
                    if need_db_reload:
                        snapshot = onedrive_core.read_bbolt_db(db_path, content_dir)
                        if not snapshot or not snapshot.get("read_success"):
                            error_occurred = True
                    elif need_content_refresh:
                        if current_snap and current_snap.get("read_success"):
                            path_to_item = current_snap.get("path_to_item", {})
                            known_folders = current_snap.get("known_folders", set())
                            id_to_item = current_snap.get("id_to_item")
                            folder_file_counts = current_snap.get("folder_file_counts")
                            cache_status = onedrive_core.compute_cache_status(
                                content_dir,
                                path_to_item,
                                known_folders,
                                id_to_item,
                                folder_file_counts=folder_file_counts
                            )
                            snapshot = dict(current_snap)
                            snapshot.update(cache_status)
                        else:
                            snapshot = onedrive_core.read_bbolt_db(db_path, content_dir)
                            if not snapshot or not snapshot.get("read_success"):
                                error_occurred = True
                except Exception:
                    error_occurred = True

                with mount_info["lock"]:
                    if mount_info.get("content_dirty"):
                        need_db_reload = False
                        need_content_refresh = True
                        continue
                    break

            def apply_snapshot():
                with mount_info["lock"]:
                    if error_occurred:
                        mount_info["last_error_time"] = time.time()
                        mount_info["loading_db"] = False
                        mount_info["pending_invalidation"].clear()
                    else:
                        if snapshot and snapshot.get("read_success"):
                            mount_info["snapshot"] = snapshot
                            mount_info["mtime"] = db_mtime
                            mount_info["content_mtime"] = content_mtime
                            mount_info["txid"] = snapshot.get("txid", 0)
                            mount_info["db_ready"] = True
                            mount_info["last_error_time"] = 0

                        mount_info["loading_db"] = False

                    to_invalidate = list(mount_info["pending_invalidation"])
                    mount_info["pending_invalidation"].clear()

                # 1. Complete any pending asynchronous requests for this mount
                with self._pending_updates_lock:
                    pending_handles = [
                        h for h, item in self._pending_updates.items()
                        if item[6] is mount_info
                    ]
                    pending_items = [self._pending_updates.pop(h) for h in pending_handles]

                for closure, prov, handle, f, fp, m_p, mi in pending_items:
                    try:
                        if error_occurred:
                            Nautilus.info_provider_update_complete_invoke(
                                closure,
                                prov,
                                handle,
                                Nautilus.OperationResult.FAILED
                            )
                        else:
                            self._apply_emblem_to_file(f, fp, m_p, mi)
                            Nautilus.info_provider_update_complete_invoke(
                                closure,
                                prov,
                                handle,
                                Nautilus.OperationResult.COMPLETE
                            )
                    except Exception:
                        pass

                # 2. Invalidate already-rendered active files so Nautilus refreshes them
                self._invalidate_active_files_for_mount(mount_info.get("mp", ""))
                for f in to_invalidate:
                    try:
                        f.invalidate_extension_info()
                    except Exception:
                        pass
                return False

            GLib.idle_add(apply_snapshot)

        threading.Thread(target=worker, daemon=True).start()

    def _match_mount(self, file_path: str):
        self._refresh_mounts()
        for mp in sorted(self.mounts.keys(), key=len, reverse=True):
            info = self.mounts[mp]
            if file_path == mp or file_path.startswith(mp + "/"):
                return mp, info
        return None, None

    # --- Nautilus.InfoProvider Interface ---
    def _apply_emblem_to_file(self, file: Nautilus.FileInfo, file_path: str, mp: str, mount_info: dict) -> bool:
        try:
            with self._sync_lock:
                syncing_snapshot = set(self.syncing_paths)

            is_syncing = any(
                file_path == p or file_path.startswith(p + "/") or
                (file.is_directory() and p.startswith(file_path + "/"))
                for p in syncing_snapshot
            )
            if is_syncing:
                file.add_emblem("onedrive-custom-syncing")
                return True

            snapshot = mount_info.get("snapshot")
            if not mount_info.get("db_ready") or not snapshot:
                return False

            rel_path = "" if file_path == mp else os.path.relpath(file_path, mp)
            rel_path = unicodedata.normalize("NFC", rel_path)

            if file.is_directory():
                has_cached = rel_path in snapshot.get("cached_folders", set())
                has_cloud = rel_path in snapshot.get("cloud_folders", set())
                is_known = rel_path in snapshot.get("known_folders", set())

                if has_cached and not has_cloud:
                    file.add_emblem("onedrive-custom-synced")
                elif has_cloud or has_cached or is_known:
                    file.add_emblem("onedrive-custom-cloud")
            else:
                item_info = snapshot.get("path_to_item", {}).get(rel_path)
                if item_info:
                    item_id = item_info["id"]
                    if item_id in snapshot.get("cached_ids", set()):
                        file.add_emblem("onedrive-custom-synced")
                    else:
                        file.add_emblem("onedrive-custom-cloud")
            return True
        except Exception:
            return False

    def update_file_info_full(self, provider, handle, closure, file: Nautilus.FileInfo) -> Nautilus.OperationResult:
        try:
            loc = file.get_location()
            if not loc:
                return Nautilus.OperationResult.COMPLETE
            file_path = loc.get_path()
            if not file_path:
                return Nautilus.OperationResult.COMPLETE

            file_path = unicodedata.normalize("NFC", file_path)
            self._register_active_file(file_path, file)

            mp, mount_info = self._match_mount(file_path)
            if not mp or not mount_info:
                return Nautilus.OperationResult.COMPLETE

            self._load_db_if_needed(mount_info, file)

            # If snapshot is already ready and loaded, apply immediately
            if mount_info.get("db_ready") and mount_info.get("snapshot"):
                self._apply_emblem_to_file(file, file_path, mp, mount_info)
                return Nautilus.OperationResult.COMPLETE

            # Snapshot still loading in background: register async handle
            with self._pending_updates_lock:
                self._pending_updates[handle] = (closure, provider, handle, file, file_path, mp, mount_info)

            return Nautilus.OperationResult.IN_PROGRESS
        except Exception:
            return Nautilus.OperationResult.COMPLETE

    def cancel_update(self, provider, handle):
        with self._pending_updates_lock:
            self._pending_updates.pop(handle, None)

    def update_file_info(self, file: Nautilus.FileInfo) -> Nautilus.OperationResult:
        try:
            loc = file.get_location()
            if not loc:
                return Nautilus.OperationResult.COMPLETE
            file_path = loc.get_path()
            if not file_path:
                return Nautilus.OperationResult.COMPLETE

            file_path = unicodedata.normalize("NFC", file_path)
            self._register_active_file(file_path, file)

            mp, mount_info = self._match_mount(file_path)
            if not mp or not mount_info:
                return Nautilus.OperationResult.COMPLETE

            self._load_db_if_needed(mount_info, file)
            self._apply_emblem_to_file(file, file_path, mp, mount_info)
        except Exception:
            pass

        return Nautilus.OperationResult.COMPLETE

    # --- Nautilus.MenuProvider Interface ---
    def get_file_items(self, files: list) -> list:
        if not files:
            return []

        onedrive_files = []
        has_synced = False
        cloud_files = []

        for file in files:
            loc = file.get_location()
            if not loc:
                continue
            file_path = loc.get_path()
            if not file_path:
                continue

            file_path = unicodedata.normalize("NFC", file_path)
            mp, mount_info = self._match_mount(file_path)
            if not mp or not mount_info:
                continue

            self._load_db_if_needed(mount_info, files)
            snapshot = mount_info.get("snapshot") or {}
            cached_ids = snapshot.get("cached_ids", set())
            rel_path = "" if file_path == mp else os.path.relpath(file_path, mp)
            rel_path = unicodedata.normalize("NFC", rel_path)
            path_to_item = snapshot.get("path_to_item", {})

            is_dir = file.is_directory()
            item_info = path_to_item.get(rel_path)
            item_id = item_info["id"] if item_info else None

            is_downloaded = False
            if is_dir:
                in_cached = rel_path in snapshot.get("cached_folders", set())
                in_cloud = rel_path in snapshot.get("cloud_folders", set())
                if in_cached:
                    has_synced = True
                is_downloaded = in_cached and not in_cloud
            else:
                is_downloaded = bool(item_id and item_id in cached_ids)
                if is_downloaded:
                    has_synced = True

            entry = (file, file_path, mp, mount_info, item_id, is_dir, rel_path, is_downloaded)
            onedrive_files.append(entry)
            if not is_dir and not is_downloaded:
                cloud_files.append(entry)

        if not onedrive_files:
            return []

        menu_items = []

        # Option: Free local space (directs safely to Vaciar caché to avoid unlinking files during FUSE operations)
        if has_synced:
            item_free = Nautilus.MenuItem(
                name="OneDrive::FreeSpace",
                label="OneDrive: Liberar espacio local",
                tip="Para proteger la integridad de sincronización, utilice «Vaciar caché» desde el panel de control",
                icon="onedrive-custom-cloud"
            )
            item_free.connect("activate", self._on_free_space_activate, onedrive_files)
            menu_items.append(item_free)

        # Download only explicit file selections.  A folder may contain many
        # gigabytes and must never be expanded by a context-menu action.
        if cloud_files:
            file_count = len(cloud_files)
            item_download = Nautilus.MenuItem(
                name="OneDrive::DownloadNow",
                label="OneDrive: Descargar archivo" if file_count == 1 else f"OneDrive: Descargar {file_count} archivos",
                tip="Descarga sólo los archivos seleccionados para usarlos sin conexión",
                icon="onedrive-custom-synced"
            )
            item_download.connect("activate", self._on_download_activate, cloud_files)
            menu_items.append(item_download)

        return menu_items

    def get_background_items(self, current_folder: Nautilus.FileInfo) -> list:
        # Do not expose a download operation for the current folder. Nautilus
        # can request background and selection menus in the same interaction;
        # treating the background folder as a selected file caused accidental
        # recursive downloads.
        return []

    def _on_free_space_activate(self, menu_item, onedrive_files):
        # A2: Directing to safe, verified cache clearing avoids destroying open descriptors or unuploaded changes
        _notify(
            "OneDrive: Liberar espacio",
            "Para evitar inconsistencias mientras onedriver está en ejecución, utilice «Vaciar caché» desde el panel de OneDrive.",
            "dialog-information"
        )

    def _on_download_activate(self, menu_item, onedrive_files):
        with self._sync_lock:
            # Defense in depth: this handler accepts files only, even if it is
            # invoked by a stale Nautilus menu object from an older extension.
            targets_to_download = [
                f for f in onedrive_files if not f[5]
                if not any(f[1] == p or f[1].startswith(p + "/") for p in self.syncing_paths)
            ]
            if not targets_to_download:
                return

            # 3. Mark as syncing and update emblems immediately
            for file, file_path, mp, mount_info, item_id, is_dir, rel_path, is_downloaded in targets_to_download:
                self.syncing_paths.add(file_path)
                try:
                    file.invalidate_extension_info()
                except Exception:
                    pass

        operation_id = f"{int(time.time() * 1000000):x}_{threading.get_ident():x}"
        activity_targets = {}
        for item in targets_to_download:
            mount_info = item[3]
            encoded = mount_info.get("encoded") if mount_info else None
            if encoded:
                activity_targets.setdefault(encoded, []).append(item)
        for encoded, items in activity_targets.items():
            _publish_manual_download_activity(encoded, operation_id, "downloading", _download_activity_label(items))

        def worker():
            mounts_involved = {}
            for item in targets_to_download:
                mi = item[3]
                if mi:
                    enc = mi.get("encoded")
                    if enc and enc not in mounts_involved:
                        mounts_involved[enc] = mi

            acquired_locks = []
            lock_failed = False
            for enc in sorted(mounts_involved.keys()):
                lf, ok = onedrive_core.acquire_lock(enc, timeout=5.0)
                if not ok:
                    lock_failed = True
                    break
                acquired_locks.append(lf)

            if lock_failed:
                for lf in acquired_locks:
                    onedrive_core.release_lock(lf)
                with self._sync_lock:
                    for _, file_path, _, _, _, _, _, _ in targets_to_download:
                        self.syncing_paths.discard(file_path)
                for file, _, _, _, _, _, _, _ in targets_to_download:
                    try:
                        GLib.idle_add(lambda f=file: (f.invalidate_extension_info(), False)[1])
                    except Exception:
                        pass
                for encoded, items in activity_targets.items():
                    _publish_manual_download_activity(encoded, operation_id, "failed", _download_activity_label(items))
                _notify("OneDrive", "La cuenta está ocupada por otra operación.", "dialog-warning")
                return

            downloaded = 0
            already_cached = 0
            failed = 0
            per_mount = {
                encoded: {"downloaded": 0, "already_cached": 0, "failed": 0}
                for encoded in mounts_involved
            }
            buf = bytearray(1024 * 1024)
            mv = memoryview(buf)

            def record(mount_info, outcome):
                encoded = mount_info.get("encoded") if mount_info else None
                if encoded in per_mount:
                    per_mount[encoded][outcome] += 1

            try:
                for file, file_path, mp, mount_info, item_id, is_dir, rel_path, is_downloaded in targets_to_download:
                    content_dir = mount_info.get("content_dir")
                    snapshot = mount_info.get("snapshot") or {}
                    path_to_item = snapshot.get("path_to_item", {})
                    norm_rel = unicodedata.normalize("NFC", rel_path)
                    item = path_to_item.get(norm_rel)
                    remote_size = item["size"] if item else 0
                    expected_hash = item.get("hash") if item else None

                    with self._sync_lock:
                        self.syncing_paths.add(file_path)
                    preset_cached = bool(item_id and onedrive_core.is_item_cached(content_dir, item_id, remote_size, expected_hash, item_info=item))
                    try:
                        with open(file_path, "rb") as f:
                            while f.readinto(mv):
                                pass
                        if preset_cached:
                            already_cached += 1
                            record(mount_info, "already_cached")
                        elif item_id and onedrive_core.is_item_cached(content_dir, item_id, remote_size, expected_hash, item_info=item):
                            downloaded += 1
                            record(mount_info, "downloaded")
                        else:
                            failed += 1
                            record(mount_info, "failed")
                    except Exception:
                        failed += 1
                        record(mount_info, "failed")
                    finally:
                        with self._sync_lock:
                            self.syncing_paths.discard(file_path)
            finally:
                with self._sync_lock:
                    for _, file_path, _, _, _, _, _, _ in targets_to_download:
                        self.syncing_paths.discard(file_path)

                for lf in acquired_locks:
                    onedrive_core.release_lock(lf)

                # Re-check and update database snapshots for all involved mounts
                for mi in mounts_involved.values():
                    self._load_db_if_needed(mi, force_content=True, invalidate_all_active=True)

                for file, _, _, _, _, _, _, _ in targets_to_download:
                    try:
                        GLib.idle_add(lambda f=file: (f.invalidate_extension_info(), False)[1])
                    except Exception:
                        pass

                for encoded, items in activity_targets.items():
                    stats = per_mount.get(encoded, {})
                    if stats.get("failed", 0) > 0 or failed > 0:
                        state = "partial" if stats.get("downloaded", 0) > 0 else "failed"
                    elif stats.get("downloaded", 0) > 0:
                        state = "completed"
                    else:
                        state = "available"
                    _publish_manual_download_activity(encoded, operation_id, state, _download_activity_label(items))

                if downloaded > 0 and failed == 0:
                    _notify("OneDrive: Descarga completada", f"Se descargaron {downloaded} archivo(s) para uso sin conexión.", "onedrive-custom-synced")
                elif downloaded > 0 and failed > 0:
                    _notify("OneDrive: Descarga parcial", f"Se descargaron {downloaded} archivo(s), pero fallaron {failed}.", "dialog-warning")
                elif failed > 0:
                    _notify("OneDrive: Error de descarga", f"Falló la descarga de {failed} archivo(s). Verifique la conexión con OneDrive.", "dialog-error")
                else:
                    _notify("OneDrive", "Todos los archivos seleccionados ya estaban descargados en este equipo.", "onedrive-custom-synced")

        threading.Thread(target=worker, daemon=True).start()
