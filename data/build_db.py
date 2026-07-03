#!/usr/bin/env python3
"""Build the on-device Britannica 1911 SQLite database (with FTS5).

Sources, merged in this order (later ones supplement, never overwrite):
  1. data/seed_articles.json      - hand-entered sample articles (always present)
  2. data/raw/*.json              - articles produced by scrape_eb1911.py

Each source article is a dict with keys:
    title (str, required)
    body  (str, required)
    volume (str, optional)
    cross_references (list[str], optional)  - target article titles
    source_url (str, optional)

Usage:
    python3 build_db.py                       # -> app/Britannica1911/britannica.sqlite
    python3 build_db.py --out /path/db.sqlite
    python3 build_db.py --no-raw              # seed only

The output path defaults to the app bundle location so a rebuild is picked up
by Xcode automatically.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sqlite3
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.normpath(
    os.path.join(HERE, "..", "app", "Britannica1911", "britannica.sqlite")
)
SCHEMA_PATH = os.path.join(HERE, "schema.sql")
SEED_PATH = os.path.join(HERE, "seed_articles.json")
RAW_GLOB = os.path.join(HERE, "raw", "*.json")


def slugify(title: str) -> str:
    """Stable, URL-safe id derived from a title.

    "Compass, Mariner's" -> "compass-mariners"
    Diacritics are folded so cross-references resolve regardless of accents.
    """
    text = unicodedata.normalize("NFKD", title)
    text = "".join(c for c in text if not unicodedata.combining(c))
    text = text.lower()
    text = re.sub(r"[^a-z0-9]+", "-", text)
    return text.strip("-") or "untitled"


def normalize_authors(art: dict) -> list[dict]:
    """Return a uniform author list [{name, initials, url}] from either source.

    Scraped articles carry a rich ``authors`` list; hand-entered seed articles
    may instead use the simpler ``author`` (str or list) / ``author_initials``
    fields. Names are de-duplicated while preserving signing order.
    """
    raw = art.get("authors")
    if not raw:
        names = art.get("author")
        if isinstance(names, str):
            names = [names]
        initials = art.get("author_initials")
        raw = [
            {"name": n, "initials": initials}
            for n in (names or [])
        ]

    out: list[dict] = []
    seen = set()
    for entry in raw:
        if isinstance(entry, str):
            entry = {"name": entry}
        name = (entry.get("name") or "").strip()
        if not name or name.lower() in seen:
            continue
        seen.add(name.lower())
        out.append({
            "name": name,
            "initials": (entry.get("initials") or "").strip() or None,
            "url": entry.get("url"),
        })
    return out


def first_letter(title: str) -> str:
    text = unicodedata.normalize("NFKD", title)
    text = "".join(c for c in text if not unicodedata.combining(c))
    for ch in text:
        if ch.isalpha():
            return ch.upper()
    return "#"


def load_articles(use_raw: bool) -> list[dict]:
    """Return merged article dicts keyed uniquely by slug (first wins)."""
    by_slug: dict[str, dict] = {}
    order: list[str] = []

    def add(art: dict, origin: str) -> None:
        title = (art.get("title") or "").strip()
        body = (art.get("body") or "").strip()
        if not title or not body:
            print(f"  ! skipping malformed article in {origin}: {title!r}", file=sys.stderr)
            return
        slug = slugify(title)
        if slug in by_slug:
            return  # first source wins; do not clobber
        authors = normalize_authors(art)
        by_slug[slug] = {
            "slug": slug,
            "title": title,
            "volume": (art.get("volume") or "").strip() or None,
            "pages": (art.get("pages") or "").strip() or None,
            "first_letter": first_letter(title),
            "body": body,
            "author_names": "; ".join(a["name"] for a in authors) or None,
            "previous_title": (art.get("previous") or "").strip() or None,
            "next_title": (art.get("next") or "").strip() or None,
            "source_url": art.get("source_url"),
            "authors": authors,
            "cross_references": [
                c.strip() for c in art.get("cross_references", []) if c and c.strip()
            ],
        }
        order.append(slug)

    with open(SEED_PATH, encoding="utf-8") as fh:
        seed = json.load(fh)
    for art in seed.get("articles", []):
        add(art, "seed_articles.json")
    print(f"  loaded {len(order)} seed article(s)")

    if use_raw:
        raw_files = sorted(glob.glob(RAW_GLOB))
        before = len(order)
        for path in raw_files:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
            items = data.get("articles", data) if isinstance(data, dict) else data
            for art in items:
                add(art, os.path.basename(path))
        if raw_files:
            print(f"  loaded {len(order) - before} scraped article(s) from {len(raw_files)} file(s)")

    return [by_slug[s] for s in order]


def build(out_path: str, use_raw: bool) -> None:
    articles = load_articles(use_raw)
    if not articles:
        sys.exit("No articles to write; aborting.")

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    if os.path.exists(out_path):
        os.remove(out_path)
    # WAL sidecar files from a previous build would otherwise linger.
    for ext in ("-wal", "-shm"):
        if os.path.exists(out_path + ext):
            os.remove(out_path + ext)

    conn = sqlite3.connect(out_path)
    conn.executescript(open(SCHEMA_PATH, encoding="utf-8").read())

    slug_to_id: dict[str, int] = {}
    for idx, art in enumerate(articles, start=1):
        art["id"] = idx
        slug_to_id[art["slug"]] = idx

    # Resolve previous/next reading-order titles into slugs (ids resolved lazily
    # in the app, since a neighbour may be scraped in a later run).
    for art in articles:
        art["previous_slug"] = slugify(art["previous_title"]) if art["previous_title"] else None
        art["next_slug"] = slugify(art["next_title"]) if art["next_title"] else None

    conn.executemany(
        """INSERT INTO articles
               (id, slug, title, volume, pages, first_letter, body, author_names,
                previous_slug, previous_title, next_slug, next_title, source_url)
           VALUES
               (:id, :slug, :title, :volume, :pages, :first_letter, :body, :author_names,
                :previous_slug, :previous_title, :next_slug, :next_title, :source_url)""",
        articles,
    )

    # Normalized contributors: one `authors` row per unique person, linked to
    # articles via `article_authors` (carrying the per-article signature).
    author_id_by_slug: dict[str, int] = {}
    author_rows: list[dict] = []
    join_rows: list[dict] = []
    for art in articles:
        for seq, author in enumerate(art["authors"]):
            aslug = slugify(author["name"])
            aid = author_id_by_slug.get(aslug)
            if aid is None:
                aid = len(author_rows) + 1
                author_id_by_slug[aslug] = aid
                author_rows.append({
                    "id": aid,
                    "slug": aslug,
                    "name": author["name"],
                    "wikisource_url": author.get("url"),
                })
            join_rows.append({
                "article_id": art["id"],
                "author_id": aid,
                "initials": author.get("initials"),
                "seq": seq,
            })
    conn.executemany(
        """INSERT INTO authors (id, slug, name, wikisource_url)
           VALUES (:id, :slug, :name, :wikisource_url)""",
        author_rows,
    )
    conn.executemany(
        """INSERT OR IGNORE INTO article_authors (article_id, author_id, initials, seq)
           VALUES (:article_id, :author_id, :initials, :seq)""",
        join_rows,
    )

    xrefs = []
    for art in articles:
        seen = set()
        for target_title in art["cross_references"]:
            target_slug = slugify(target_title)
            if target_slug == art["slug"] or target_slug in seen:
                continue
            seen.add(target_slug)
            xrefs.append(
                {
                    "from_id": art["id"],
                    "to_slug": target_slug,
                    "to_title": target_title,
                    "to_id": slug_to_id.get(target_slug),
                }
            )
    conn.executemany(
        """INSERT OR IGNORE INTO cross_references (from_id, to_slug, to_title, to_id)
           VALUES (:from_id, :to_slug, :to_title, :to_id)""",
        xrefs,
    )

    # Collapse WAL into the main file and compact, so the bundled asset is a
    # single self-contained, read-optimized file.
    conn.commit()
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    conn.execute("PRAGMA journal_mode = DELETE")
    conn.execute("INSERT INTO articles_fts(articles_fts) VALUES('optimize')")
    conn.commit()
    conn.execute("VACUUM")
    conn.close()

    resolved = sum(1 for x in xrefs if x["to_id"])
    with_author = sum(1 for a in articles if a["authors"])
    size_kb = os.path.getsize(out_path) / 1024
    print(f"\nWrote {out_path}")
    print(f"  articles          : {len(articles)} ({with_author} with a named author)")
    print(f"  contributors      : {len(author_rows)}")
    print(f"  cross-references  : {len(xrefs)} ({resolved} resolved, {len(xrefs) - resolved} dangling)")
    print(f"  file size         : {size_kb:.1f} KiB")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=DEFAULT_OUT, help="output SQLite path")
    ap.add_argument("--no-raw", action="store_true", help="ignore data/raw/*.json")
    args = ap.parse_args()
    print("Building Britannica 1911 database ...")
    build(args.out, use_raw=not args.no_raw)


if __name__ == "__main__":
    main()
