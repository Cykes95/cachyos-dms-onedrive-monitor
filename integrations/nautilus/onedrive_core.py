#!/usr/bin/env python3
"""
OneDrive Core Library for Nautilus Integration and Standalone Scripts
Provides:
- Transactionally consistent bbolt B+ tree database parsing with inline bucket support
- Byte-accurate UTF-8 systemd unescaping
- Octal-unescaped active FUSE mount detection via /proc/self/mountinfo
- Shared file-descriptor locking outside the cache directory
- Remote vs. local size verification for download integrity
"""

import os
import sys
import re
import struct
import mmap
import json
import time
import fcntl
import stat
import unicodedata
import base64

BOLT_MAGIC = 0xED0CDAED
DEFAULT_PAGE_SIZE = 4096

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

def decode_mountinfo_path(p: str) -> str:
    """Decodes octal escapes used in /proc/self/mountinfo (e.g. \\040 for spaces)."""
    return re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), p)

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
                        raw_mp = left[4]
                        fstype = right[0]
                        if fstype.startswith("fuse"):
                            decoded_mp = decode_mountinfo_path(raw_mp)
                            mounts.add(decoded_mp)
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

class QuickXorHash:
    """
    Pure Python implementation of Microsoft's QuickXorHash algorithm.
    WidthInBits = 160 (20 bytes), Shift = 11, DataSize = 11 * 160 = 1760 bytes.
    Matches Microsoft OneDrive / SharePoint and onedriver checksums.
    """
    DATA_SIZE = 11 * 160  # 1760

    def __init__(self):
        self.data = bytearray(self.DATA_SIZE)
        self.length = 0

    def update(self, b: bytes):
        n = len(b)
        if n == 0:
            return
        last_remain = self.length % self.DATA_SIZE
        offset = 0

        if last_remain != 0:
            chunk = min(n, self.DATA_SIZE - last_remain)
            for j in range(chunk):
                self.data[last_remain + j] ^= b[j]
            offset += chunk

        while n - offset >= self.DATA_SIZE:
            for j in range(self.DATA_SIZE):
                self.data[j] ^= b[offset + j]
            offset += self.DATA_SIZE

        if offset < n:
            rem = n - offset
            for j in range(rem):
                self.data[j] ^= b[offset + j]

        self.length += n

    def digest(self) -> bytes:
        h = bytearray(21)
        for i in range(self.DATA_SIZE):
            shift = (i * 11) % 160
            sb = shift // 8
            sbits = shift % 8
            shifted = self.data[i] << sbits
            h[sb] ^= (shifted & 0xFF)
            h[sb + 1] ^= ((shifted >> 8) & 0xFF)
        h[0] ^= h[20]

        d = self.length
        for j in range(8):
            h[20 - 8 + j] ^= ((d >> (8 * j)) & 0xFF)

        return bytes(h[:20])

    def b64digest(self) -> str:
        return base64.b64encode(self.digest()).decode("ascii")


def compute_file_quickxorhash(file_path: str, chunk_size: int = 65536) -> str:
    """Computes base64 QuickXorHash for a local file."""
    hasher = QuickXorHash()
    with open(file_path, "rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            hasher.update(chunk)
    return hasher.b64digest()


_HASH_CACHE = {}  # (st_ino, st_size, st_mtime_ns) -> b64_hash

def get_cached_quickxorhash(file_path: str, st: os.stat_result = None) -> str:
    """
    Returns QuickXorHash for file_path, memoizing results by (st_ino, st_size, st_mtime_ns).
    Avoids re-reading and re-hashing files that have not changed.
    """
    try:
        if st is None:
            st = os.stat(file_path)
        cache_key = (st.st_ino, st.st_size, st.st_mtime_ns)
        cached = _HASH_CACHE.get(cache_key)
        if cached is not None:
            return cached
        computed = compute_file_quickxorhash(file_path)
        _HASH_CACHE[cache_key] = computed
        if len(_HASH_CACHE) > 10000:
            for k in list(_HASH_CACHE.keys())[:2000]:
                del _HASH_CACHE[k]
        return computed
    except OSError:
        return None


def is_item_cached(content_dir: str, item_id: str, remote_size: int = 0, expected_hash: str = None) -> bool:
    """
    Verifies if an item is physically, regularly and verified-cached on disk.
    Requires:
    1. Target file exists in content_dir, is regular file (stat.S_ISREG), not a symlink.
    2. Size matches exact remote size (if remote_size is valid >= 0).
    3. If expected_hash (QuickXorHash) is provided, computed QuickXorHash must match.
    """
    if not content_dir or not item_id:
        return False
    if remote_size is None or int(remote_size) < 0:
        return False
    target_file = os.path.join(content_dir, item_id)
    try:
        if not os.path.isfile(target_file) or os.path.islink(target_file):
            return False
        st = os.stat(target_file)
        if not stat.S_ISREG(st.st_mode):
            return False
        if st.st_size != int(remote_size):
            return False
        if expected_hash:
            actual_hash = get_cached_quickxorhash(target_file, st)
            if actual_hash != expected_hash:
                return False
        return True
    except OSError:
        return False


def compute_cache_status(content_dir: str, path_to_item: dict, known_folders: set = None, id_to_item: dict = None) -> dict:
    """
    Computes cached_ids, cached_folders, and cloud_folders by checking physical files
    in content_dir against items in path_to_item with QuickXorHash validation.
    Optimized: scans content_dir and only hashes files present in local cache.
    """
    cached_ids = set()
    cached_folders = set()
    cloud_folders = set()
    if known_folders is None:
        known_folders = set()

    if content_dir and os.path.isdir(content_dir) and path_to_item:
        local_entries = {}
        try:
            with os.scandir(content_dir) as it:
                for entry in it:
                    if entry.is_file(follow_symlinks=False):
                        try:
                            st = entry.stat()
                            if stat.S_ISREG(st.st_mode):
                                local_entries[entry.name] = (entry.path, st)
                        except OSError:
                            pass
        except OSError:
            pass

        if id_to_item is None:
            id_to_item = {info["id"]: info for info in path_to_item.values()}

        # Verify only items that physically exist in local_entries
        for item_id, (target_file, st) in local_entries.items():
            item_info = id_to_item.get(item_id)
            if not item_info:
                continue
            remote_size = item_info.get("size", 0)
            if remote_size is None or int(remote_size) < 0 or st.st_size != int(remote_size):
                continue
            expected_hash = item_info.get("hash")
            if expected_hash:
                actual_hash = get_cached_quickxorhash(target_file, st)
                if actual_hash != expected_hash:
                    continue
            cached_ids.add(item_id)

        # Folder status propagation
        for rel_path, item_info in path_to_item.items():
            item_id = item_info["id"]
            parts = rel_path.split("/")
            if item_id in cached_ids:
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

    return {
        "cached_ids": cached_ids,
        "cached_folders": cached_folders,
        "cloud_folders": cloud_folders
    }

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

    if not os.path.isfile(db_path) or os.path.getsize(db_path) < DEFAULT_PAGE_SIZE * 2:
        return result

    try:
        with open(db_path, "rb") as f:
            mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)

        # Meta pages are at offset 0 and at page offset 1 (at least 4096)
        active_meta = None
        highest_txid = -1
        page_size = DEFAULT_PAGE_SIZE

        for p_offset in (0, DEFAULT_PAGE_SIZE):
            if len(mm) < p_offset + 80:
                continue
            p = mm[p_offset:p_offset + DEFAULT_PAGE_SIZE]
            magic, version, meta_pagesize, flags_meta = struct.unpack("<IIII", p[16:32])
            if magic == BOLT_MAGIC and version == 2 and meta_pagesize >= 512:
                root_pgid, seq, freelist, total_pgid, txid, checksum = struct.unpack("<QQQQQQ", p[32:80])
                if txid > highest_txid:
                    highest_txid = txid
                    page_size = meta_pagesize
                    active_meta = (root_pgid, txid)

        if not active_meta:
            return result

        root_pgid, txid = active_meta
        result["txid"] = txid

        def read_page(pgid):
            offset = pgid * page_size
            p = mm[offset:offset + page_size]
            p_id, flags, count, overflow = struct.unpack("<QHHI", p[:16])
            if overflow > 0:
                p = mm[offset:offset + page_size * (overflow + 1)]
            return flags, count, p

        def parse_leaf_elements(p_data, count):
            items = []
            for i in range(count):
                elem_offset = 16 + i * 16
                eflags, pos, ksize, vsize = struct.unpack("<IIII", p_data[elem_offset:elem_offset + 16])
                k_offset = elem_offset + pos
                k = p_data[k_offset:k_offset + ksize]
                v = p_data[k_offset + ksize:k_offset + ksize + vsize]
                items.append((k, v, eflags))
            return items

        def get_bucket_items(b_root, b_val):
            # Inline bucket support
            if b_root == 0:
                inline_page = b_val[16:]
                if len(inline_page) < 16:
                    return []
                _, ip_flags, ip_count, _ = struct.unpack("<QHHI", inline_page[:16])
                if ip_flags & 2:  # leaf
                    return [(k, v) for (k, v, _) in parse_leaf_elements(inline_page, ip_count)]
                return []

            # Non-inline bucket: traverse B+ tree
            items = []
            def traverse(pgid):
                flags, count, p = read_page(pgid)
                if flags & 1:  # branch page
                    for i in range(count):
                        elem_offset = 16 + i * 16
                        pos, ksize, child_pgid = struct.unpack("<IIQ", p[elem_offset:elem_offset + 16])
                        traverse(child_pgid)
                elif flags & 2:  # leaf page
                    for (k, v, _) in parse_leaf_elements(p, count):
                        items.append((k, v))
            traverse(b_root)
            return items

        # Root page holds top-level buckets
        flags, count, p = read_page(root_pgid)
        root_items = parse_leaf_elements(p, count) if (flags & 2) else []

        meta_items = []
        upload_items = []

        for key, val, eflags in root_items:
            if eflags & 1:  # bucket
                b_root, _ = struct.unpack("<QQ", val[:16])
                if key == b"metadata":
                    meta_items = get_bucket_items(b_root, val)
                elif key == b"uploads":
                    upload_items = get_bucket_items(b_root, val)

        if upload_items:
            result["has_pending_uploads"] = True
            for k, _ in upload_items:
                result["pending_upload_ids"].add(k.decode("utf-8", errors="ignore"))

        path_to_item = {}
        id_to_path = {}
        id_to_item = {}
        known_folders = set()

        for key_b, val_b in meta_items:
            try:
                obj = json.loads(val_b)
            except Exception:
                continue

            item_id = obj.get("id")
            name = obj.get("name")
            if not item_id or not name:
                continue

            name = unicodedata.normalize("NFC", name)
            parent_ref = obj.get("parentReference") or {}
            raw_path = parent_ref.get("path", "")
            if "root:" in raw_path:
                clean_parent = raw_path.split("root:", 1)[1].lstrip("/")
            else:
                clean_parent = raw_path.lstrip("/")
            clean_parent = unicodedata.normalize("NFC", clean_parent)
            rel_path = unicodedata.normalize("NFC", os.path.normpath(os.path.join(clean_parent, name)))
            if rel_path == ".":
                continue

            is_folder = ("folder" in obj) or ("file" not in obj)
            if is_folder:
                known_folders.add(rel_path)
            else:
                size = obj.get("size", 0)
                file_facet = obj.get("file") or {}
                hashes = file_facet.get("hashes") or {}
                quick_hash = hashes.get("quickXorHash")
                item_info = {
                    "id": item_id,
                    "name": name,
                    "size": size,
                    "hash": quick_hash,
                    "rel_path": rel_path
                }
                path_to_item[rel_path] = item_info
                id_to_path[item_id] = rel_path
                id_to_item[item_id] = item_info

        result["path_to_item"] = path_to_item
        result["id_to_path"] = id_to_path
        result["id_to_item"] = id_to_item
        result["known_folders"] = known_folders
        result["read_success"] = True

        # Precompute folder and cache status if content_dir is provided
        if content_dir and os.path.isdir(content_dir):
            cache_status = compute_cache_status(content_dir, path_to_item, known_folders, id_to_item)
            result.update(cache_status)

        return result
    except Exception:
        return result

if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "check-purge":
        db_file = sys.argv[2]
        res = read_bbolt_db(db_file)
        if res.get("read_success") and not res.get("has_pending_uploads"):
            print("SAFE_TO_PURGE")
            sys.exit(0)
        else:
            if not res.get("read_success"):
                print("ERROR_READING_DB", file=sys.stderr)
            else:
                print("PENDING_UPLOADS", file=sys.stderr)
            sys.exit(1)
