db_init() {
    mkdir -p "$KINDLE_DATA_DIR" "$KINDLE_CACHE_DIR"
    sqlite3 "$KINDLE_DB" "
        CREATE TABLE IF NOT EXISTS books (
            file_id    INTEGER PRIMARY KEY,
            filename   TEXT NOT NULL,
            size       INTEGER NOT NULL DEFAULT 0,
            extension  TEXT,
            scanned_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS clippings (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            book        TEXT NOT NULL,
            type        TEXT NOT NULL,
            content     TEXT,
            location    TEXT,
            imported_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS reading_positions (
            book_id         TEXT PRIMARY KEY,
            book_name       TEXT,
            position        INTEGER DEFAULT 0,
            total_positions INTEGER DEFAULT 0,
            percentage      REAL DEFAULT 0,
            timestamp       INTEGER
        );
        CREATE TABLE IF NOT EXISTS vocabulary (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            word      TEXT NOT NULL,
            stem      TEXT,
            usage     TEXT,
            book      TEXT,
            timestamp INTEGER
        );
        CREATE TABLE IF NOT EXISTS scans (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            scanned_at TEXT NOT NULL,
            book_count INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS cached_files (
            filename    TEXT PRIMARY KEY,
            device_size INTEGER NOT NULL DEFAULT 0,
            device_id   INTEGER NOT NULL DEFAULT 0,
            pulled_at   TEXT NOT NULL
        );
    "
    # Migrate: add percentage and total_positions columns to reading_positions if missing
    local has_percentage
    has_percentage=$(sqlite3 "$KINDLE_DB" "SELECT COUNT(*) FROM pragma_table_info('reading_positions') WHERE name='percentage';" 2>/dev/null || echo 0)
    if [ "$has_percentage" -eq 0 ]; then
        sqlite3 "$KINDLE_DB" "ALTER TABLE reading_positions ADD COLUMN percentage REAL DEFAULT 0;" 2>/dev/null || true
    fi
    local has_total
    has_total=$(sqlite3 "$KINDLE_DB" "SELECT COUNT(*) FROM pragma_table_info('reading_positions') WHERE name='total_positions';" 2>/dev/null || echo 0)
    if [ "$has_total" -eq 0 ]; then
        sqlite3 "$KINDLE_DB" "ALTER TABLE reading_positions ADD COLUMN total_positions INTEGER DEFAULT 0;" 2>/dev/null || true
    fi

    # Migrate: drop legacy scans table that had file_count column
    local has_file_count
    has_file_count=$(sqlite3 "$KINDLE_DB" "SELECT COUNT(*) FROM pragma_table_info('scans') WHERE name='file_count';" 2>/dev/null || echo 0)
    if [ "$has_file_count" -gt 0 ]; then
        sqlite3 "$KINDLE_DB" "
            DROP TABLE scans;
            CREATE TABLE scans (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                scanned_at TEXT NOT NULL,
                book_count INTEGER NOT NULL DEFAULT 0
            );
        "
    fi
}

db_query() {
    sqlite3 -separator '|' "$KINDLE_DB" "$@"
}

db_require() {
    if [ ! -f "$KINDLE_DB" ] || [ "$(db_query "SELECT COUNT(*) FROM books;")" = "0" ]; then
        echo -e "${RED}No scan data.${NC} Run ${BOLD}kindle scan${NC} first (with device plugged in)."
        return 1
    fi
    local last_scan
    last_scan=$(db_query "SELECT scanned_at FROM scans ORDER BY id DESC LIMIT 1;" 2>/dev/null || true)
    if [ -n "$last_scan" ]; then
        echo -e "${CYAN}Using scan from: ${last_scan}${NC}"
    fi
}
