#!/usr/bin/env python3
"""
Imports clipboard history, images, link previews, and pinboards from Paste.app's
local CoreData SQLite database into ClipShelf's local SQLite storage.

Reads Paste.db strictly in read-only mode (never modifies Paste's data).
"""
from __future__ import annotations

import hashlib
import json
import os
import plistlib
import re
import sqlite3
import uuid
from typing import Any

COREDATA_EPOCH_OFFSET = 978307200.0  # 2001-01-01 00:00:00 UTC

PASTE_DIR = os.path.expanduser("~/Library/Application Support/Paste")
PASTE_DB = os.path.join(PASTE_DIR, "Paste.db")
PASTE_EXT_DIR = os.path.join(PASTE_DIR, ".Paste_SUPPORT", "_EXTERNAL_DATA")

CLIPSHELF_DIR = os.path.expanduser("~/Library/Application Support/ClipShelf")
CLIPSHELF_DB = os.path.join(CLIPSHELF_DIR, "history.sqlite")
CLIPSHELF_BLOBS = os.path.join(CLIPSHELF_DIR, "blobs")


def argb_to_hex(val: int | None, fallback: str = "#3A3D42") -> str:
    if val is None:
        return fallback
    r = (val >> 16) & 0xFF
    g = (val >> 8) & 0xFF
    b = val & 0xFF
    return f"#{r:02X}{g:02X}{b:02X}"


def resolve_uid(objects: list[Any], obj: Any) -> Any:
    if isinstance(obj, plistlib.UID):
        idx = obj.data
        return objects[idx] if 0 <= idx < len(objects) else None
    return obj


def decode_nsurl_bplist(blob: bytes | None) -> str | None:
    if not blob:
        return None
    try:
        pl = plistlib.loads(blob)
        objects = pl.get("$objects", [])
        top = pl.get("$top", {})
        root = resolve_uid(objects, top.get("root"))
        if isinstance(root, dict):
            rel = resolve_uid(objects, root.get("NS.relative"))
            base = resolve_uid(objects, root.get("NS.base"))
            if isinstance(rel, str):
                return rel
            if isinstance(base, str):
                return base
    except Exception:
        pass
    return None


def load_external_or_inline_blob(blob: bytes | None) -> bytes | None:
    if not blob or len(blob) < 2:
        return None
    marker = blob[0]
    if marker == 0x01:
        return blob[1:]
    if marker == 0x02:
        ext_name = blob[1:].decode("ascii", errors="ignore").rstrip("\x00")
        ext_path = os.path.join(PASTE_EXT_DIR, ext_name)
        if os.path.isfile(ext_path):
            with open(ext_path, "rb") as f:
                return f.read()
    # Fallback: raw bplist without marker
    if blob.startswith(b"bplist00"):
        return blob
    return None


def decode_pasteboard_items(blob: bytes | None) -> dict[str, bytes]:
    raw = load_external_or_inline_blob(blob)
    if not raw:
        return {}
    try:
        pl = plistlib.loads(raw)
        objects = pl.get("$objects", [])
        top = pl.get("$top", {})
        root = resolve_uid(objects, top.get("root"))
        if not isinstance(root, dict):
            return {}
        items_uids = root.get("NS.objects", [])
        merged: dict[str, bytes] = {}
        for item_uid in items_uids:
            item_obj = resolve_uid(objects, item_uid)
            if not isinstance(item_obj, dict):
                continue
            data_dict = resolve_uid(objects, item_obj.get("data"))
            if not isinstance(data_dict, dict):
                continue
            keys = data_dict.get("NS.keys", [])
            vals = data_dict.get("NS.objects", [])
            for k_uid, v_uid in zip(keys, vals):
                k = resolve_uid(objects, k_uid)
                v = resolve_uid(objects, v_uid)
                if isinstance(k, str) and isinstance(v, bytes) and k not in merged:
                    merged[k] = v
        return merged
    except Exception:
        return {}


def decode_preview_text(blob: bytes | None) -> str | None:
    if not blob:
        return None
    try:
        pl = plistlib.loads(blob)
        objects = pl.get("$objects", [])
        for obj in objects:
            if isinstance(obj, str) and obj != "$null" and not obj.startswith("NS"):
                return obj
    except Exception:
        pass
    return None


def parse_image_size(size_str: str | None) -> tuple[int | None, int | None]:
    if not size_str:
        return None, None
    m = re.match(r"\{\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*\}", size_str)
    if not m:
        return None, None
    return int(float(m.group(1))), int(float(m.group(2)))


def save_blob(data: bytes, ext: str) -> str:
    os.makedirs(CLIPSHELF_BLOBS, exist_ok=True)
    name = f"{uuid.uuid4()}.{ext}"
    with open(os.path.join(CLIPSHELF_BLOBS, name), "wb") as f:
        f.write(data)
    return name


def detect_img_ext(data: bytes) -> str:
    if data.startswith(b"\x89PNG"):
        return "png"
    if data.startswith(b"\xff\xd8\xff"):
        return "jpg"
    return "png"


def ensure_clipshelf_schema(dst: sqlite3.Connection) -> None:
    dst.executescript("""
    PRAGMA journal_mode=WAL;
    PRAGMA foreign_keys=ON;
    CREATE TABLE IF NOT EXISTS items (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        plain_text TEXT,
        rtf_data BLOB,
        url_string TEXT,
        image_filename TEXT,
        image_width INTEGER,
        image_height INTEGER,
        file_paths_json TEXT NOT NULL,
        color_hex TEXT,
        source_app_bundle_id TEXT,
        source_app_name TEXT,
        header_color_hex TEXT NOT NULL,
        created_at REAL NOT NULL,
        content_hash TEXT NOT NULL UNIQUE,
        link_title TEXT,
        link_image_filename TEXT,
        custom_title TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_items_created_at ON items(created_at DESC);
    CREATE TABLE IF NOT EXISTS pinboards (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        color_hex TEXT NOT NULL,
        sort_order INTEGER NOT NULL,
        created_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS item_pinboards (
        item_id TEXT NOT NULL,
        pinboard_id TEXT NOT NULL,
        added_at REAL NOT NULL,
        PRIMARY KEY (item_id, pinboard_id),
        FOREIGN KEY (item_id) REFERENCES items(id) ON DELETE CASCADE,
        FOREIGN KEY (pinboard_id) REFERENCES pinboards(id) ON DELETE CASCADE
    );
    """)


def main() -> None:
    if not os.path.isfile(PASTE_DB):
        raise SystemExit(f"Paste database not found at {PASTE_DB}")

    os.makedirs(CLIPSHELF_DIR, exist_ok=True)
    os.makedirs(CLIPSHELF_BLOBS, exist_ok=True)

    src = sqlite3.connect(f"file:{PASTE_DB}?mode=ro", uri=True)
    dst = sqlite3.connect(CLIPSHELF_DB)
    ensure_clipshelf_schema(dst)

    # Load source apps
    apps: dict[int, tuple[str | None, str | None, str]] = {}
    for pk, color, bundle_id, name in src.execute(
        "SELECT Z_PK, ZCOLOR, ZBUNDLEIDENTIFIER, ZNAME FROM ZAPPLICATION"
    ):
        apps[pk] = (bundle_id, name, argb_to_hex(color))

    # Import Pinboards (Z_ENT = 15)
    pinboard_pk_to_uuid: dict[int, str] = {}
    pinboards_imported = 0
    for pk, order, color, name in src.execute(
        "SELECT Z_PK, ZDISPLAYORDER, ZCOLOR, ZNAME FROM ZSNIPPETLIST WHERE Z_ENT = 15 ORDER BY ZDISPLAYORDER ASC"
    ):
        if not name:
            continue
        existing = dst.execute("SELECT id FROM pinboards WHERE name = ?", (name,)).fetchone()
        if existing:
            pinboard_pk_to_uuid[pk] = existing[0]
        else:
            pid = str(uuid.uuid4())
            dst.execute(
                "INSERT INTO pinboards (id, name, color_hex, sort_order, created_at) VALUES (?, ?, ?, ?, ?)",
                (pid, name, argb_to_hex(color, "#0A84FF"), order or 0, 1700000000.0),
            )
            pinboard_pk_to_uuid[pk] = pid
            pinboards_imported += 1

    # Load snippet -> pinboard memberships
    snippet_pinboards: dict[int, list[str]] = {}
    for snippet_pk, list_pk in src.execute("SELECT Z_6SNIPPETS, Z_13LISTS FROM Z_6LISTS"):
        if list_pk in pinboard_pk_to_uuid:
            snippet_pinboards.setdefault(snippet_pk, []).append(pinboard_pk_to_uuid[list_pk])

    # Import Snippets
    rows = src.execute("""
        SELECT s.Z_PK, s.Z_ENT, s.ZSOURCEAPPLICATION, s.ZCOLOR, s.ZCREATEDAT, s.ZTIMESTAMP,
               s.ZTITLE, s.ZPATH, s.ZIMAGESIZE, s.ZURLNAME, s.ZURL,
               s.ZPREVIEW, s.ZPREVIEW1, s.ZPREVIEW2, s.ZIMAGE,
               d.ZPASTEBOARDITEMS
        FROM ZSNIPPET s
        LEFT JOIN ZSNIPPETDATA d ON d.ZSNIPPET = s.Z_PK
        ORDER BY COALESCE(s.ZTIMESTAMP, s.ZCREATEDAT) DESC
    """).fetchall()

    counts = {"text": 0, "link": 0, "image": 0, "file": 0, "color": 0}
    skipped = 0
    duplicates = 0

    for row in rows:
        (
            pk, ent, app_pk, scolor, created_cd, ts_cd,
            title, path, img_size, url_name, url_blob,
            preview_blob, preview1_blob, preview2_blob, image_blob,
            pb_blob,
        ) = row

        cd_ts = ts_cd if ts_cd is not None else (created_cd if created_cd is not None else 0.0)
        unix_ts = cd_ts + COREDATA_EPOCH_OFFSET

        bundle_id, app_name, header_hex = apps.get(app_pk, (None, None, "#3A3D42"))
        pb_map = decode_pasteboard_items(pb_blob)

        kind = None
        plain_text = None
        rtf_data = pb_map.get("public.rtf")
        url_string = None
        image_filename = None
        image_w, image_h = None, None
        file_paths: list[str] = []
        color_hex = None
        link_title = None
        link_image_filename = None
        content_hash = None

        if ent == 7:  # ColorSnippet
            kind = "color"
            color_hex = argb_to_hex(scolor, "#0A84FF")
            raw_txt = pb_map.get("public.utf8-plain-text")
            plain_text = raw_txt.decode("utf-8", errors="replace").strip() if raw_txt else color_hex
            header_hex = color_hex
            content_hash = hashlib.sha256(f"color:{color_hex}".encode()).hexdigest()

        elif ent == 8:  # FileSnippet
            kind = "file"
            if path:
                file_paths = [path]
            elif "public.file-url" in pb_map:
                furl = pb_map["public.file-url"].decode("utf-8", errors="ignore").strip()
                if furl.startswith("file://"):
                    from urllib.parse import unquote, urlparse
                    file_paths = [unquote(urlparse(furl).path)]
            if not file_paths:
                skipped += 1
                continue
            plain_text = ", ".join(os.path.basename(p) for p in file_paths)
            content_hash = hashlib.sha256(("file:" + "\n".join(file_paths)).encode()).hexdigest()

        elif ent == 9:  # ImageSnippet
            kind = "image"
            img_bytes = (
                pb_map.get("public.png")
                or pb_map.get("public.jpeg")
                or pb_map.get("public.tiff")
                or preview1_blob
                or preview_blob
                or image_blob
            )
            if not img_bytes:
                skipped += 1
                continue
            image_w, image_h = parse_image_size(img_size)
            content_hash = hashlib.sha256(img_bytes).hexdigest()
            # Check duplicate before writing blob
            if dst.execute("SELECT 1 FROM items WHERE content_hash = ?", (content_hash,)).fetchone():
                duplicates += 1
                continue
            image_filename = save_blob(img_bytes, detect_img_ext(img_bytes))

        elif ent == 10:  # LinkSnippet
            kind = "link"
            url_string = decode_nsurl_bplist(url_blob)
            if not url_string:
                raw_txt = pb_map.get("public.utf8-plain-text")
                url_string = raw_txt.decode("utf-8", errors="replace").strip() if raw_txt else None
            if not url_string:
                skipped += 1
                continue
            plain_text = url_string
            link_title = url_name
            content_hash = hashlib.sha256(f"link:{url_string}".encode()).hexdigest()
            if dst.execute("SELECT 1 FROM items WHERE content_hash = ?", (content_hash,)).fetchone():
                duplicates += 1
                continue
            if image_blob and len(image_blob) > 100:
                link_image_filename = save_blob(image_blob, detect_img_ext(image_blob))

        elif ent in (11, 6):  # TextSnippet or generic Snippet
            kind = "text"
            raw_txt = pb_map.get("public.utf8-plain-text")
            if raw_txt:
                plain_text = raw_txt.decode("utf-8", errors="replace")
            else:
                plain_text = decode_preview_text(preview2_blob)
            if not plain_text or not plain_text.strip():
                skipped += 1
                continue
            content_hash = hashlib.sha256(f"text:{plain_text}".encode()).hexdigest()

        else:
            skipped += 1
            continue

        existing = dst.execute("SELECT id FROM items WHERE content_hash = ?", (content_hash,)).fetchone()
        if existing:
            item_id = existing[0]
            duplicates += 1
        else:
            item_id = str(uuid.uuid4())
            dst.execute(
                """
                INSERT INTO items (
                    id, kind, plain_text, rtf_data, url_string, image_filename, image_width, image_height,
                    file_paths_json, color_hex, source_app_bundle_id, source_app_name, header_color_hex,
                    created_at, content_hash, link_title, link_image_filename, custom_title
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    item_id, kind, plain_text, rtf_data, url_string, image_filename, image_w, image_h,
                    json.dumps(file_paths), color_hex, bundle_id, app_name, header_hex,
                    unix_ts, content_hash, link_title, link_image_filename, title,
                ),
            )
            counts[kind] += 1

        for pid in snippet_pinboards.get(pk, []):
            dst.execute(
                "INSERT OR IGNORE INTO item_pinboards (item_id, pinboard_id, added_at) VALUES (?, ?, ?)",
                (item_id, pid, unix_ts),
            )

    dst.commit()
    total = sum(counts.values())
    print(f"Imported {total} items ({counts}), {pinboards_imported} pinboards, {duplicates} duplicates skipped, {skipped} empty/unsupported skipped.")


if __name__ == "__main__":
    main()
