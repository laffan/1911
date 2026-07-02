-- Britannica 1911 offline database schema
-- Built by data/build_db.py. Consumed read-only by the SwiftUI app.
--
-- Design notes:
--   * `articles` holds the canonical content. `slug` is a stable URL-safe id
--     used for cross-reference resolution and deep links.
--   * `articles_fts` is an external-content FTS5 index over title + body, kept
--     in sync by triggers. `unicode61` + `porter` give diacritic-insensitive,
--     stemmed matching suited to encyclopedic prose. `rank` (bm25) orders hits.
--   * `cross_references` records "See also" style links between entries. The
--     target may not yet exist in the corpus, so `to_id` is nullable and the
--     app can also resolve lazily by `to_slug`.

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS articles (
    id            INTEGER PRIMARY KEY,
    slug          TEXT    NOT NULL UNIQUE,   -- e.g. "aardvark"
    title         TEXT    NOT NULL,          -- display title, e.g. "Aard-vark"
    volume        TEXT,                      -- source volume, e.g. "1"
    first_letter  TEXT    NOT NULL,          -- uppercase A-Z or '#' for browse index
    body          TEXT    NOT NULL,          -- plain-text article body
    source_url    TEXT                       -- provenance (Wikisource page URL)
);

CREATE INDEX IF NOT EXISTS idx_articles_first_letter ON articles(first_letter);
CREATE INDEX IF NOT EXISTS idx_articles_title        ON articles(title COLLATE NOCASE);

CREATE TABLE IF NOT EXISTS cross_references (
    from_id   INTEGER NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
    to_slug   TEXT    NOT NULL,
    to_title  TEXT    NOT NULL,
    to_id     INTEGER REFERENCES articles(id) ON DELETE SET NULL,
    PRIMARY KEY (from_id, to_slug)
);

CREATE INDEX IF NOT EXISTS idx_xref_to_slug ON cross_references(to_slug);

-- Full-text search over external content (the `articles` table).
CREATE VIRTUAL TABLE IF NOT EXISTS articles_fts USING fts5(
    title,
    body,
    content='articles',
    content_rowid='id',
    tokenize='porter unicode61 remove_diacritics 2'
);

-- Keep the FTS index in sync with the content table.
CREATE TRIGGER IF NOT EXISTS articles_ai AFTER INSERT ON articles BEGIN
    INSERT INTO articles_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
END;
CREATE TRIGGER IF NOT EXISTS articles_ad AFTER DELETE ON articles BEGIN
    INSERT INTO articles_fts(articles_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
END;
CREATE TRIGGER IF NOT EXISTS articles_au AFTER UPDATE ON articles BEGIN
    INSERT INTO articles_fts(articles_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
    INSERT INTO articles_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
END;
