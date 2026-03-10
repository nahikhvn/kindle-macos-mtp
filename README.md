# kindle — MTP bridge for Kindle on macOS

A bash CLI for managing Amazon Kindle devices over USB on macOS. Scans the device once, pulls internal databases, then provides offline reading stats and progress tracking.

## Install

```bash
brew install libmtp
git clone <repo> && ln -s "$(pwd)/bin/kindle" /usr/local/bin/kindle
```

`sqlite3` ships with macOS. On first run, `mtp-batch` (a small C helper) is auto-compiled from `lib/kindle/mtp_batch.c` using your Homebrew libmtp headers — no manual build step needed.

## Quick start

```
1. Plug in Kindle via USB
2. kindle scan          # pulls file list, databases, clippings
3. Unplug — everything below works offline
4. kindle stats         # reading dashboard
5. kindle progress hp   # progress for books matching "hp"
6. kindle ls mobi       # list books matching "mobi"
```

## Commands

| Command | Requires device | Description |
|---|---|---|
| `kindle scan` | yes | Scan device, pull databases & clippings to `~/.kindle/` |
| `kindle stats` | no | Reading stats dashboard (books, formats, clippings, vocab) |
| `kindle progress <book>` | no | Reading progress for a book (bookmark, highlights, est. pages) |
| `kindle ls [filter]` | no | List all books, optionally filtered |
| `kindle export <fmt> <type> [filter]` | no | Export data as csv, json, or tsv |
| `kindle db [sql]` | no | Open SQLite shell or run a one-off query |
| `kindle detect` | yes | Check if a Kindle is connected |
| `kindle tree` | yes | Full file/folder tree on device |
| `kindle pull <id> [dest]` | yes | Download a file by MTP file ID |
| `kindle push <file> [id]` | yes | Upload a file (optional parent folder ID) |
| `kindle clippings [dest]` | yes | Pull `My Clippings.txt` |
| `kindle books [dest]` | yes | Pull all book files (.kfx, .mobi, .pdf, .epub) |
| `kindle rm <id>` | yes | Delete a file by MTP file ID |

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
1. Lists all files on the device (stored in `books` table)
2. Pulls `My Clippings.txt` → parsed into `clippings` table (highlights, notes, bookmarks)
3. Pulls Kindle internal databases → imported into `reading_positions` and `vocabulary` tables

All other commands read from `~/.kindle/kindle.db` — no device needed.

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
kindle export csv books                    # library list
kindle export json progress                # reading progress as JSON
kindle export json highlights hp           # highlights for books matching "hp"
kindle export tsv vocabulary               # vocab lookups (tab-separated)
kindle export json all                     # everything in one JSON object
kindle export csv books > library.csv      # pipe to file
kindle export json progress | jq .         # pipe to jq
```

**Formats:** `csv`, `json`, `tsv`
**Types:** `books`, `progress`, `highlights`, `notes`, `clippings`, `vocabulary`, `all`

All informational output goes to stderr, so stdout is clean for piping.

For ad-hoc queries, `kindle db` gives direct SQLite access:

```bash
kindle db                                  # interactive sqlite3 shell
kindle db "SELECT * FROM vocabulary LIMIT 5"
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
  mtp_batch.c               # single-session MTP helper (C, links against libmtp)
```

Source order matters — later files depend on functions from earlier ones.

## Database schema

| Table | Key columns | Source |
|---|---|---|
| `books` | file_id, filename, size, extension | MTP file listing |
| `clippings` | book, type (highlight/note/bookmark), content, location | My Clippings.txt |
| `reading_positions` | book_id, position, total_positions, percentage | ksdk_annotation_v1.db |
| `vocabulary` | word, stem, usage, book, timestamp | vocab.db |
| `scans` | scanned_at, book_count | scan metadata |
| `cached_files` | filename, device_size, device_id | tracks pulled files |
