#!/usr/bin/env python3
"""
OneDrive Nautilus Extension
- Displays cloud and synced emblems (onedrive-custom-cloud / onedrive-custom-synced)
- Provides context menu to "Liberar espacio local" and "Descargar en este equipo"
- Powered by onedrive_core (transactional bbolt B+ tree parser, remote size checks, active FUSE detection)
"""

import os
import sys
import time
import threading
import subprocess
import unicodedata
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

class OneDriveExtension(GObject.GObject, Nautilus.InfoProvider, Nautilus.MenuProvider):
    def __init__(self):
        super().__init__()
        self._sync_lock = threading.Lock()
        self._active_files_lock = threading.Lock()
        self._active_files = weakref.WeakValueDictionary()  # file_path -> weakref to Nautilus.FileInfo
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
                        return False

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

                if invalidate_all_active:
                    self._invalidate_active_files_for_mount(mount_info.get("mp", ""))
                else:
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

            with self._sync_lock:
                syncing_snapshot = set(self.syncing_paths)

            is_syncing = any(
                file_path == p or file_path.startswith(p + "/") or
                (file.is_directory() and p.startswith(file_path + "/"))
                for p in syncing_snapshot
            )
            if is_syncing:
                file.add_emblem("onedrive-custom-syncing")
                return Nautilus.OperationResult.COMPLETE

            if not mount_info.get("db_ready") or not mount_info.get("snapshot"):
                return Nautilus.OperationResult.COMPLETE

            snapshot = mount_info["snapshot"]
            rel_path = "" if file_path == mp else os.path.relpath(file_path, mp)
            rel_path = unicodedata.normalize("NFC", rel_path)

            if file.is_directory():
                has_cached = rel_path in snapshot["cached_folders"]
                has_cloud = rel_path in snapshot["cloud_folders"]
                is_known = rel_path in snapshot["known_folders"]

                if has_cached and not has_cloud:
                    file.add_emblem("onedrive-custom-synced")
                elif has_cloud or has_cached or is_known:
                    file.add_emblem("onedrive-custom-cloud")
            else:
                item_info = snapshot["path_to_item"].get(rel_path)
                if item_info:
                    item_id = item_info["id"]
                    if item_id in snapshot["cached_ids"]:
                        file.add_emblem("onedrive-custom-synced")
                    else:
                        file.add_emblem("onedrive-custom-cloud")

        except Exception:
            pass

        return Nautilus.OperationResult.COMPLETE

    # --- Nautilus.MenuProvider Interface ---
    def get_file_items(self, files: list) -> list:
        if not files:
            return []

        onedrive_files = []
        has_synced = False
        has_cloud = False

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
                if in_cloud:
                    has_cloud = True
                is_downloaded = in_cached and not in_cloud
            else:
                is_downloaded = bool(item_id and item_id in cached_ids)
                if is_downloaded:
                    has_synced = True
                else:
                    has_cloud = True

            onedrive_files.append((file, file_path, mp, mount_info, item_id, is_dir, rel_path, is_downloaded))

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

        # Option: Download now (fetches files through FUSE)
        if has_cloud:
            item_download = Nautilus.MenuItem(
                name="OneDrive::DownloadNow",
                label="OneDrive: Descargar en este equipo",
                tip="Descarga una copia local completa para usar sin conexión",
                icon="onedrive-custom-synced"
            )
            item_download.connect("activate", self._on_download_activate, onedrive_files)
            menu_items.append(item_download)

        return menu_items

    def get_background_items(self, current_folder: Nautilus.FileInfo) -> list:
        if not current_folder:
            return []
        return self.get_file_items([current_folder])

    def _on_free_space_activate(self, menu_item, onedrive_files):
        # A2: Directing to safe, verified cache clearing avoids destroying open descriptors or unuploaded changes
        _notify(
            "OneDrive: Liberar espacio",
            "Para evitar inconsistencias mientras onedriver está en ejecución, utilice «Vaciar caché» desde el panel de OneDrive.",
            "dialog-information"
        )

    def _on_download_activate(self, menu_item, onedrive_files):
        with self._sync_lock:
            # 1. Prune child targets if ancestor directory is already in selection
            selected_dirs = {f[1] for f in onedrive_files if f[5]}
            pruned_files = [
                f for f in onedrive_files
                if not any(f[1] != d and f[1].startswith(d + "/") for d in selected_dirs)
            ]
            # 2. Filter out targets that are already actively syncing
            targets_to_download = [
                f for f in pruned_files
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
                _notify("OneDrive", "La cuenta está ocupada por otra operación.", "dialog-warning")
                return

            downloaded = 0
            already_cached = 0
            failed = 0
            buf = bytearray(1024 * 1024)
            mv = memoryview(buf)

            def walk_error(err):
                nonlocal failed
                failed += 1

            try:
                for file, file_path, mp, mount_info, item_id, is_dir, rel_path, is_downloaded in targets_to_download:
                    content_dir = mount_info.get("content_dir")
                    snapshot = mount_info.get("snapshot") or {}
                    path_to_item = snapshot.get("path_to_item", {})

                    if is_dir:
                        for root_dir, _, filenames in os.walk(file_path, onerror=walk_error):
                            for fn in filenames:
                                fp = os.path.join(root_dir, fn)
                                rel_f = unicodedata.normalize("NFC", os.path.relpath(fp, mp))
                                item = path_to_item.get(rel_f)
                                cid_f = item["id"] if item else None
                                remote_size = item["size"] if item else 0
                                expected_hash = item.get("hash") if item else None

                                with self._sync_lock:
                                    self.syncing_paths.add(fp)
                                preset_cached = bool(cid_f and onedrive_core.is_item_cached(content_dir, cid_f, remote_size, expected_hash, item_info=item))
                                try:
                                    with open(fp, "rb") as f:
                                        while f.readinto(mv):
                                            pass
                                    if preset_cached:
                                        already_cached += 1
                                    else:
                                        downloaded += 1
                                except Exception:
                                    failed += 1
                                finally:
                                    with self._sync_lock:
                                        self.syncing_paths.discard(fp)
                    else:
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
                            else:
                                downloaded += 1
                        except Exception:
                            failed += 1
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

                if downloaded > 0 and failed == 0:
                    _notify("OneDrive: Descarga completada", f"Se descargaron {downloaded} archivo(s) para uso sin conexión.", "onedrive-custom-synced")
                elif downloaded > 0 and failed > 0:
                    _notify("OneDrive: Descarga parcial", f"Se descargaron {downloaded} archivo(s), pero fallaron {failed}.", "dialog-warning")
                elif failed > 0:
                    _notify("OneDrive: Error de descarga", f"Falló la descarga de {failed} archivo(s). Verifique la conexión con OneDrive.", "dialog-error")
                else:
                    _notify("OneDrive", "Todos los archivos seleccionados ya estaban descargados en este equipo.", "onedrive-custom-synced")

        threading.Thread(target=worker, daemon=True).start()
