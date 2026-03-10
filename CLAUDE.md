# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A bash CLI tool (`bin/kindle`) for managing Amazon Kindle devices on macOS via MTP (Media Transfer Protocol). It scans the device, pulls internal databases, and provides offline reading statistics.

## Running

```bash
bin/kindle              # show usage
bin/kindle scan         # scan device, pull databases & clippings (requires Kindle connected)
bin/kindle stats        # display reading stats dashboard (offline, requires prior scan)
bin/kindle ls [filter]  # list books (offline)
```

No build step. No tests. No linting. Pure bash.

## Dependencies

- `libmtp` — install via `brew install libmtp` (provides mtp-detect, mtp-files, mtp-getfile, mtp-sendfile, mtp-delfile, mtp-filetree)
- `sqlite3` — ships with macOS

## Architecture

Single entry point `bin/kindle` sources libraries from `lib/kindle/` in strict order:

1. **config.sh** — color codes, paths (`~/.kindle/`, `~/.kindle/kindle.db`), target DB filenames, book extensions
2. **deps.sh** — dependency checker (`check_deps`)
3. **db.sh** — SQLite schema init and query helpers; tables: `books`, `clippings`, `reading_positions`, `vocabulary`, `scans`
4. **ui.sh** — terminal UI helpers: `human_size`, `bar` (bar chart), `box_*` (box-drawing)
5. **parse.sh** — `parse_mtp_files` (awk parser for mtp-files output), `import_clippings` (My Clippings.txt parser), `import_kindle_dbs` (extracts data from pulled Kindle SQLite databases)
6. **mtp.sh** — all command implementations: `cmd_scan`, `cmd_detect`, `cmd_pull`, `cmd_push`, `cmd_clippings`, `cmd_books`, `cmd_tree`, `cmd_rm`, `cmd_ls`, `cmd_stats`
7. **stats.sh** — (empty, stats rendering is in `cmd_stats` inside mtp.sh)

Source order matters — later files depend on functions/variables from earlier files.

## Key Design Notes

- **MTP USB locking**: libmtp on macOS locks the USB device after each command. `cmd_scan` handles this by prompting the user to replug the Kindle between file pulls.
- **Pipe mode scanning**: `mtp-files` output is piped through `parse_mtp_files` (awk) so SIGPIPE kills the process early, releasing USB faster.
- **Offline-first**: `scan` pulls everything needed, then `stats`/`ls` work without the device. Data lives in `~/.kindle/kindle.db` (SQLite) with cached Kindle databases in `~/.kindle/cache/`.
- **WAL checkpoint**: When processing `fmcache.db`, the code copies to a working copy and runs `PRAGMA wal_checkpoint(TRUNCATE)` to merge the WAL before reading.
