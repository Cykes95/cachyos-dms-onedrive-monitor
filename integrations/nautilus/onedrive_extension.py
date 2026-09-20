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
import urllib.parse
import threading
import gi
gi.require_version('Nautilus', '4.1')
from gi.repository import Nautilus, GObject, Gio, GLib

class OneDriveExtension(GObject.GObject, Nautilus.InfoProvider, Nautilus.MenuProvider):
    def __init__(self):
        super().__init__()
        self.cache_base = os.path.expanduser("~/.cache/onedriver")
        self.mounts = {} # mountpoint -> {"cache_dir": ..., "db_path": ..., "content_dir": ..., "mtime": 0, "path_to_id": {}, "id_to_path": {}}
        self.last_mount_check = 0
        self.cached_ids = {} # mountpoint -> (set_of_ids, timestamp)
        self._refresh_mounts()

    def _unescape_systemd(self, encoded: str) -> str:
        # Replaces systemd escape sequences like \x2d with '-'
        # and converts '-' to '/'
        result = []
        i = 0
        n = len(encoded)
        while i < n:
            if encoded[i:i+4].startswith(r"\x"):
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
        if now - self.last_mount_check < 10 and self.mounts:
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
                        "id_to_path": prev.get("id_to_path", {})
                    }
        self.mounts = active_mounts

    def _load_db_if_needed(self, mount_info: dict):
        db_path = mount_info["db_path"]
        if not os.path.isfile(db_path):
            return

        try:
            mtime = os.path.getmtime(db_path)
            if mtime <= mount_info.get("mtime", 0) and mount_info["path_to_id"]:
                return

            with open(db_path, "rb") as f:
                raw = f.read()

            pattern = re.compile(rb'\{"id":"([A-Za-z0-9!_-]+)","name":"([^"]+)".*?"parentReference":\{.*?"path":"([^"]*)"', re.DOTALL)
            matches = pattern.findall(raw)

            path_to_id = {}
            id_to_path = {}
            for item_id_b, name_b, parent_b in matches:
                item_id = item_id_b.decode("utf-8", errors="ignore")
                clean_parent = parent_b.decode("utf-8", errors="ignore").replace("/drive/root:", "")
                clean_name = name_b.decode("utf-8", errors="ignore")
                rel_path = os.path.normpath(os.path.join(clean_parent.lstrip("/"), clean_name))
                if rel_path == ".":
                    continue
                path_to_id[rel_path] = item_id
                id_to_path[item_id] = rel_path

            mount_info["mtime"] = mtime
            mount_info["path_to_id"] = path_to_id
            mount_info["id_to_path"] = id_to_path
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

        # Precompute cached folders for instant O(1) directory lookups
        cached_folders = set()
        cloud_folders = set()
        path_to_id = mount_info.get("path_to_id", {})
        for p, cid in path_to_id.items():
            parts = p.split("/")
            if cid in cached:
                for i in range(1, len(parts)):
                    cached_folders.add("/".join(parts[:i]))
            else:
                for i in range(1, len(parts)):
                    cloud_folders.add("/".join(parts[:i]))

        mount_info["cached_folders"] = cached_folders
        mount_info["cloud_folders"] = cloud_folders
        return cached

    def _match_mount(self, file_path: str):
        self._refresh_mounts()
        for mp, info in self.mounts.items():
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

            # Root of the mountpoint
            if file_path == mp:
                return Nautilus.OperationResult.COMPLETE

            self._load_db_if_needed(mount_info)
            cached_ids = self._get_cached_ids(mount_info)

            rel_path = os.path.relpath(file_path, mp)
            path_to_id = mount_info.get("path_to_id", {})
            item_id = path_to_id.get(rel_path)

            if file.is_directory():
                has_cached = rel_path in mount_info.get("cached_folders", set())
                has_cloud = rel_path in mount_info.get("cloud_folders", set())
                if has_cached:
                    file.add_emblem("onedrive-custom-synced")
                elif has_cloud:
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
            if not mp or not mount_info or file_path == mp:
                continue

            self._load_db_if_needed(mount_info)
            cached_ids = self._get_cached_ids(mount_info)
            rel_path = os.path.relpath(file_path, mp)
            path_to_id = mount_info.get("path_to_id", {})

            is_dir = file.is_directory()
            item_id = path_to_id.get(rel_path)

            is_downloaded = False
            if is_dir:
                is_downloaded = rel_path in mount_info.get("cached_folders", set())
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

        # Option: Keep always on this device / Download now
        item_download = Nautilus.MenuItem(
            name="OneDrive::DownloadNow",
            label="OneDrive: Descargar en este equipo",
            tip="Descarga una copia local completa para usar sin conexión",
            icon="onedrive-custom-synced"
        )
        item_download.connect("activate", self._on_download_activate, onedrive_files)
        menu_items.append(item_download)

        return menu_items

    def _on_free_space_activate(self, menu_item, onedrive_files):
        def worker():
            for file, file_path, mp, mount_info, item_id, is_dir, rel_path, is_downloaded in onedrive_files:
                content_dir = mount_info.get("content_dir")
                path_to_id = mount_info.get("path_to_id", {})
                if not content_dir or not os.path.isdir(content_dir):
                    continue

                if is_dir:
                    prefix = rel_path + "/"
                    for p, cid in path_to_id.items():
                        if p.startswith(prefix):
                            cf = os.path.join(content_dir, cid)
                            if os.path.isfile(cf):
                                try:
                                    os.remove(cf)
                                except Exception:
                                    pass
                else:
                    if item_id:
                        cf = os.path.join(content_dir, item_id)
                        if os.path.isfile(cf):
                            try:
                                os.remove(cf)
                            except Exception:
                                pass

                try:
                    GLib.idle_add(file.invalidate_extension_info)
                except Exception:
                    pass

        threading.Thread(target=worker, daemon=True).start()

    def _on_download_activate(self, menu_item, onedrive_files):
        def worker():
            for file, file_path, mp, mount_info, item_id, is_dir, rel_path, is_downloaded in onedrive_files:
                if is_dir:
                    # Walk directory and touch files to download
                    for root_dir, _, filenames in os.walk(file_path):
                        for fn in filenames:
                            fp = os.path.join(root_dir, fn)
                            try:
                                with open(fp, "rb") as f:
                                    f.read(1)
                            except Exception:
                                pass
                else:
                    try:
                        with open(file_path, "rb") as f:
                            f.read(1)
                    except Exception:
                        pass

                try:
                    GLib.idle_add(file.invalidate_extension_info)
                except Exception:
                    pass

        threading.Thread(target=worker, daemon=True).start()
