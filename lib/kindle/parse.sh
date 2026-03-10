# Parse mtp-files multi-line output into: id|filename|size
parse_mtp_files() {
    awk '
    /^File ID:/ {
        if (length(id) > 0) printf "%s|%s|%s\n", id, name, size
        id = $3; name = ""; size = ""
    }
    /^[[:space:]]+Filename:/ {
        sub(/^[[:space:]]+Filename: /, "")
        name = $0
    }
    /^[[:space:]]+File size / {
        sub(/^[[:space:]]+File size /, "")
        size = $1 + 0
    }
    END {
        if (length(id) > 0) printf "%s|%s|%s\n", id, name, size
    }'
}

# Parse My Clippings.txt and insert into db
import_clippings() {
    local clip_file="$1"
    local now="$2"

    db_query "DELETE FROM clippings;"

    awk '
    BEGIN { RS = "==========" }
    {
        n = split($0, lines, "\n")
        book = ""; type = ""; loc = ""; content = ""
        for (i = 1; i <= n; i++) {
            line = lines[i]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            gsub(/^\xEF\xBB\xBF/, "", line)
            if (length(line) == 0) continue

            if (length(book) == 0) {
                book = line
                sub(/ \([^)]+\)$/, "", book)
                continue
            }
            if (line ~ /^- Your Highlight/) { type = "highlight"; loc = line; continue }
            if (line ~ /^- Your Note/)      { type = "note";      loc = line; continue }
            if (line ~ /^- Your Bookmark/)  { type = "bookmark";  loc = line; continue }
            if (length(type) > 0 && length(content) == 0) {
                content = line
            }
        }
        if (length(book) > 0 && length(type) > 0) {
            gsub(/'\''/, "'\'''\''", book)
            gsub(/'\''/, "'\'''\''", content)
            gsub(/'\''/, "'\'''\''", loc)
            printf "INSERT INTO clippings(book,type,content,location,imported_at) VALUES('\''%s'\'','\''%s'\'','\''%s'\'','\''%s'\'','\''%s'\'');\n", book, type, content, loc, now
        }
    }' "$clip_file" | db_query
}

# Extract data from pulled Kindle databases into our local db
import_kindle_dbs() {
    local cache="$KINDLE_CACHE_DIR"

    # --- ksdk_annotation_v1.db: reading positions ---
    if [ -f "$cache/ksdk_annotation_v1.db" ]; then
        local positions
        positions=$(sqlite3 -separator '|' "$cache/ksdk_annotation_v1.db" \
            "SELECT book_id, start_position, end_position, modified_time, serialized_payload
             FROM nonsyncable_annotations
             WHERE annotation_id = 'kindle.local_most_recent_read';" 2>/dev/null || true)

        if [ -n "$positions" ]; then
            db_query "DELETE FROM reading_positions;"
            echo "$positions" | while IFS='|' read -r book_id start_pos end_pos mtime payload; do
                # Extract shortPosition from JSON payload
                local pos
                pos=$(echo "$end_pos" | sed -n 's/.*"shortPosition":\([0-9]*\).*/\1/p')
                if [ -z "$pos" ]; then
                    pos=$(echo "$start_pos" | sed -n 's/.*"shortPosition":\([0-9]*\).*/\1/p')
                fi
                # Try to extract book name from payload (title preferred, then asin)
                local bname
                bname=$(echo "$payload" | sed -n 's/.*"title":"\([^"]*\)".*/\1/p')
                if [ -z "$bname" ]; then
                    bname=$(echo "$payload" | sed -n 's/.*"asin":"\([^"]*\)".*/\1/p')
                fi
                local safe_id safe_name
                safe_id=$(echo "$book_id" | sed "s/'/''/g")
                safe_name=$(echo "$bname" | sed "s/'/''/g")
                # Try to extract total positions from payload
                local total
                total=$(echo "$payload" | sed -n 's/.*"totalPositions":\([0-9]*\).*/\1/p')
                local pct=0
                if [ "${pos:-0}" -gt 0 ] && [ "${total:-0}" -gt 0 ]; then
                    pct=$(echo "$pos $total" | awk '{printf "%.1f", $1 * 100.0 / $2}')
                fi
                db_query "INSERT OR REPLACE INTO reading_positions(book_id, book_name, position, total_positions, percentage, timestamp)
                          VALUES('$safe_id', '$safe_name', ${pos:-0}, ${total:-0}, $pct, ${mtime:-0});"
            done
            echo -e "  ${GREEN}Imported reading positions from ksdk_annotation_v1.db${NC}"
        fi
    fi

    # --- vocab.db: vocabulary lookups ---
    if [ -f "$cache/vocab.db" ]; then
        local has_words
        has_words=$(sqlite3 "$cache/vocab.db" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='WORDS';" 2>/dev/null || echo 0)
        if [ "$has_words" -gt 0 ]; then
            db_query "DELETE FROM vocabulary;"
            sqlite3 -separator '|' "$cache/vocab.db" \
                "SELECT w.word, w.stem, l.usage, COALESCE(b.title, ''), w.timestamp
                 FROM WORDS w
                 LEFT JOIN LOOKUPS l ON l.word_key = w.id
                 LEFT JOIN BOOK_INFO b ON b.id = l.book_key
                 ORDER BY w.timestamp DESC;" 2>/dev/null | while IFS='|' read -r word stem usage book ts; do
                local sw ss su sb
                sw=$(echo "$word" | sed "s/'/''/g")
                ss=$(echo "$stem" | sed "s/'/''/g")
                su=$(echo "$usage" | sed "s/'/''/g")
                sb=$(echo "$book" | sed "s/'/''/g")
                db_query "INSERT INTO vocabulary(word, stem, usage, book, timestamp)
                          VALUES('$sw', '$ss', '$su', '$sb', $ts);"
            done
            local vcount
            vcount=$(db_query "SELECT COUNT(*) FROM vocabulary;")
            echo -e "  ${GREEN}Imported ${vcount} vocabulary lookups${NC}"
        fi
    fi

    # --- fmcache.db: book metadata / reading progress ---
    local fmdb=""
    if [ -f "$cache/fmcache.db" ] && [ -f "$cache/fmcache.db-wal" ]; then
        cp "$cache/fmcache.db" "$cache/fmcache_work.db"
        cp "$cache/fmcache.db-wal" "$cache/fmcache_work.db-wal"
        [ -f "$cache/fmcache.db-shm" ] && cp "$cache/fmcache.db-shm" "$cache/fmcache_work.db-shm"
        sqlite3 "$cache/fmcache_work.db" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
        fmdb="$cache/fmcache_work.db"
    elif [ -f "$cache/fmcache.db" ]; then
        fmdb="$cache/fmcache.db"
    fi

    if [ -n "$fmdb" ]; then
        local tables
        tables=$(sqlite3 "$fmdb" ".tables" 2>/dev/null || true)
        if [ -n "$tables" ]; then
            echo -e "  ${CYAN}fmcache.db tables: ${tables}${NC}"
            sqlite3 "$fmdb" ".schema" > "$cache/fmcache_schema.txt" 2>/dev/null || true
        fi

        # Try to extract reading progress from known Kindle table structures
        # We look for: content key, percentage read, title, and total page/location count
        local progress=""

        # Pattern: entries table (newer Kindle firmware)
        # p_percentage_read = bookmark position as %, p_content_size or similar for total
        if [ -z "$progress" ]; then
            progress=$(sqlite3 -separator '|' "$fmdb" \
                "SELECT p_cde_content_key,
                        COALESCE(p_percentage_read, 0),
                        COALESCE(p_title, ''),
                        COALESCE(p_last_access_position, 0),
                        COALESCE(p_content_size, 0)
                 FROM entries
                 WHERE p_percentage_read IS NOT NULL AND CAST(p_percentage_read AS REAL) > 0;" 2>/dev/null || true)
        fi

        # Pattern: content_catalog_metadata_tbl
        if [ -z "$progress" ]; then
            progress=$(sqlite3 -separator '|' "$fmdb" \
                "SELECT cde_content_key,
                        COALESCE(percent_finished, 0),
                        COALESCE(display_title, ''),
                        0,
                        0
                 FROM content_catalog_metadata_tbl
                 WHERE percent_finished IS NOT NULL AND CAST(percent_finished AS REAL) > 0;" 2>/dev/null || true)
        fi

        if [ -n "$progress" ]; then
            echo "$progress" | while IFS='|' read -r key pct title pos total; do
                [ -z "$key" ] && continue
                local safe_key safe_title
                safe_key=$(echo "$key" | sed "s/'/''/g")
                safe_title=$(echo "$title" | sed "s/'/''/g")
                # Normalize percentage to 0-100 (some Kindles store 0.0-1.0)
                local pct_val
                pct_val=$(echo "$pct" | awk '{if ($1 > 0 && $1 <= 1.0) printf "%.1f", $1 * 100; else printf "%.1f", $1}')
                db_query "INSERT OR REPLACE INTO reading_positions(book_id, book_name, percentage, position, total_positions, timestamp)
                          VALUES('$safe_key', '$safe_title', $pct_val, ${pos:-0}, ${total:-0}, 0);"
            done
            local pcount
            pcount=$(echo "$progress" | grep -c '[^[:space:]]' || true)
            echo -e "  ${GREEN}Imported ${pcount} reading progress entries from fmcache.db${NC}"
        fi

        rm -f "$cache/fmcache_work.db" "$cache/fmcache_work.db-wal" "$cache/fmcache_work.db-shm"
    fi

    # --- Index.db ---
    if [ -f "$cache/Index.db" ]; then
        local tables
        tables=$(sqlite3 "$cache/Index.db" ".tables" 2>/dev/null || true)
        if [ -n "$tables" ]; then
            echo -e "  ${CYAN}Index.db tables: ${tables}${NC}"
            sqlite3 "$cache/Index.db" ".schema" > "$cache/index_schema.txt" 2>/dev/null || true
        fi
    fi
}
