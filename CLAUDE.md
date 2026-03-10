# CLAUDE.md

## Overview

Bash CLI (`bin/kindle`) for managing Kindle devices on macOS via MTP. Scans the device once, pulls internal databases, then provides offline reading stats and progress tracking.

## Running

```bash
bin/kindle              # show usage
bin/kindle scan         # scan device (requires Kindle connected via USB)
bin/kindle stats        # reading dashboard (offline)
bin/kindle progress hp  # progress for books matching "hp" (offline)
bin/kindle ls [filter]  # list books (offline)
```

No build step. No tests. No linting. Pure bash.

## Dependencies

- `libmtp` — `brew install libmtp`
- `sqlite3` — ships with macOS

## Configuration

Environment variables in `.env.example` (copy to `.env.local` for local overrides, gitignored):

- `KINDLE_SCREEN` — screen size: `6` (default) or `7`
- `LOCS_PER_PAGE` — locations per page for page estimation (default: 10 for 6", 13 for 7")

## Architecture

Single entry point `bin/kindle` sources `lib/kindle/` in strict order:

1. **config.sh** — colors, paths (`~/.kindle/`, `~/.kindle/kindle.db`), constants, screen/page settings
2. **deps.sh** — dependency checker, auto-compiles `mtp-batch`
3. **db.sh** — SQLite schema, migrations, query helpers
4. **ui.sh** — terminal formatting: `human_size`, `bar` (bar chart), `box_*` (box-drawing)
5. **parse.sh** — parsers: mtp-files output (awk), clippings, Kindle databases
6. **mtp.sh** — device commands: `cmd_scan`, `cmd_detect`, `cmd_pull`, `cmd_push`, `cmd_clippings`, `cmd_books`, `cmd_tree`, `cmd_rm`
7. **stats.sh** — offline commands: `cmd_ls`, `cmd_progress`, `cmd_stats`
8. **mtp_batch.c** — single-session MTP helper (C, links against libmtp)

Source order matters — later files depend on earlier ones.

## Key Design Notes

- **mtp-batch**: `mtp_batch.c` keeps a single MTP session open for the entire scan, avoiding the macOS libmtp USB locking issue (each process exit locks the device, requiring a replug). Auto-compiled on first run. Falls back to individual `mtp-*` commands with replug prompts if compilation fails.
- **Offline-first**: `scan` pulls everything needed, then `stats`/`progress`/`ls` work without the device. Data lives in `~/.kindle/kindle.db` (SQLite) with cached Kindle databases in `~/.kindle/cache/`.
- **WAL checkpoint**: When processing `fmcache.db`, copies to a working copy and runs `PRAGMA wal_checkpoint(TRUNCATE)` to merge the WAL before reading.
- **Page estimation**: Kindle uses "locations" (~128 bytes) instead of pages. `cmd_progress` estimates screen pages from locations using `LOCS_PER_PAGE`.
