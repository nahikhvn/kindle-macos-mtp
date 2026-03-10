# --- export ---
cmd_export() {
    local format="${1:-}"
    local type="${2:-}"
    local filter="${3:-}"

    if [ -z "$format" ] || [ -z "$type" ]; then
        echo -e "${RED}Usage:${NC} kindle export <format> <type> [filter]" >&2
        echo "" >&2
        echo "Formats: csv, json, tsv" >&2
        echo "Types:   books, progress, highlights, notes, clippings, vocabulary, all" >&2
        echo "" >&2
        echo "Examples:" >&2
        echo "  kindle export csv books" >&2
        echo "  kindle export json progress" >&2
        echo "  kindle export json highlights hp" >&2
        echo "  kindle export tsv vocabulary" >&2
        echo "  kindle export json all" >&2
        return 1
    fi

    case "$format" in
        csv|json|tsv) ;;
        *)
            echo -e "${RED}Unknown format:${NC} $format (expected: csv, json, tsv)" >&2
            return 1
            ;;
    esac

    case "$type" in
        books|progress|highlights|notes|clippings|vocabulary|all) ;;
        *)
            echo -e "${RED}Unknown type:${NC} $type" >&2
            echo "Expected: books, progress, highlights, notes, clippings, vocabulary, all" >&2
            return 1
            ;;
    esac

    # Send db_require output to stderr so it doesn't pollute export data
    db_require >&2 || return 1

    if [ "$type" = "all" ]; then
        _export_all "$format" "$filter"
    else
        local query
        query=$(_export_query "$type" "$filter")
        _export_fmt "$format" "$query"
    fi
}

_export_query() {
    local type="$1" filter="$2"
    local safe=""

    if [ -n "$filter" ]; then
        safe=$(echo "$filter" | sed "s/'/''/g")
    fi

    case "$type" in
        books)
            local q="SELECT file_id, filename, extension, size, scanned_at FROM books"
            [ -n "$safe" ] && q="$q WHERE filename LIKE '%${safe}%' COLLATE NOCASE"
            echo "$q ORDER BY filename;"
            ;;
        progress)
            local q="SELECT book_id, book_name, position, total_positions, percentage, timestamp FROM reading_positions"
            [ -n "$safe" ] && q="$q WHERE book_name LIKE '%${safe}%' COLLATE NOCASE"
            echo "$q ORDER BY book_name;"
            ;;
        highlights)
            local q="SELECT book, content, location, imported_at FROM clippings WHERE type='highlight'"
            [ -n "$safe" ] && q="$q AND book LIKE '%${safe}%' COLLATE NOCASE"
            echo "$q ORDER BY book, id;"
            ;;
        notes)
            local q="SELECT book, content, location, imported_at FROM clippings WHERE type='note'"
            [ -n "$safe" ] && q="$q AND book LIKE '%${safe}%' COLLATE NOCASE"
            echo "$q ORDER BY book, id;"
            ;;
        clippings)
            local q="SELECT book, type, content, location, imported_at FROM clippings"
            [ -n "$safe" ] && q="$q WHERE book LIKE '%${safe}%' COLLATE NOCASE"
            echo "$q ORDER BY book, id;"
            ;;
        vocabulary)
            local q="SELECT word, stem, usage, book, timestamp FROM vocabulary"
            [ -n "$safe" ] && q="$q WHERE book LIKE '%${safe}%' COLLATE NOCASE"
            echo "$q ORDER BY timestamp DESC;"
            ;;
    esac
}

_export_fmt() {
    local format="$1" query="$2"

    case "$format" in
        csv)  sqlite3 -csv -header "$KINDLE_DB" "$query" ;;
        tsv)  sqlite3 -separator "$(printf '\t')" -header "$KINDLE_DB" "$query" ;;
        json) sqlite3 -json "$KINDLE_DB" "$query" ;;
    esac
}

_export_all() {
    local format="$1" filter="$2"
    local types="books progress highlights notes clippings vocabulary"

    if [ "$format" = "json" ]; then
        printf '{\n'
        local first=true
        for type in $types; do
            local query
            query=$(_export_query "$type" "$filter")
            local data
            data=$(sqlite3 -json "$KINDLE_DB" "$query" 2>/dev/null || echo "[]")
            $first || printf ',\n'
            printf '  "%s": %s' "$type" "$data"
            first=false
        done
        printf '\n}\n'
    else
        for type in $types; do
            local query
            query=$(_export_query "$type" "$filter")
            echo "# ${type}"
            _export_fmt "$format" "$query"
            echo ""
        done
    fi
}

# --- db ---
cmd_db() {
    local query="${1:-}"

    if [ ! -f "$KINDLE_DB" ]; then
        echo -e "${RED}No database.${NC} Run ${BOLD}kindle scan${NC} first." >&2
        return 1
    fi

    if [ -n "$query" ]; then
        sqlite3 -header -column "$KINDLE_DB" "$query"
    else
        echo -e "${CYAN}Opening kindle.db — type .help for SQLite commands, .quit to exit${NC}" >&2
        sqlite3 -header -column "$KINDLE_DB"
    fi
}
