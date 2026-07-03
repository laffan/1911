#!/usr/bin/env python3
"""Download the 1911 Encyclopaedia Britannica corpus from English Wikisource.

Run this on a machine with network access (e.g. your Mac). It talks to the
MediaWiki API, enumerates the EB1911 article subpages, fetches each page's
wikitext, converts it to clean plain text, and extracts metadata — the signing
contributor(s) and their initials, source volume and page range, previous/next
entry, and cross-reference links — writing batches to data/raw/eb1911_NNNN.json.
Then run build_db.py to compile the SQLite database the app bundles.

Only the Python standard library is used, so there is nothing to install.

Typical use:
    python3 scrape_eb1911.py --limit 200      # a quick sample
    python3 scrape_eb1911.py                  # the whole corpus (long!)
    python3 scrape_eb1911.py --resume         # continue an interrupted run

The full corpus is tens of thousands of articles; be a good citizen — the
default 0.2s delay and descriptive User-Agent respect the Wikimedia API
etiquette. See https://www.mediawiki.org/wiki/API:Etiquette
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

API = "https://en.wikisource.org/w/api.php"
ROOT_PREFIX = "1911 Encyclopædia Britannica/"
USER_AGENT = (
    "EB1911-Offline-Builder/1.0 (personal offline reader project; "
    "contact via https://en.wikisource.org)"
)
HERE = os.path.dirname(os.path.abspath(__file__))
RAW_DIR = os.path.join(HERE, "raw")
STATE_PATH = os.path.join(RAW_DIR, ".scrape_state.json")
BATCH_SIZE = 500


def api_get(params: dict) -> dict:
    params = {**params, "format": "json", "formatversion": "2"}
    url = API + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except Exception as exc:  # network/5xx: exponential backoff
            wait = 2 ** attempt
            print(f"    api error ({exc}); retrying in {wait}s", file=sys.stderr)
            time.sleep(wait)
    raise RuntimeError(f"API request failed after retries: {params}")


def enumerate_titles(limit: int | None, delay: float):
    """Yield EB1911 article page titles via allpages under the root prefix.

    Sub-subpages (disambiguation fragments, image pages) are skipped so we keep
    one record per encyclopedia entry.
    """
    apcontinue = None
    count = 0
    while True:
        # allpages is in the main namespace (0). We walk from the root prefix
        # and stop once titles fall outside it (see the startswith guard below).
        params = {
            "action": "query",
            "list": "allpages",
            "apnamespace": "0",
            "aplimit": "500",
            "apfrom": ROOT_PREFIX,
        }
        if apcontinue:
            params["apcontinue"] = apcontinue
        data = api_get(params)
        for page in data.get("query", {}).get("allpages", []):
            title = page["title"]
            if not title.startswith(ROOT_PREFIX):
                return  # walked past the EB1911 range
            leaf = title[len(ROOT_PREFIX):]
            if "/" in leaf:
                continue  # skip fragment subpages
            yield title
            count += 1
            if limit and count >= limit:
                return
        cont = data.get("continue", {})
        apcontinue = cont.get("apcontinue")
        if not apcontinue:
            return
        time.sleep(delay)


# [[target]] or [[target|label]] — group 1 target, group 2 optional label.
LINK_RE = re.compile(r"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]")
# Signature links to a contributor's Author: page: [[Author:Full Name|Initials]].
AUTHOR_RE = re.compile(r"\[\[Author:([^|\]]+)(?:\|([^\]]+))?\]\]")
VOLUME_RE = re.compile(r"\bvolume\s*=\s*([0-9IVXLC]+)", re.I)
# Header fields carrying reading-order and pagination metadata.
HEADER_FIELD_RE = re.compile(r"\|\s*(previous|next|pages?)\s*=\s*([^\n|}]+)", re.I)


def _link_label(m: "re.Match") -> str:
    """Render a wikilink as plain text, preferring its label over its target."""
    target, label = m.group(1), m.group(2)
    if label is not None:
        return label
    return target.split("/")[-1]


def wikitext_to_plain(wikitext: str) -> str:
    text = wikitext
    text = re.sub(r"<ref[^>]*>.*?</ref>", "", text, flags=re.S)  # footnotes
    text = re.sub(r"<ref[^>]*/>", "", text)
    text = re.sub(r"\{\{[^{}]*\}\}", "", text)  # simple templates
    text = re.sub(r"\{\{[^{}]*\}\}", "", text)  # nested pass
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)  # comments
    text = LINK_RE.sub(_link_label, text)  # keep link label / title
    text = re.sub(r"\[https?://\S+\s+([^\]]+)\]", r"\1", text)  # external links
    text = re.sub(r"'''?", "", text)  # bold/italic
    text = re.sub(r"<[^>]+>", "", text)  # stray html
    text = re.sub(r"^[=]{2,}.*?[=]{2,}$", "", text, flags=re.M)  # headings
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def extract_cross_refs(wikitext: str) -> list[str]:
    """Collect linked EB1911 entry titles as cross-references (deduped)."""
    refs: list[str] = []
    seen = set()
    for m in LINK_RE.finditer(wikitext):
        target = m.group(1).strip()
        if target.startswith(ROOT_PREFIX):
            target = target[len(ROOT_PREFIX):]
        if ":" in target or "/" in target:  # namespaces / fragments
            continue
        key = target.lower()
        if key and key not in seen:
            seen.add(key)
            refs.append(target)
    return refs[:40]


def extract_authors(wikitext: str) -> list[dict]:
    """Contributors that signed the article.

    EB1911 articles are signed with the author's initials, which Wikisource
    links to the contributor's ``Author:`` page, e.g.
    ``[[Author:Richard Lydekker|R. L.*]]``. We capture the full name, the
    original initials, and the Author-page URL. Order is preserved and
    duplicates (an author cited both mid-text and in the signature) are merged.
    """
    authors: list[dict] = []
    seen = set()
    for m in AUTHOR_RE.finditer(wikitext):
        name = m.group(1).strip()
        initials = (m.group(2) or "").strip() or None
        if not name or name.lower() in seen:
            continue
        seen.add(name.lower())
        authors.append({
            "name": name,
            "initials": initials,
            "url": "https://en.wikisource.org/wiki/Author:"
                   + urllib.parse.quote(name.replace(" ", "_")),
        })
    return authors


def _clean_field(value: str) -> str:
    """Strip wiki markup from a header field value (links, quotes, braces)."""
    value = LINK_RE.sub(_link_label, value)
    value = re.sub(r"'''?|[{}\[\]]", "", value)
    return value.strip()


def extract_header_meta(wikitext: str) -> dict:
    """Pull reading-order (previous/next) and pagination from the header."""
    meta: dict = {}
    for m in HEADER_FIELD_RE.finditer(wikitext):
        key = m.group(1).lower()
        value = _clean_field(m.group(2))
        if not value:
            continue
        if key in ("page", "pages"):
            meta.setdefault("pages", value)
        elif key not in meta:
            meta[key] = value
    return meta


def fetch_article(title: str) -> dict | None:
    data = api_get({
        "action": "query",
        "prop": "revisions",
        "rvprop": "content",
        "rvslots": "main",
        "titles": title,
    })
    pages = data.get("query", {}).get("pages", [])
    if not pages or "missing" in pages[0]:
        return None
    try:
        wikitext = pages[0]["revisions"][0]["slots"]["main"]["content"]
    except (KeyError, IndexError):
        return None
    body = wikitext_to_plain(wikitext)
    if len(body) < 20:
        return None
    vol = VOLUME_RE.search(wikitext)
    meta = extract_header_meta(wikitext)
    display_title = title[len(ROOT_PREFIX):]
    return {
        "title": display_title,
        "volume": vol.group(1) if vol else None,
        "pages": meta.get("pages"),
        "previous": meta.get("previous"),
        "next": meta.get("next"),
        "body": body,
        "authors": extract_authors(wikitext),
        "cross_references": extract_cross_refs(wikitext),
        "source_url": "https://en.wikisource.org/wiki/" + urllib.parse.quote(title.replace(" ", "_")),
    }


def load_state() -> dict:
    if os.path.exists(STATE_PATH):
        with open(STATE_PATH, encoding="utf-8") as fh:
            return json.load(fh)
    return {"done_titles": [], "batch_index": 0}


def save_state(state: dict) -> None:
    with open(STATE_PATH, "w", encoding="utf-8") as fh:
        json.dump(state, fh)


def flush_batch(batch: list[dict], index: int) -> None:
    path = os.path.join(RAW_DIR, f"eb1911_{index:04d}.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"articles": batch}, fh, ensure_ascii=False, indent=1)
    print(f"  wrote {path} ({len(batch)} articles)")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--limit", type=int, default=None, help="max articles (sampling)")
    ap.add_argument("--delay", type=float, default=0.2, help="seconds between requests")
    ap.add_argument("--resume", action="store_true", help="skip already-fetched titles")
    args = ap.parse_args()

    os.makedirs(RAW_DIR, exist_ok=True)
    state = load_state() if args.resume else {"done_titles": [], "batch_index": 0}
    done = set(state["done_titles"])
    batch: list[dict] = []
    batch_index = state["batch_index"]
    fetched = 0

    print("Enumerating EB1911 article titles ...")
    for title in enumerate_titles(args.limit, args.delay):
        if title in done:
            continue
        art = fetch_article(title)
        done.add(title)
        if art:
            batch.append(art)
            fetched += 1
            if fetched % 25 == 0:
                print(f"  fetched {fetched} articles (latest: {art['title']})")
        if len(batch) >= BATCH_SIZE:
            flush_batch(batch, batch_index)
            batch_index += 1
            batch = []
            save_state({"done_titles": sorted(done), "batch_index": batch_index})
        time.sleep(args.delay)

    if batch:
        flush_batch(batch, batch_index)
        batch_index += 1
    save_state({"done_titles": sorted(done), "batch_index": batch_index})
    print(f"\nDone. Fetched {fetched} articles into {RAW_DIR}/")
    print("Next: python3 build_db.py   (compiles the SQLite database)")


if __name__ == "__main__":
    main()
