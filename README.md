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
    Views/                          ContentView (TabView), BrowseTab, NotebookTab,
                                    ListenTab, SettingsTab, ArticleView,
                                    SelectableArticleText, AuthorArticlesView, FlowLayout
    Models/Article.swift            Value types (articles, notes, …)
    Database/Database.swift         Read-only SQLite/FTS5 access (system SQLite3)
    Store/LibraryStore.swift        Observable app state + debounced search
    Store/SettingsStore.swift       Appearance, font size, OpenAI credentials (Keychain)
    Store/ListenStore.swift         TTS synthesis + audio playlist / media player
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

Each page is fetched **rendered** (via the MediaWiki `action=parse` API), because
most EB1911 entries transclude their prose from the `Page:` namespace — the raw
wikitext holds only the header, so rendering is what yields the actual article
text, the author signature, and in-text cross-references.

> **Upgrading / re-scraping:** the resume state (`data/raw/.scrape_state.json`)
> records which titles were already fetched. If you scraped with an earlier
> version of this script (before rendered-HTML capture) your articles will be
> missing their bodies — clear the old output before re-running:
> ```bash
> rm -f data/raw/*.json data/raw/.scrape_state.json
> python3 scrape_eb1911.py && python3 build_db.py
> ```

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

A serif-styled bottom tab bar with four sections — **Browse**, **Notebook**,
**Listen**, **Settings** — each with its own navigation stack.

- **Browse** — search, browse and random in one pane. A **search field** sits at
  the top with a **Random dice** beside it. Type to get live, ranked full-text
  results (contributor names are indexed, so you can search by author too); clear
  the field and the **A–Z reading index** returns — a scrollable list of entries
  for one letter (title + two-line preview), a **sub-section scrubber**
  (Aa, Ab, Ac …), and an **A–Z rail**. The dice opens a random article.
- **Notebook** — a sub-navigation over four kept collections:
  - **Bookmarks** — articles you've saved. **Long-press any entry's title**
    anywhere in the app to Bookmark it; **swipe** to remove. Keyed by slug.
  - **Notes** — passages you saved with **Send to Notebook** (see Read), each
    linking back to its source article.
  - **Recent Searches** — tap to re-run in Browse; "Clear" to reset.
  - **Recent Random** — the random entries you've opened, tap to revisit.
- **Listen** — a **playlist** of article recordings plus a simple **media
  player** (play/pause, scrubber, skip). Recordings are generated on demand from
  the **Listen** button on any article using OpenAI's text-to-speech API and
  saved on device.
- **Settings** — a sub-navigation:
  - **Appearance** — follow the **System** theme or force **Light** / **Dark**,
    and pick an **article text size**.
  - **Listen** — store your **OpenAI API key** (kept in the Keychain, persisted
    between launches), choose a **voice** once authenticated, and inspect a
    **debug log** of every OpenAI request and response (including errors).
- **Read** — articles render in a serif body at your chosen text size, with a
  volume/page citation, a tappable **contributor byline**, a **Listen** control,
  and **See also** cross-reference chips. The body is **freely selectable**: pick
  any passage and the edit menu offers **Send to Notebook** alongside the usual
  Copy / Look Up / Share. The **Listen** control shows an **estimated OpenAI
  cost** for confirmation before generating; once a recording exists it becomes
  an inline **mini-player**. Previous/next navigation stays **pinned to the
  bottom** (in a sans-serif face) while the article scrolls beneath it; moving
  between neighbours **pages in place** with a directional slide (and a
  horizontal **swipe**), so Back always returns to the list you came from. On
  **iPad** the reading column (and the Browse index) is centered at article
  width, with the title centered above it.

The panes themselves have no title bars — the bottom tab bar's active state is
label enough, and Browse offers a **Hide Keyboard** button (and swipe-to-dismiss)
so the on-screen keyboard never covers the A–Z rail.
- **Browse by contributor** — tap an author's name in a byline to see every
  article they signed in the edition; tap through to any of them.

(The Wikisource source URL is still collected in the database for provenance;
it is simply not surfaced in the reading UI.)

### Listen (text-to-speech)

The **Listen** button on an article sends its text to OpenAI's
[`/v1/audio/speech`](https://developers.openai.com/api/docs/guides/text-to-speech)
endpoint (`tts-1`), streams back an mp3, and stores it under
`Documents/ListenAudio` with its metadata. Long articles are split under the
API's per-request character limit and the mp3 segments are concatenated. Your
API key is entered in **Settings › Listen** and held in the Keychain — it never
leaves the device except in the request to OpenAI. Before each request the
reader is shown the character count and an **estimated cost** (OpenAI's `tts-1`
list price), and every request/response is recorded to a debug log surfaced in
Settings. Playback uses `AVAudioPlayer` with a spoken-audio session; tracks
auto-advance through the playlist.

Playback **continues in the background and on the lock screen** (the app
declares the `audio` background mode on iOS). Track title and progress are
published to `MPNowPlayingInfoCenter`, and the lock-screen / Control Center
transport — play, pause, next, previous and the scrubber — is wired through
`MPRemoteCommandCenter`, so headphone and CarPlay controls work too.

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
