-- Britannica 1911 offline database schema
-- Built by data/build_db.py. Consumed read-only by the SwiftUI app.
--
-- Design notes:
--   * `articles` holds the canonical content. `slug` is a stable URL-safe id
--     used for cross-reference / prev-next resolution and deep links.
--   * Authorship is normalized: `authors` (one row per contributor) and
--     `article_authors` (which contributors signed which article, with the
--     original EB1911 initials). `articles.author_names` is a denormalized
--     copy used for display and full-text search.
--   * `articles_fts` is an external-content FTS5 index over title, body and
--     author names, kept in sync by triggers. `unicode61` + `porter` give
--     diacritic-insensitive, stemmed matching; `rank` (bm25) orders hits.
--   * `cross_references` records "See also" style links between entries. The
--     target may not yet exist in the corpus, so `to_id` is nullable and the
--     app can also resolve lazily by `to_slug`. Prev/next work the same way.

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS articles (
    id              INTEGER PRIMARY KEY,
    slug            TEXT    NOT NULL UNIQUE,   -- e.g. "aardvark"
    title           TEXT    NOT NULL,          -- display title, e.g. "Aard-vark"
    volume          TEXT,                      -- source volume, e.g. "1"
    pages           TEXT,                      -- printed page range, e.g. "4-5"
    first_letter    TEXT    NOT NULL,          -- uppercase A-Z or '#' for browse index
    body            TEXT    NOT NULL,          -- plain-text article body
    author_names    TEXT,                      -- denormalized "A; B" for search/display
    previous_slug   TEXT,                      -- preceding entry in reading order
    previous_title  TEXT,
    next_slug       TEXT,                       -- following entry in reading order
    next_title      TEXT,
    source_url      TEXT                        -- provenance (Wikisource page URL)
);

CREATE INDEX IF NOT EXISTS idx_articles_first_letter ON articles(first_letter);
CREATE INDEX IF NOT EXISTS idx_articles_title        ON articles(title COLLATE NOCASE);

-- Contributors (article authors). Signature initials belong on the join row,
-- since a contributor may sign with slightly different initials across entries.
CREATE TABLE IF NOT EXISTS authors (
    id              INTEGER PRIMARY KEY,
    slug            TEXT    NOT NULL UNIQUE,   -- e.g. "richard-lydekker"
    name            TEXT    NOT NULL,          -- e.g. "Richard Lydekker"
    wikisource_url  TEXT                        -- Author: page on Wikisource
);

CREATE TABLE IF NOT EXISTS article_authors (
    article_id  INTEGER NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
    author_id   INTEGER NOT NULL REFERENCES authors(id)  ON DELETE CASCADE,
    initials    TEXT,                          -- original EB1911 signature, e.g. "R. L.*"
    seq         INTEGER NOT NULL DEFAULT 0,    -- order of signing on the article
    PRIMARY KEY (article_id, author_id)
);

CREATE INDEX IF NOT EXISTS idx_article_authors_author ON article_authors(author_id);

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
    author_names,
    content='articles',
    content_rowid='id',
    tokenize='porter unicode61 remove_diacritics 2'
);

-- Keep the FTS index in sync with the content table.
CREATE TRIGGER IF NOT EXISTS articles_ai AFTER INSERT ON articles BEGIN
    INSERT INTO articles_fts(rowid, title, body, author_names)
    VALUES (new.id, new.title, new.body, new.author_names);
END;
CREATE TRIGGER IF NOT EXISTS articles_ad AFTER DELETE ON articles BEGIN
    INSERT INTO articles_fts(articles_fts, rowid, title, body, author_names)
    VALUES ('delete', old.id, old.title, old.body, old.author_names);
END;
CREATE TRIGGER IF NOT EXISTS articles_au AFTER UPDATE ON articles BEGIN
    INSERT INTO articles_fts(articles_fts, rowid, title, body, author_names)
    VALUES ('delete', old.id, old.title, old.body, old.author_names);
    INSERT INTO articles_fts(rowid, title, body, author_names)
    VALUES (new.id, new.title, new.body, new.author_names);
END;
