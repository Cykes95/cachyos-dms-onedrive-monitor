#!/usr/bin/env python3
"""
OneDrive Nautilus Extension
- Displays cloud and synced emblems (onedrive-custom-cloud / onedrive-custom-synced)
- Provides context menu to "Liberar espacio local" and "Descargar en este equipo"
- Supports multiple onedriver accounts
"""

import os
import re
import time
import threading
import subprocess
import mmap
import gi
gi.require_version('Nautilus', '4.1')
from gi.repository import Nautilus, GObject, GLib

DB_PATTERN = re.compile(rb'\{"id":"([A-Za-z0-9!_-]+)","name":"([^"]+)".*?"parentReference":\{.*?"path":"([^"]*)".*?,"(file|folder)":', re.DOTALL)

def _notify(title: str, message: str, icon: str = "onedrive-custom-cloud"):
    try:
        subprocess.Popen(["notify-send", "-a", "OneDrive", "-i", icon, title, message])
    except Exception:
        pass

class OneDriveExtension(GObject.GObject, Nautilus.InfoProvider, Nautilus.MenuProvider):
    def __init__(self):
        super().__init__()
        self._sync_lock = threading.Lock()
        home_dir = os.path.expanduser("~")
        self.cache_base = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.join(home_dir, ".cache")), "onedriver")
        config_file = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.join(home_dir, ".config")), "onedriver/config.yml")
        if os.path.isfile(config_file):
            try:
                with open(config_file, "r", encoding="utf-8") as f:
                    for line in f:
                        if line.strip().startswith("cacheDir:"):
                            val = line.split(":", 1)[1].strip().strip("\"'")
                            if val.startswith("~"):
                                self.cache_base = os.path.expanduser(val)
                            elif val.startswith("/"):
                                self.cache_base = val
                            break
            except Exception:
                pass

        self.mounts = {} # mountpoint -> {"cache_dir": ..., "db_path": ..., "content_dir": ..., "mtime": 0, "path_to_id": {}, "id_to_path": {}, "io_lock": ...}
        self.last_mount_check = 0
        self.cached_ids = {} # mountpoint -> (set_of_ids, timestamp)
        self.syncing_paths = set()
        self._refresh_mounts()

    def _unescape_systemd(self, encoded: str) -> str:
        # Replaces systemd escape sequences like \x2d with '-'
        # and converts '-' to '/'
        result = []
        i = 0
        n = len(encoded)
        while i < n:
            if encoded[i:i+2] == "\\x":
                try:
                    hex_val = encoded[i+2:i+4]
                    result.append(chr(int(hex_val, 16)))
                    i += 4
                    continue
                except Exception:
                    pass
            if encoded[i] == "-":
                result.append("/")
            else:
                result.append(encoded[i])
            i += 1
        path = "".join(result)
        if not path.startswith("/"):
            path = "/" + path
        return path

    def _refresh_mounts(self):
        now = time.time()
        if now - self.last_mount_check < 10:
            return
        self.last_mount_check = now

        if not os.path.isdir(self.cache_base):
            return

        active_mounts = {}
        for entry in os.listdir(self.cache_base):
            if entry in ("CacheStorage", "WebKitCache"):
                continue
            entry_path = os.path.join(self.cache_base, entry)
            token_file = os.path.join(entry_path, "auth_tokens.json")
            if os.path.isdir(entry_path) and os.path.isfile(token_file):
                mp = self._unescape_systemd(entry)
                if os.path.isdir(mp):
                    prev = self.mounts.get(mp, {})
                    active_mounts[mp] = {
                        "cache_dir": entry_path,
                        "db_path": os.path.join(entry_path, "onedriver.db"),
                        "content_dir": os.path.join(entry_path, "content"),
                        "mtime": prev.get("mtime", 0),
                        "path_to_id": prev.get("path_to_id", {}),
                        "id_to_path": prev.get("id_to_path", {}),
                        "io_lock": prev.get("io_lock") or threading.Lock()
                    }
        self.mounts = active_mounts
        # Prune cached_ids for any mount that was removed
        active_cache_dirs = {m["cache_dir"] for m in active_mounts.values()}
        self.cached_ids = {k: v for k, v in self.cached_ids.items() if k in active_cache_dirs}

    def _parse_db_file(self, db_path: str, mtime: float, mount_info: dict, file_to_invalidate=None):
        if not os.path.isfile(db_path) or os.path.getsize(db_path) == 0:
            mount_info["loading_db"] = False
            return
        try:
            with open(db_path, "rb") as f:
                with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as mm:
                    matches = DB_PATTERN.findall(mm)

            path_to_id = {}
            id_to_path = {}
            for item_id_b, name_b, parent_b, kind_b in matches:
                # We only track files for caching and emblem computation!
                if kind_b != b"file":
                    continue
                item_id = item_id_b.decode("utf-8", errors="ignore")
                clean_parent = parent_b.decode("utf-8", errors="ignore").replace("/drive/root:", "")
                clean_name = name_b.decode("utf-8", errors="ignore")
                rel_path = os.path.normpath(os.path.join(clean_parent.lstrip("/"), clean_name))
                if rel_path == ".":
                    continue
                path_to_id[rel_path] = item_id
                id_to_path[item_id] = rel_path

            def apply_snapshot():
                mount_info["mtime"] = mtime
                mount_info["path_to_id"] = path_to_id
                mount_info["id_to_path"] = id_to_path
                cache_dir = mount_info.get("cache_dir")
                if cache_dir:
                    self.cached_ids.pop(cache_dir, None)
                if file_to_invalidate:
                    try:
                        file_to_invalidate.invalidate_extension_info()
                    except Exception:
                        pass
                return False

            GLib.idle_add(apply_snapshot)
        except Exception:
            pass
        finally:
            mount_info["loading_db"] = False

    def _load_db_if_needed(self, mount_info: dict, file_to_invalidate=None):
        db_path = mount_info["db_path"]
        if not os.path.isfile(db_path) or os.path.getsize(db_path) == 0:
            return

        try:
            mtime = os.path.getmtime(db_path)
            if mtime <= mount_info.get("mtime", 0) and mount_info.get("path_to_id"):
                return

            if not mount_info.get("loading_db"):
                mount_info["loading_db"] = True
                threading.Thread(target=self._parse_db_file, args=(db_path, mtime, mount_info, file_to_invalidate), daemon=True).start()
        except Exception:
            pass

    def _get_cached_ids(self, mount_info: dict) -> set:
        content_dir = mount_info["content_dir"]
        mp = mount_info["cache_dir"]
        now = time.time()
        cached, ts = self.cached_ids.get(mp, (set(), 0))
        if now - ts < 1.5:
            return cached

        if os.path.isdir(content_dir):
            try:
                cached = set(os.listdir(content_dir))
            except Exception:
                cached = set()
        else:
            cached = set()

        self.cached_ids[mp] = (cached, now)

        # Precompute cached folders and folder-to-IDs map for instant O(1) lookups
        cached_folders = set()
        cloud_folders = set()
        folder_to_cids = {"": []}
        path_to_id = mount_info.get("path_to_id", {})
        for p, cid in path_to_id.items():
            folder_to_cids[""].append(cid)
            parts = p.split("/")
            for i in range(1, len(parts)):
                folder = "/".join(parts[:i])
                if folder not in folder_to_cids:
                    folder_to_cids[folder] = []
                folder_to_cids[folder].append(cid)

            if cid in cached:
                cached_folders.add("")
                for i in range(1, len(parts)):
                    cached_folders.add("/".join(parts[:i]))
            else:
                cloud_folders.add("")
                for i in range(1, len(parts)):
                    cloud_folders.add("/".join(parts[:i]))

        mount_info["cached_folders"] = cached_folders
        mount_info["cloud_folders"] = cloud_folders
        mount_info["folder_to_cids"] = folder_to_cids
        return cached

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

            mp, mount_info = self._match_mount(file_path)
            if not mp or not mount_info:
                return Nautilus.OperationResult.COMPLETE

            self._load_db_if_needed(mount_info, file)
            cached_ids = self._get_cached_ids(mount_info)

            rel_path = "" if file_path == mp else os.path.relpath(file_path, mp)
            path_to_id = mount_info.get("path_to_id", {})
            item_id = path_to_id.get(rel_path)

            with self._sync_lock:
                syncing_snapshot = set(self.syncing_paths)

            is_syncing = any(file_path == p or file_path.startswith(p + "/") or (file.is_directory() and p.startswith(file_path + "/")) for p in syncing_snapshot)
            if is_syncing:
                file.add_emblem("onedrive-custom-syncing")
                return Nautilus.OperationResult.COMPLETE

            if file.is_directory():
                has_cached = rel_path in mount_info.get("cached_folders", set())
                has_cloud = rel_path in mount_info.get("cloud_folders", set())
                # Only mark folder as completely synced if all its contents are cached locally
                if has_cached and not has_cloud:
                    file.add_emblem("onedrive-custom-synced")
                elif has_cloud or has_cached:
                    file.add_emblem("onedrive-custom-cloud")
            else:
                # For files
                if item_id and item_id in cached_ids:
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

            mp, mount_info = self._match_mount(file_path)
            if not mp or not mount_info:
                continue

            self._load_db_if_needed(mount_info)
            cached_ids = self._get_cached_ids(mount_info)
            rel_path = "" if file_path == mp else os.path.relpath(file_path, mp)
            path_to_id = mount_info.get("path_to_id", {})

            is_dir = file.is_directory()
            item_id = path_to_id.get(rel_path)

            is_downloaded = False
            if is_dir:
                in_cached = rel_path in mount_info.get("cached_folders", set())
                in_cloud = rel_path in mount_info.get("cloud_folders", set())
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

        # Option: Free local space (if any selected item is downloaded)
        if has_synced:
            item_free = Nautilus.MenuItem(
                name="OneDrive::FreeSpace",
                label="OneDrive: Liberar espacio local",
                tip="Elimina la copia descargada en este PC sin borrar el archivo de la nube",
                icon="onedrive-custom-cloud"
            )
            item_free.connect("activate", self._on_free_space_activate, onedrive_files)
            menu_items.append(item_free)

        # Option: Keep always on this device / Download now (if any selected item is not yet fully downloaded)
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
        def worker():
            mounts_involved = {}
            for item in onedrive_files:
                mi = item[3]
                if mi:
                    cd = mi.get("cache_dir")
                    if cd and cd not in mounts_involved:
                        mounts_involved[cd] = mi.get("io_lock") or threading.Lock()

            acquired = []
            for cd in sorted(mounts_involved.keys()):
                lock = mounts_involved[cd]
                lock.acquire()
                acquired.append(lock)

            try:
                freed = 0
                affected_mounts = set()
                for file, file_path, mp, mount_info, item_id, is_dir, rel_path, is_downloaded in onedrive_files:
                    content_dir = mount_info.get("content_dir")
                    path_to_id = mount_info.get("path_to_id", {})
                    if not content_dir or not os.path.isdir(content_dir):
                        continue

                    affected_mounts.add(mount_info.get("cache_dir"))

                    if is_dir:
                        cids = mount_info.get("folder_to_cids", {}).get(rel_path, [])
                        for cid in cids:
                            cf = os.path.join(content_dir, cid)
                            if os.path.isfile(cf):
                                try:
                                    os.remove(cf)
                                    freed += 1
                                except Exception:
                                    pass
                    else:
                        if item_id:
                            cf = os.path.join(content_dir, item_id)
                            if os.path.isfile(cf):
                                try:
                                    os.remove(cf)
                                    freed += 1
                                except Exception:
                                    pass

                # Clear cached IDs so next info update re-reads fresh directory state
                for cd in affected_mounts:
                    if cd:
                        self.cached_ids.pop(cd, None)

                for file, _, _, _, _, _, _, _ in onedrive_files:
                    try:
                        GLib.idle_add(lambda f=file: (f.invalidate_extension_info(), False)[1])
                    except Exception:
                        pass

                if freed > 0:
                    _notify("OneDrive: Espacio liberado", f"Se desalojaron {freed} archivo(s) del equipo sin eliminarlos de la nube.", "onedrive-custom-cloud")
            finally:
                for lock in reversed(acquired):
                    lock.release()

        threading.Thread(target=worker, daemon=True).start()

    def _on_download_activate(self, menu_item, onedrive_files):
        with self._sync_lock:
            # Filter out targets that are already actively syncing (or within a syncing directory)
            targets_to_download = [
                f for f in onedrive_files
                if not any(f[1] == p or f[1].startswith(p + "/") for p in self.syncing_paths)
            ]
            if not targets_to_download:
                return

            # 1. Immediately mark target files as syncing and trigger emblem update
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
                    cd = mi.get("cache_dir")
                    if cd and cd not in mounts_involved:
                        mounts_involved[cd] = mi.get("io_lock") or threading.Lock()

            acquired = []
            for cd in sorted(mounts_involved.keys()):
                lock = mounts_involved[cd]
                lock.acquire()
                acquired.append(lock)

            downloaded = 0
            affected_mounts = set()
            buf = bytearray(1024 * 1024)
            mv = memoryview(buf)
            try:
                for file, file_path, mp, mount_info, item_id, is_dir, rel_path, is_downloaded in targets_to_download:
                    affected_mounts.add(mount_info.get("cache_dir"))
                    path_to_id = mount_info.get("path_to_id", {})
                    cached_ids = self._get_cached_ids(mount_info)

                    if is_dir:
                        for root_dir, _, filenames in os.walk(file_path):
                            for fn in filenames:
                                fp = os.path.join(root_dir, fn)
                                rel_f = os.path.relpath(fp, mp)
                                cid_f = path_to_id.get(rel_f)
                                # Avoid redundant disk I/O if file is already in cache
                                if cid_f and cid_f in cached_ids:
                                    continue

                                with self._sync_lock:
                                    self.syncing_paths.add(fp)
                                try:
                                    with open(fp, "rb") as f:
                                        while f.readinto(mv):
                                            pass
                                    downloaded += 1
                                except Exception:
                                    pass
                                finally:
                                    with self._sync_lock:
                                        self.syncing_paths.discard(fp)
                    else:
                        if item_id and item_id in cached_ids:
                            continue

                        with self._sync_lock:
                            self.syncing_paths.add(file_path)
                        try:
                            with open(file_path, "rb") as f:
                                while f.readinto(mv):
                                    pass
                            downloaded += 1
                        except Exception:
                            pass
                        finally:
                            with self._sync_lock:
                                self.syncing_paths.discard(file_path)
            finally:
                # 2. Clear syncing state and invalidate cache
                with self._sync_lock:
                    for file, file_path, mp, mount_info, item_id, is_dir, rel_path, is_downloaded in targets_to_download:
                        self.syncing_paths.discard(file_path)

                for cd in affected_mounts:
                    if cd:
                        self.cached_ids.pop(cd, None)

                for file, _, _, _, _, _, _, _ in targets_to_download:
                    try:
                        GLib.idle_add(lambda f=file: (f.invalidate_extension_info(), False)[1])
                    except Exception:
                        pass

                for lock in reversed(acquired):
                    lock.release()

                if downloaded > 0:
                    _notify("OneDrive: Descarga completada", f"Se descargaron {downloaded} archivo(s) para uso sin conexión.", "onedrive-custom-synced")
                else:
                    _notify("OneDrive", "Todos los archivos seleccionados ya estaban descargados en este equipo.", "onedrive-custom-synced")

        threading.Thread(target=worker, daemon=True).start()
