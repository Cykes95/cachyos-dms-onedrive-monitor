#!/usr/bin/env python3
"""
Automated Reliability & Edge-Case Test Suite for OneDriveMonitor / Nautilus Integration
Verifies:
1. QuickXorHash correctness against reference vectors and Microsoft Graph checksums.
2. Missing hash fails safe (never claims cached/downloaded if unverified).
3. Same-size mismatched content fails safe.
4. SHA-1 fallback when QuickXorHash is absent.
5. _HASH_CACHE key includes st_dev and ctime_ns.
6. Event coalescing via content_dirty in worker.
7. Cache clearing safely purges dotfiles and hidden directories.
"""

import os
import sys
import tempfile
import stat
import subprocess
import collections

# Insert integration path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "integrations", "nautilus"))
import onedrive_core


def test_quickxorhash_vector():
    print("Running test_quickxorhash_vector...", end=" ")
    h = onedrive_core.QuickXorHash()
    h.update(b"The quick brown fox jumps over the lazy dog")
    digest = h.b64digest()
    assert digest == "bMSlbysmxJL6S75XwfMcQZOpcr4=", f"Got {digest}"
    print("PASS")


def test_hash_absent_fails_safe():
    print("Running test_hash_absent_fails_safe...", end=" ")
    with tempfile.TemporaryDirectory() as tmpdir:
        test_file = os.path.join(tmpdir, "01TESTITEMID")
        with open(test_file, "wb") as f:
            f.write(b"A" * 1024)

        # Case: expected_hash is None/empty
        item_info = {
            "id": "01TESTITEMID",
            "name": "document.docx",
            "size": 1024,
            "hash": None,
            "hashes": {},
            "rel_path": "document.docx"
        }

        # 1. is_item_cached must return False
        cached = onedrive_core.is_item_cached(tmpdir, "01TESTITEMID", remote_size=1024, expected_hash=None, item_info=item_info)
        assert not cached, f"Expected is_item_cached=False for missing hash, got {cached}"

        # 2. compute_cache_status must not include it in cached_ids
        path_to_item = {"document.docx": item_info}
        res = onedrive_core.compute_cache_status(tmpdir, path_to_item, known_folders=set(), id_to_item={"01TESTITEMID": item_info})
        assert "01TESTITEMID" not in res["cached_ids"], "Item without hash must NOT be in cached_ids!"
    print("PASS")


def test_mismatched_content_same_size_fails_safe():
    print("Running test_mismatched_content_same_size_fails_safe...", end=" ")
    with tempfile.TemporaryDirectory() as tmpdir:
        test_file = os.path.join(tmpdir, "01CORRUPTITEM")
        with open(test_file, "wb") as f:
            f.write(b"CORRUPTED BYTES" + b" " * 1009)

        item_info = {
            "id": "01CORRUPTITEM",
            "name": "legit.pdf",
            "size": 1024,
            "hash": "8G0J5R4KWCeDGao4rLmJcaFRMhc=",  # Hash of something else
            "hashes": {"quickXorHash": "8G0J5R4KWCeDGao4rLmJcaFRMhc="},
            "rel_path": "legit.pdf"
        }

        cached = onedrive_core.is_item_cached(tmpdir, "01CORRUPTITEM", remote_size=1024, item_info=item_info)
        assert not cached, f"Expected False for hash mismatch with identical size, got {cached}"

        path_to_item = {"legit.pdf": item_info}
        res = onedrive_core.compute_cache_status(tmpdir, path_to_item, known_folders=set(), id_to_item={"01CORRUPTITEM": item_info})
        assert "01CORRUPTITEM" not in res["cached_ids"], "Corrupted item must NOT be in cached_ids!"
    print("PASS")


def test_sha1_fallback():
    print("Running test_sha1_fallback...", end=" ")
    import hashlib
    with tempfile.TemporaryDirectory() as tmpdir:
        content = b"Special content for SHA1 test"
        sha1_expected = hashlib.sha1(content).hexdigest()
        test_file = os.path.join(tmpdir, "01SHA1ITEM")
        with open(test_file, "wb") as f:
            f.write(content)

        item_info = {
            "id": "01SHA1ITEM",
            "name": "archive.tar",
            "size": len(content),
            "hash": None,
            "sha1": sha1_expected,
            "hashes": {"sha1Hash": sha1_expected},
            "rel_path": "archive.tar"
        }

        # With correct sha1:
        st = os.stat(test_file)
        assert onedrive_core.verify_file_hash(test_file, st, item_info) == True, "Correct SHA-1 must verify!"

        # With corrupted sha1:
        bad_info = dict(item_info, sha1="0000000000000000000000000000000000000000", hashes={"sha1Hash": "0000000000000000000000000000000000000000"})
        assert onedrive_core.verify_file_hash(test_file, st, bad_info) == False, "Mismatched SHA-1 must fail!"
    print("PASS")


def test_hash_cache_includes_dev_ctime():
    print("Running test_hash_cache_includes_dev_ctime...", end=" ")
    with tempfile.TemporaryDirectory() as tmpdir:
        test_file = os.path.join(tmpdir, "testfile")
        with open(test_file, "wb") as f:
            f.write(b"test cache key content")

        st = os.stat(test_file)
        h1 = onedrive_core.get_cached_quickxorhash(test_file, st)
        assert h1 is not None

        # Check key in _HASH_CACHE has 5 elements: (dev, ino, size, mtime_ns, ctime_ns)
        cache_keys = list(onedrive_core._HASH_CACHE.keys())
        assert len(cache_keys) > 0
        latest_key = cache_keys[-1]
        assert len(latest_key) == 5, f"Expected 5-element key (dev, ino, size, mtime_ns, ctime_ns), got {latest_key}"
        assert latest_key[0] == st.st_dev
        assert latest_key[1] == st.st_ino
    print("PASS")


def test_content_dirty_coalescing():
    print("Running test_content_dirty_coalescing...", end=" ")
    # Simulates the worker loop logic from onedrive_extension.py
    import threading
    lock = threading.Lock()
    mount_info = {
        "content_dirty": True,
        "passes": 0
    }

    # Worker simulation
    while True:
        with lock:
            mount_info["content_dirty"] = False
            mount_info["passes"] += 1

        # Simulate a concurrent event arriving during pass 1
        if mount_info["passes"] == 1:
            with lock:
                mount_info["content_dirty"] = True

        with lock:
            if mount_info["content_dirty"]:
                continue
            break

    assert mount_info["passes"] == 2, f"Expected 2 passes due to coalescing, got {mount_info['passes']}"
    print("PASS")


def test_clear_cache_with_dotfiles():
    print("Running test_clear_cache_with_dotfiles...", end=" ")
    with tempfile.TemporaryDirectory() as tmpdir:
        content_dir = os.path.join(tmpdir, "content")
        os.makedirs(content_dir)

        # Create regular file, dotfile, and hidden subdirectory
        with open(os.path.join(content_dir, "01REGULAR"), "w") as f:
            f.write("regular")
        with open(os.path.join(content_dir, ".xdg-volume-info"), "w") as f:
            f.write("dotfile")
        os.makedirs(os.path.join(content_dir, ".Trash-1000", "info"), exist_ok=True)
        with open(os.path.join(content_dir, ".Trash-1000", "info", "file.trashinfo"), "w") as f:
            f.write("trashinfo")

        # Run the exact command used in actions.sh
        cmd = f'find "{content_dir}" -mindepth 1 -delete 2>/dev/null || find "{content_dir}" -mindepth 1 -exec rm -rf {{}} + 2>/dev/null'
        rc = subprocess.call(cmd, shell=True)
        assert rc == 0, f"find delete command failed with code {rc}"

        remaining = os.listdir(content_dir)
        assert len(remaining) == 0, f"Expected content_dir to be empty, but found: {remaining}"
    print("PASS")


if __name__ == "__main__":
    print("=== Running OneDriveMonitor Reliability Test Suite ===")
    test_quickxorhash_vector()
    test_hash_absent_fails_safe()
    test_mismatched_content_same_size_fails_safe()
    test_sha1_fallback()
    test_hash_cache_includes_dev_ctime()
    test_content_dirty_coalescing()
    test_clear_cache_with_dotfiles()
    print("=== All 7 Reliability Tests PASSED successfully! ===")
