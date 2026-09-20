#!/usr/bin/env python3
"""
OneDrive Core Library for Nautilus Integration and Standalone Scripts
Provides:
- Transactionally consistent bbolt B+ tree database parsing (zero-regex)
- Byte-accurate UTF-8 systemd unescaping
- Active FUSE mount detection via /proc/self/mountinfo
- Shared file-descriptor locking outside the cache directory
- Remote vs. local size verification for download integrity
"""

import os
import sys
import struct
import mmap
import json
import time
import fcntl

PAGE_SIZE = 4096
BOLT_MAGIC = 0xED0CDAED

def unescape_systemd(encoded: str) -> str:
    """Decodes systemd-escaped paths back to their UTF-8 string representation."""
    raw_bytes = bytearray()
    i = 0
    n = len(encoded)
    while i < n:
        if encoded[i:i+2] == "\\x" and i + 4 <= n:
            try:
                b = int(encoded[i+2:i+4], 16)
                raw_bytes.append(b)
                i += 4
                continue
            except ValueError:
                pass
        if encoded[i] == "-":
            raw_bytes.append(ord("/"))
        else:
            raw_bytes.extend(encoded[i].encode("utf-8"))
        i += 1
    path = raw_bytes.decode("utf-8", errors="replace")
    if not path.startswith("/"):
        path = "/" + path
    return path

def get_active_fuse_mounts() -> set:
    """Returns a set of all active FUSE mountpoint paths from /proc/self/mountinfo."""
    mounts = set()
    try:
        with open("/proc/self/mountinfo", "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.strip().split(" - ")
                if len(parts) == 2:
                    left = parts[0].split()
                    right = parts[1].split()
                    if len(left) >= 5 and len(right) >= 1:
                        mp = left[4]
                        fstype = right[0]
                        if fstype.startswith("fuse"):
                            mounts.add(mp)
    except Exception:
        pass
    return mounts

def get_cache_base() -> str:
    """Resolves the onedriver cache base directory according to XDG and config.yml."""
    home_dir = os.path.expanduser("~")
    cache_base = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.join(home_dir, ".cache")), "onedriver")
    config_file = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.join(home_dir, ".config")), "onedriver/config.yml")
    if os.path.isfile(config_file):
        try:
            with open(config_file, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line_clean = line.strip()
                    if line_clean.startswith("cacheDir:"):
                        val = line_clean.split(":", 1)[1].split("#")[0].strip().strip("\"'")
                        if val == "~":
                            cache_base = home_dir
                        elif val.startswith("~/"):
                            cache_base = os.path.join(home_dir, val[2:])
                        elif val.startswith("/"):
                            cache_base = val
                        break
        except Exception:
            pass
    return cache_base

def get_lock_path(encoded: str) -> str:
    """Returns the lock file path in XDG_RUNTIME_DIR outside the account cache."""
    uid = os.getuid()
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{uid}")
    lock_dir = os.path.join(runtime_dir, "onedrive_locks")
    try:
        os.makedirs(lock_dir, mode=0o700, exist_ok=True)
    except Exception:
        lock_dir = f"/tmp/onedriver_locks_{uid}"
        os.makedirs(lock_dir, mode=0o700, exist_ok=True)
    return os.path.join(lock_dir, f"{encoded}.lock")

def acquire_lock(encoded: str, timeout: float = 5.0):
    """
    Acquires an exclusive lock on the account lock file.
    Returns (lock_file_obj, True) on success, or (None, False) on timeout/error.
    """
    lock_path = get_lock_path(encoded)
    try:
        lf = open(lock_path, "a")
    except Exception:
        return None, False

    start_time = time.monotonic()
    while True:
        try:
            fcntl.flock(lf.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return lf, True
        except (BlockingIOError, OSError):
            if time.monotonic() - start_time >= timeout:
                try:
                    lf.close()
                except Exception:
                    pass
                return None, False
            time.sleep(0.1)

def release_lock(lf):
    """Safely releases and closes an acquired lock."""
    if lf:
        try:
            fcntl.flock(lf.fileno(), fcntl.LOCK_UN)
            lf.close()
        except Exception:
            pass

def is_item_cached(content_dir: str, item_id: str, remote_size: int) -> bool:
    """
    Verifies if an item is physically and completely cached on disk.
    If the remote size is greater than 0, the local cache file must match in size.
    """
    if not content_dir or not item_id:
        return False
    target_file = os.path.join(content_dir, item_id)
    try:
        st = os.stat(target_file)
        if remote_size > 0:
            return st.st_size == remote_size
        return True
    except OSError:
        return False

def read_bbolt_db(db_path: str, content_dir: str = None) -> dict:
    """
    Traverses the active transaction of a bbolt database to retrieve:
    - txid: active transaction ID
    - has_pending_uploads: bool (whether bucket 'uploads' has pending sessions)
    - pending_upload_ids: set of session IDs
    - path_to_item: dict of rel_path -> item dict (id, name, size, rel_path)
    - id_to_path: dict of id -> rel_path
    - known_folders: set of folder rel_paths
    - cached_ids: set of IDs completely downloaded in content_dir
    - cached_folders: set of folders containing at least one downloaded item
    - cloud_folders: set of folders containing at least one cloud-only item
    """
    result = {
        "txid": 0,
        "has_pending_uploads": False,
        "pending_upload_ids": set(),
        "path_to_item": {},
        "id_to_path": {},
        "known_folders": set(),
        "cached_ids": set(),
        "cached_folders": set(),
        "cloud_folders": set(),
        "read_success": False
    }

    if not os.path.isfile(db_path) or os.path.getsize(db_path) < PAGE_SIZE * 3:
        return result

    try:
        with open(db_path, "rb") as f:
            mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)

        # Meta pages are at offset 0 and PAGE_SIZE
        active_meta = None
        highest_txid = -1
        for p_offset in (0, PAGE_SIZE):
            p = mm[p_offset:p_offset + PAGE_SIZE]
            magic, version, pagesize, flags_meta = struct.unpack("<IIII", p[16:32])
            if magic == BOLT_MAGIC:
                root_pgid, seq, freelist, total_pgid, txid, checksum = struct.unpack("<QQQQQQ", p[32:80])
                if txid > highest_txid:
                    highest_txid = txid
                    active_meta = (root_pgid, txid)

        if not active_meta:
            return result

        root_pgid, txid = active_meta
        result["txid"] = txid

        def read_page(pgid):
            offset = pgid * PAGE_SIZE
            p = mm[offset:offset + PAGE_SIZE]
            p_id, flags, count, overflow = struct.unpack("<QHHI", p[:16])
            if overflow > 0:
                p = mm[offset:offset + PAGE_SIZE * (overflow + 1)]
            return flags, count, p

        # Root page holds top-level buckets
        flags, count, p = read_page(root_pgid)
        meta_bucket_root = 0
        upload_bucket_root = 0

        for i in range(count):
            elem_offset = 16 + i * 16
            eflags, pos, ksize, vsize = struct.unpack("<IIII", p[elem_offset:elem_offset + 16])
            k_offset = elem_offset + pos
            key = p[k_offset:k_offset + ksize]
            val = p[k_offset + ksize:k_offset + ksize + vsize]
            if eflags & 1:  # bucket
                b_root, _ = struct.unpack("<QQ", val[:16])
                if key == b"metadata":
                    meta_bucket_root = b_root
                elif key == b"uploads":
                    upload_bucket_root = b_root

        # Inspect uploads bucket
        if upload_bucket_root > 0:
            u_flags, u_count, u_page = read_page(upload_bucket_root)
            if u_count > 0:
                result["has_pending_uploads"] = True
                if u_flags & 2:  # leaf
                    for i in range(u_count):
                        elem_offset = 16 + i * 16
                        _, pos, ksize, _ = struct.unpack("<IIII", u_page[elem_offset:elem_offset + 16])
                        k_offset = elem_offset + pos
                        result["pending_upload_ids"].add(u_page[k_offset:k_offset + ksize].decode("utf-8", errors="ignore"))

        raw_items = []
        def traverse(pgid):
            flags, count, p = read_page(pgid)
            if flags & 1:  # branch page
                for i in range(count):
                    elem_offset = 16 + i * 16
                    pos, ksize, child_pgid = struct.unpack("<IIQ", p[elem_offset:elem_offset + 16])
                    traverse(child_pgid)
            elif flags & 2:  # leaf page
                for i in range(count):
                    elem_offset = 16 + i * 16
                    eflags, pos, ksize, vsize = struct.unpack("<IIII", p[elem_offset:elem_offset + 16])
                    k_offset = elem_offset + pos
                    key = p[k_offset:k_offset + ksize]
                    val = p[k_offset + ksize:k_offset + ksize + vsize]
                    raw_items.append((key, val))

        if meta_bucket_root > 0:
            traverse(meta_bucket_root)

        path_to_item = {}
        id_to_path = {}
        known_folders = set()

        for key_b, val_b in raw_items:
            try:
                obj = json.loads(val_b)
            except Exception:
                continue

            item_id = obj.get("id")
            name = obj.get("name")
            if not item_id or not name:
                continue

            parent_ref = obj.get("parentReference") or {}
            raw_path = parent_ref.get("path", "")
            clean_parent = raw_path.replace("/drive/root:", "").lstrip("/")
            rel_path = os.path.normpath(os.path.join(clean_parent, name))
            if rel_path == ".":
                continue

            is_folder = ("folder" in obj) or ("file" not in obj)
            if is_folder:
                known_folders.add(rel_path)
            else:
                size = obj.get("size", 0)
                item_info = {
                    "id": item_id,
                    "name": name,
                    "size": size,
                    "rel_path": rel_path
                }
                path_to_item[rel_path] = item_info
                id_to_path[item_id] = rel_path

        result["path_to_item"] = path_to_item
        result["id_to_path"] = id_to_path
        result["known_folders"] = known_folders
        result["read_success"] = True

        # Precompute folder and cache status if content_dir is provided
        if content_dir and os.path.isdir(content_dir):
            cached_ids = set()
            cached_folders = set()
            cloud_folders = set()

            for rel_path, item_info in path_to_item.items():
                item_id = item_info["id"]
                remote_size = item_info["size"]
                is_cached = is_item_cached(content_dir, item_id, remote_size)

                parts = rel_path.split("/")
                if is_cached:
                    cached_ids.add(item_id)
                    cached_folders.add("")
                    for i in range(1, len(parts)):
                        cached_folders.add("/".join(parts[:i]))
                else:
                    cloud_folders.add("")
                    for i in range(1, len(parts)):
                        cloud_folders.add("/".join(parts[:i]))

            for f in known_folders:
                if f and f not in cached_folders:
                    cloud_folders.add(f)

            result["cached_ids"] = cached_ids
            result["cached_folders"] = cached_folders
            result["cloud_folders"] = cloud_folders

        return result
    except Exception:
        return result
