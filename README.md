# Britannica 1911 — Offline Reader

An offline, searchable reader for the **1911 Encyclopædia Britannica (11th edition)**,
built with SwiftUI for **iOS and macOS**. All content lives in an on-device
SQLite database with full-text search (FTS5) — no network is needed to read.

The public-domain source text comes from
[English Wikisource's EB1911 project](https://en.wikisource.org/wiki/1911_Encyclop%C3%A6dia_Britannica).

```
┌────────────────┐   scrape_eb1911.py   ┌────────────┐   build_db.py   ┌──────────────────┐
│  Wikisource    │ ───────────────────▶ │ data/raw/  │ ──────────────▶ │ britannica.sqlite │
│  EB1911 pages  │   (MediaWiki API)    │  *.json    │  (SQLite+FTS5)  │  (bundled asset)  │
└────────────────┘                      └────────────┘                 └────────┬─────────┘
                                                                                │ read-only
                                                                       ┌────────▼─────────┐
                                                                       │  SwiftUI app     │
                                                                       │  iOS + macOS     │
                                                                       └──────────────────┘
```

## Repository layout

```
data/
  schema.sql            SQLite schema (articles, authors, cross_references, FTS5)
  seed_articles.json    Hand-entered sample articles (works out of the box)
  build_db.py           Compiles JSON sources → britannica.sqlite   (stdlib only)
  scrape_eb1911.py      Downloads the full corpus from Wikisource    (stdlib only)
  raw/                  Scraper output (git-ignored)

app/
  Britannica1911.xcodeproj          Multiplatform Xcode project (iOS + macOS)
  Britannica1911/
    Britannica1911App.swift         App entry point
    Views/                          ContentView, Sidebar, ArticleView,
                                    AuthorArticlesView, FlowLayout
    Models/Article.swift            Value types
    Database/Database.swift         Read-only SQLite/FTS5 access (system SQLite3)
    Store/LibraryStore.swift        Observable app state + debounced search
    Assets.xcassets                 App icon slot + accent color
    britannica.sqlite               Bundled database (built by build_db.py)
```

## Quick start

### 1. Open and run the app

```bash
open app/Britannica1911.xcodeproj
```

Select the **Britannica1911** scheme and run on an iOS simulator, an iPhone/iPad,
or **My Mac**. It ships with ~19 sample articles so search, A–Z browse, and
cross-reference links all work immediately.

> The project targets **iOS 16 / macOS 13** and has **no third-party
> dependencies** — it uses Apple's built-in SQLite via `import SQLite3`.

### 2. Load the full encyclopedia

The bundled database is only a small sample. To pull the complete corpus, run
the scraper on a machine with internet access (nothing to `pip install`):

```bash
cd data
python3 scrape_eb1911.py --limit 500     # quick sample of 500 articles
# or, for everything (tens of thousands of entries — takes a long while):
python3 scrape_eb1911.py
python3 scrape_eb1911.py --resume         # continue an interrupted run

python3 build_db.py                        # compiles → app/Britannica1911/britannica.sqlite
```

Rebuild the app; Xcode picks up the regenerated `britannica.sqlite` automatically.

## How it works

### Database (`data/schema.sql`)

- **`articles`** — one row per entry (`slug`, `title`, `volume`, `pages`,
  `first_letter`, `body`, `author_names`, previous/next neighbours, `source_url`).
- **`authors`** + **`article_authors`** — normalized contributor data. EB1911
  entries are signed with the author's initials (e.g. `R. L.*`), which
  Wikisource links to the contributor's `Author:` page. The scraper captures
  the full name, the original initials, and the author-page URL. One `authors`
  row per person; the join table records who signed which article (and in what
  order for co-authored entries).
- **`articles_fts`** — an FTS5 external-content index over `title`, `body` and
  `author_names`, kept in sync by triggers. Tokenizer
  `porter unicode61 remove_diacritics 2` gives stemmed, accent-insensitive
  matching; results are ranked with `bm25` (title and author names weighted
  above body), so searching a contributor's name surfaces their articles.
- **`cross_references`** — "See also" links between entries. Targets are
  resolved to article ids at build time where possible; unresolved ones remain
  visible (and become live automatically once that entry is scraped in). The
  previous/next reading-order neighbours resolve the same way.

### Captured metadata

Per article the scraper records: **author(s)** and their signature initials,
**volume**, **page range**, **previous/next** entry (reading order), and
**cross-references**. Many short EB1911 entries were published unsigned, so a
null author is expected and handled gracefully.

### App

- **Browse** — an A–Z index in the sidebar; pick a letter to list its entries.
- **Search** — type in the sidebar search field for live, ranked full-text
  results with highlighted snippets. Contributor names are indexed, so you can
  search by author too.
- **Read** — articles render in a serif body with a volume/page citation, a
  tappable **contributor byline**, **See also** cross-reference chips, previous/next
  navigation, and a link back to the Wikisource source.
- **Browse by contributor** — tap an author's name in a byline to see every
  article they signed in the edition; tap through to any of them.
- Cross-reference, author, and prev/next taps push onto a navigation stack, so
  you can follow a chain of entries and swipe/click back.

## Notes & provenance

- The seed entries in `seed_articles.json` are **abridged, hand-entered
  samples** of genuine EB1911 articles, included so the app is demonstrable
  before you run the scraper. The scraper fetches the full, unabridged text.
- All EB1911 content is in the public domain (first published 1910–1911).
- Please respect the
  [Wikimedia API etiquette](https://www.mediawiki.org/wiki/API:Etiquette):
  the scraper sends a descriptive `User-Agent` and rate-limits requests.

## Regenerating the sample database

```bash
cd data && python3 build_db.py --no-raw     # seed articles only
```
