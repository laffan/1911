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
    Views/                          ContentView (TabView), BrowseTab, ColumnReader,
                                    NotebookTab, ListenTab, SettingsTab, ArticleView,
                                    ArticleColumnsView, SelectableArticleText,
                                    AuthorArticlesView, FlowLayout
    Models/Article.swift            Value types (articles, notes, …)
    Database/Database.swift         Read-only SQLite/FTS5 access (system SQLite3)
    Store/LibraryStore.swift        Observable app state + debounced search
    Store/ColumnLayout.swift        Column geometry (per-device proportions),
                                    glyph metrics, line breaking
    Store/ColumnIndexStore.swift    Background pagination of a letter into columns
    Store/ArticleColumnLayout.swift One article on the same column grid, plus
                                    the in-article find matcher
    Store/ArticleReaderModel.swift  Article pagination + find session (⌘F)
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
or **My Mac**. It ships with ~19 sample articles so search, the A–Z column
reader, and cross-reference links all work immediately.

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

A bottom tab bar with four sections — **Browse**, **Notebook**, **Listen**,
**Settings** — each with its own navigation stack. The UI chrome uses the
system sans-serif face; only the article reading view (title and body) is set
in serif for an encyclopedic feel.

- **Browse** — search and reading in one pane, laid out top to bottom: a
  **search field** with a **Random dice** beside it, then the **A–Z rail** and
  the **sub-section scrubber** (Aa, Ab, Ac …) as horizontal bars, then the
  reading surface itself. That surface sets the whole letter as **newspaper
  columns that scroll sideways** — a **third of a screen wide** on an iPad or a
  Mac, **four-fifths of it on an iPhone**, where thirds would be ribbons a few
  words across (see *Phone proportions* below). It is one continuous run
  of text in alphabetical order, where each entry's **full text flows on** into
  the columns that follow and the next entry's title falls **wherever the last
  one left off**, mid-column as often as not. Tap a letter to change section;
  tap a sub-section to fly to it. On an iPad or a Mac the alphabet is spread
  across the pane and can be **dragged along like a scrubber**; on an iPhone
  there is no room for twenty-six letters at a readable size, so **both bars
  scroll sideways** instead, each keeping where you are in view.
  Tapping an entry's title opens it in the full reading view; **double-clicking
  the title bookmarks it**, and a small **red bookmark** appears beside it
  (double-click again to remove it). The text itself is **freely selectable**,
  and the edit menu offers **Send to Notebook**. Typing swaps the columns for live, ranked
  full-text results (contributor names are indexed, so you can search by author
  too); clearing the field puts you back where you were reading. The dice opens
  a random article.
- **Notebook** — a sub-navigation over three kept collections:
  - **Bookmarks** — articles you've saved. **Double-click an entry's title** in
    the Browse columns or at the head of an article to keep it (or long-press
    any title anywhere in the app for a Bookmark menu); **swipe** to remove.
    Each kept entry carries a **Listen** control: it generates an audio version
    on first use (after confirming the estimated OpenAI cost) and becomes a
    play/pause button once a recording exists. Keyed by slug.
  - **Notes** — passages you saved with **Send to Notebook** (see Read), each
    linking back to its source article.
  - **Recent** — two sections: **Recent searches** (tap to re-run in Browse) and
    **Recent random** (entries you've opened via the dice), each with its own
    "Clear".
- **Listen** — a **playlist** of article recordings plus a simple **media
  player** (play/pause, scrubber, skip). Recordings are made from the **Listen**
  control on each entry in **Notebook › Bookmarks** — the reading views
  themselves stay free of audio chrome.
- **Settings** — a sub-navigation:
  - **Appearance** — follow the **System** theme or force **Light** / **Dark**,
    and pick an **article text size**.
  - **Listen** — store your **OpenAI API key** (kept in the Keychain, persisted
    between launches), choose a **voice** once authenticated, and inspect a
    **debug log** of every OpenAI request and response (including errors).
- **Read** — the single-article view, reached from a search hit, a cross
  reference, a byline or an entry title in the columns. An entry is set in the
  **same sideways columns as Browse**, at the same proportions — a third of a
  screen wide on an iPad or a Mac, four-fifths of it on an iPhone. The first
  column opens with the headword, its citation and a tappable **contributor
  byline**; the text flows on from column to column; **See also** closes the
  entry in a panel of its own. Every column carries a running head and where it
  falls in the entry ("3 / 7"). An article short enough to fit the screen — one
  or two columns — is **centred** in the pane rather than left hard against its
  leading edge. The headword takes the same **double-click to bookmark** as the
  Browse columns, and the body is **freely selectable**, with **Send to
  Notebook** in the edit menu alongside the usual Copy / Look Up / Share.
  Previous/next stays **pinned to the bottom** (in a sans-serif face) and
  **pages in place**, so Back always returns to the list you came from; the
  directional slide and the swipe that went with it are gone, since a
  horizontal drag now belongs to the columns.
- **Find in an article** — **⌘F** (or the magnifying glass in the article's
  toolbar, for a device with no keyboard) opens a find bar over the entry.
  Matches are highlighted in every column as you type, the bar counts them
  ("3 of 12"), and **⌘G** / **⇧⌘G** — or Return, or the chevrons — step
  between them, scrolling each match's column into view. **Esc** or **Done**
  closes it. Matching ignores case and accents and reads a wrapped line break
  as the space it stands for, so a phrase is found even where the column broke
  it across two lines; a phrase split across a *column* break is not, which is
  the same limitation selection has.

The panes themselves have no title bars — the bottom tab bar's active state is
label enough, and Browse offers a **Hide Keyboard** button (and swipe-to-dismiss)
so the on-screen keyboard never covers the columns.
- **Browse by contributor** — tap an author's name in a byline to see every
  article they signed in the edition; tap through to any of them.

(The Wikisource source URL is still collected in the database for provenance;
it is simply not surfaced in the reading UI.)

### The column reader, and how it stays fast

The corpus runs to tens of thousands of printed pages, so the sideways-scrolling
Browse surface can never lay all of it out. Five things keep it responsive:

1. **The text is broken into lines by hand, not by TextKit.** For each font size
   the app measures the advance width of ~500 characters once
   (`GlyphWidths`, cached per face and size), then wraps paragraphs with a
   greedy line breaker that costs one array lookup per character. Measuring a
   whole letter of the encyclopaedia takes well under a second instead of the
   many seconds a full text-layout pass would. Because the table is built from
   the *same* serif system font `Text` draws with — and because kerning and
   ligatures only ever pull glyphs closer — a line that fits by this measure
   always fits on screen.
2. **Only counts are kept.** A background pass streams the letter's entries out
   of SQLite one row at a time (`forEachEntry`), wraps each body, records how
   many lines it came to, and throws the text away. That is a handful of
   integers per entry, so the index for an entire letter costs a few hundred
   kilobytes — and positions, once assigned, never move.
3. **Everything sits on one line grid.** The letter is a single unbroken run of
   *slots*, one slot per line of body text, sliced into columns. Titles are
   measured in whole slots too, which is what lets an entry begin exactly where
   the previous one stopped instead of at a column top. The one interruption:
   a title is never split across a column break, so a heading that wouldn't fit
   in what's left of a column starts the next one and leaves the remainder
   blank.
4. **The stream only ever grows at the end.** Entries are published to the
   reader in small batches, in alphabetical order, so columns appear within a
   frame or two of choosing a letter while measuring continues behind them. New
   entries always land *after* what is already on screen, so nothing shifts
   under your finger; a hairline at the top shows the pass finishing.
5. **Drawing is virtualized and prefetched.** Columns live in a `LazyHStack` at
   a fixed width, so only the handful actually on screen are ever built no
   matter how far the stream runs. Rendering one needs that entry's wrapped lines,
   which are recomputed on demand, held in an LRU budgeted by wrapped lines,
   and prefetched a few *columns* ahead of the viewport on a background queue
   (entries would be the wrong unit — a single column can hold a dozen of the
   short ones) — so a fast flick draws from the cache rather than waiting on it.

Rotating the device or resizing the window changes the column geometry and so
re-measures the letter; that is debounced until the resize settles, and the
existing columns stay readable and scrollable meanwhile.

Long jumps are navigation, not scrolling: the A–Z rail and the sub-section
scrubber at the top of the pane move the reader straight to the column an
entry begins in, which is what keeps the buffer from ever being outrun.

Body text is drawn by the platform text view (`SelectableArticleText`) rather
than SwiftUI's `Text`, which is what allows an arbitrary passage to be selected
and sent to the Notebook — SwiftUI offers no way to add an action to a `Text`
selection menu. It is handed lines already broken to the column's exact width,
so it re-wraps nothing. The cost is a text view per block of text on screen;
titles stay plain `Text`, since a double-click there has to mean *bookmark*
rather than *select word*. Selection is per block, so a sentence that runs
across a column break is selected in two pieces.

#### One article on the same grid

A single entry is not the letter stream: it is finite, and small enough to wrap
outright. So the reading view keeps the wrapped lines instead of throwing them
away, and slices them onto the same line grid the Browse columns use
(`ArticleColumnLayout`). Two things follow from having the whole entry in hand:

* the run of columns has a **known width**, so an article that comes to one or
  two columns is centred in the pane rather than left against its leading edge;
* **⌘F** can count every match in the entry, not just the ones on screen — the
  find searches each column's text exactly as that column draws it, which is
  what makes a match a range the text view can highlight directly.

The masthead — headword, citation, byline — is measured in whole line slots
before the body is laid out, exactly as a title is in Browse, so the first
column's text picks up on the same grid as every other column's.

#### Phone proportions

A third of an iPad is a newspaper column; a third of an iPhone is a ribbon
~130pt across, which at reading size carries four or five words to the line.
So the page is proportioned per device by one small type, `ColumnMetrics`
(`.wide` for iPad, Mac and any regular-width window; `.phone` for a
compact-width pane), which is part of the style key — moving between the two,
by rotation or an iPad split view, re-measures the letter like any other
geometry change. It sets four things:

| | `.wide` | `.phone` |
|---|---|---|
| column width | ⅓ of the pane | ⅘ of the pane |
| max column width | — | 420pt |
| padding around the text | 50pt | 24pt |
| body type | as chosen in Settings | ×0.85 |

Padding is on every side of a column's text, so the gutter between two columns
reads as twice it, and it is clamped on a narrow column so the text can never
collapse to a ribbon. The ceiling on the phone's column width matters in
landscape, where four-fifths of the screen would otherwise be 600pt+ of prose
to a line; past it the slice stops growing and simply yields more columns per
screen. The ×0.85 on the article text size applies to the columns only (the
single-article view is unchanged) — one line of prose on a phone then carries a
phrase rather than a word or two. It is the knob to turn if the phone type
wants resizing.

### Listen (text-to-speech)

> **Where it lives.** The reading views carry no audio chrome; recordings are
> made from the **Listen** control on each entry in **Notebook › Bookmarks**
> (`ListenButton`), which is also where an existing recording plays from.

The **Listen** control sends an entry's text to OpenAI's
[`/v1/audio/speech`](https://developers.openai.com/api/docs/guides/text-to-speech)
endpoint (`tts-1`), streams back an mp3, and stores it under
`Documents/ListenAudio` with its metadata. Long articles are split into several
requests (a couple of thousand characters each) whose mp3 responses are stitched
together; each request runs on a long-timeout session and is retried a few times
on transient failures, so full-length entries no longer time out. **Progress is
shown live** — a spinner on the entry and a banner in the Listen pane report
"clip N of M" as the audio is built. Your API key is entered in
**Settings › Listen** and held in the Keychain — it never leaves the device
except in the request to OpenAI. Before each request the
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
