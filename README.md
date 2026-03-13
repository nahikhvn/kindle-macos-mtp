# kindle — MTP bridge for Kindle on macOS

> **Tested with Kindle firmware 5.19.2 on macOS (March 2026). No jailbreak required.** Works with stock Kindle Paperwhite, Basic, and Oasis devices over standard USB. Reads sideloaded books (including from Anna's Archive), clippings, reading progress, and vocabulary lookups via MTP.

A bash CLI for managing Amazon Kindle devices over USB on macOS. Scans the device once, pulls internal databases, then provides offline reading stats, progress tracking, structured data export (CSV/JSON/TSV), and sync to book tracking platforms like [Hardcover](https://hardcover.app).

## Install

```bash
brew install libmtp
git clone <repo> && ln -s "$(pwd)/bin/kindle" /usr/local/bin/kindle
```

`sqlite3` ships with macOS. On first run, `mtp-batch` (a small C helper) is auto-compiled from `lib/kindle/mtp_batch.c` using your Homebrew libmtp headers — no manual build step needed.

## Quick start

```
1. Plug in Kindle via USB
2. kindle scan              # pulls file list, databases, clippings (incremental)
3. Unplug — everything below works offline
4. kindle stats             # reading dashboard
5. kindle progress hp       # progress for books matching "hp"
6. kindle ls mobi           # list books matching "mobi"
7. kindle sync hardcover    # match new books to Hardcover
8. kindle sync update       # push reading progress to Hardcover
```

## Commands

| Command | Requires device | Description |
|---|---|---|
| `kindle scan` | yes | Scan device, pull databases & clippings (incremental — skips unchanged books) |
| `kindle stats` | no | Reading stats dashboard (books, formats, clippings, vocab) |
| `kindle progress <book>` | no | Reading progress for a book (bookmark, highlights, est. pages) |
| `kindle ls [filter]` | no | List all books, optionally filtered |
| `kindle export <fmt> <type> [filter]` | no | Export to ~/Downloads/ as csv, json, or tsv (`-o` to change) |
| `kindle db [sql]` | no | Open SQLite shell or run a one-off query |
| `kindle detect` | yes | Check if a Kindle is connected |
| `kindle tree` | yes | Full file/folder tree on device |
| `kindle pull <id> [dest]` | yes | Download a file by MTP file ID |
| `kindle push <file> [id]` | yes | Upload a file (optional parent folder ID) |
| `kindle clippings [dest]` | yes | Pull `My Clippings.txt` |
| `kindle books [dest]` | yes | Pull all book files (.kfx, .mobi, .pdf, .epub) |
| `kindle rm <id>` | yes | Delete a file by MTP file ID |
| `kindle sync hardcover [filter]` | no | Match and sync new books to Hardcover (skips already-mapped books) |
| `kindle sync update` | no | Push reading progress for all mapped books to Hardcover |
| `kindle sync hardcover -n` | no | Dry run — preview what would sync |
| `kindle sync status` | no | Show book mappings and last sync times |
| `kindle sync map <file_id> hardcover <id>` | no | Manually map a book to a Hardcover book ID |
| `kindle sync unmap <file_id> hardcover` | no | Remove a book mapping |

## How it works

### The MTP problem on macOS

libmtp on macOS locks the USB device when a process exits, requiring a physical replug before the next MTP operation. Every `mtp-*` CLI tool (mtp-files, mtp-getfile, etc.) is a separate process, so a scan that lists files then pulls 5 databases would need 6 replugs.

**Solution:** `mtp-batch` is a small C program (`lib/kindle/mtp_batch.c`) that links directly against libmtp and keeps a single MTP session open for the entire operation. It auto-compiles on first run — zero replugs needed for `kindle scan`.

If compilation fails (missing headers, no compiler), the tool falls back to individual `mtp-*` commands with replug prompts.

### Data flow

```
Kindle USB ──► kindle scan ──► ~/.kindle/
                                 ├── kindle.db          # local SQLite (books, clippings, vocab, positions)
                                 ├── cache/             # raw Kindle databases pulled from device
                                 │   ├── ksdk_annotation_v1.db   # reading positions, total locations
                                 │   ├── fmcache.db[/-wal/-shm]  # book metadata
                                 │   ├── vocab.db                 # vocabulary lookups
                                 │   └── Index.db                 # device index
                                 └── mtp-batch          # auto-compiled helper binary
```

`kindle scan` does:
1. Lists all files on the device — new books are inserted, unchanged books are skipped, and books removed from the device are cleaned up. Book mappings (for Hardcover sync) are preserved across scans even if MTP file IDs change.
2. Pulls `My Clippings.txt` → parsed into `clippings` table (highlights, notes, bookmarks)
3. Pulls Kindle internal databases → imported into `reading_positions` and `vocabulary` tables

All other commands read from `~/.kindle/kindle.db` — no device needed.

### Book metadata parsing

Filenames from Anna's Archive follow the format:

```
Title -- Author -- Series, Year -- Publisher -- ISBN -- md5 -- Anna's Archive.ext
```

During scan (or on first use after upgrading), these filenames are parsed into structured fields: `title`, `author`, `series`, `publisher`, and `isbn`. Non-Anna's Archive filenames (e.g. `hpmor_UUID.kfx`) get the title extracted by stripping the Kindle UUID suffix.

### Page estimation

Kindle uses "locations" (~128 bytes of text) as fixed position units instead of pages. Page numbers are only available for Amazon-purchased books with print edition mapping.

For sideloaded books, `kindle progress` estimates screen pages from locations:

```
est_page = current_location / locations_per_page
```

Default locations per page by screen size (at default font):

| Screen | Chars/page | Locs/page |
|---|---|---|
| 6" (Paperwhite, basic) | ~1280 | 10 |
| 7" (Oasis) | ~1664 | 13 |

Tune for your setup with environment variables:

```bash
KINDLE_SCREEN=7 kindle progress book        # 7" ereader
LOCS_PER_PAGE=7 kindle progress book        # large font on any screen
LOCS_PER_PAGE=15 kindle progress book       # small font
```

When total locations are available (from `ksdk_annotation_v1.db`), progress shows as "~Page X of ~Y (Z%)".

## Exporting data

`kindle export` dumps data in machine-readable formats for use with external tools and services.

```bash
kindle export csv books                    # → ~/Downloads/kindle-books.csv
kindle export json progress                # → ~/Downloads/kindle-progress.json
kindle export json highlights hp           # highlights for books matching "hp"
kindle export tsv vocabulary               # vocab lookups (tab-separated)
kindle export json all                     # everything in one JSON object
kindle export -o /tmp json all             # → /tmp/kindle-all.json
kindle export -o - csv books | wc -l       # pipe to stdout
```

**Formats:** `csv`, `json`, `tsv`
**Types:** `books`, `progress`, `highlights`, `notes`, `clippings`, `vocabulary`, `all`

Files are saved to `~/Downloads/` by default. Use `-o DIR` to change the output directory, or `-o -` to write to stdout for piping.

For ad-hoc queries, `kindle db` gives direct SQLite access:

```bash
kindle db                                  # interactive sqlite3 shell
kindle db "SELECT * FROM vocabulary LIMIT 5"
```

## Syncing to Hardcover

`kindle sync` pushes your Kindle reading data to [Hardcover](https://hardcover.app), a book tracking platform.

### Setup

1. Get your API token from https://hardcover.app/account/api
2. Add it to `.env.local`:
   ```bash
   HARDCOVER_TOKEN="your_token_here"
   ```

### What gets synced

- **Book matching** — matches books by ISBN13 first, then falls back to title+author search. Auto-selects when only one result is found; shows page counts for each edition when choosing between multiple results.
- **Reading progress** — Kindle location percentage converted to page numbers using the edition's page count from Hardcover. Falls back to bookmark locations from clippings when reading position data is unavailable (common for sideloaded books).
- **Status** — inferred from the `Bookshelves` column in the books table (`to-read`, `currently-reading`, `read`, `did-not-finish`) or auto-detected from reading progress.
- **Rating** — star rating from the `Rating` column in the books table.

Book-to-Hardcover mappings are cached in the `book_mappings` table. `kindle sync hardcover` skips already-mapped books and only prompts for new ones. Use `kindle sync update` to push reading progress for all mapped books.

```bash
kindle sync hardcover                # match and sync new books
kindle sync hardcover hp             # sync books matching "hp"
kindle sync update                   # push reading progress for mapped books
kindle sync hardcover --dry-run      # preview without making API calls
kindle sync status                   # check mapping and sync status
kindle sync map 42 hardcover 12345   # manually map file_id 42
```

## Architecture

```
bin/kindle                  # entry point, sources libs in order, routes subcommands
lib/kindle/
  config.sh                 # colors, paths, constants, screen/page settings
  deps.sh                   # dependency check, auto-compiles mtp-batch
  db.sh                     # SQLite schema, migrations, query helpers
  ui.sh                     # terminal formatting (human_size, bar charts, box drawing)
  parse.sh                  # parsers: mtp-files output, clippings, Kindle databases
  mtp.sh                    # all device and offline command implementations
  stats.sh                  # stats dashboard, progress, ls
  export.sh                 # export (csv/json/tsv) and db (raw sqlite3 access)
  sync.sh                   # sync to external platforms (Hardcover)
  mtp_batch.c               # single-session MTP helper (C, links against libmtp)
```

Source order matters — later files depend on functions from earlier ones.

## Database schema

| Table | Key columns | Source |
|---|---|---|
| `books` | file_id, Title, Author, Series, Publisher, ISBN13, Rating, Review, Bookshelves, filename, size, extension | MTP file listing + filename parsing |
| `clippings` | book, type (highlight/note/bookmark), content, location | My Clippings.txt |
| `reading_positions` | book_id, position, total_positions, percentage | ksdk_annotation_v1.db |
| `vocabulary` | word, stem, usage, book, timestamp | vocab.db |
| `scans` | scanned_at, book_count | scan metadata |
| `book_mappings` | file_id, platform, external_id, edition_id, edition_pages, user_book_id | sync mapping cache |
| `cached_files` | filename, device_size, device_id | tracks pulled files |
