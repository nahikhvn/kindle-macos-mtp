#!/usr/bin/env bash
# Sync reading data to external book tracking platforms

cmd_sync() {
    db_require || return 1

    if ! command -v jq &>/dev/null; then
        echo -e "${RED}Error:${NC} jq required for sync. Install: brew install jq"
        return 1
    fi

    local subcmd="${1:-}"
    shift 2>/dev/null || true

    case "$subcmd" in
        hardcover)  _sync_platform hardcover "$@" ;;
        status)     _sync_status "$@" ;;
        map)        _sync_map "$@" ;;
        unmap)      _sync_unmap "$@" ;;
        ""|help|-h) _sync_usage ;;
        *)
            echo -e "${RED}Unknown sync command:${NC} $subcmd"
            _sync_usage
            return 1
            ;;
    esac
}

_sync_usage() {
    cat <<EOF
Usage: kindle sync <platform> [options] [filter]

Platforms:
  hardcover [filter]    Sync to Hardcover (hardcover.app)
    -n, --dry-run       Show what would sync without making API calls

Management:
  status [platform]     Show sync mappings and last sync times
  map <file_id> <platform> <external_id>   Manually map a book
  unmap <file_id> <platform>               Remove a mapping

Configuration:
  Set HARDCOVER_TOKEN in .env.local (get from hardcover.app/account/api)
EOF
}

_sync_status() {
    local platform="${1:-}"
    local where=""
    [[ -n "$platform" ]] && where="WHERE bm.platform = '$(echo "$platform" | sed "s/'/''/g")'"

    local count
    count=$(db_query "SELECT COUNT(*) FROM book_mappings")

    if [[ "$count" -eq 0 ]]; then
        echo -e "No book mappings yet. Run ${BOLD}kindle sync <platform>${NC} to start syncing."
        return 0
    fi

    echo -e "${BOLD}Book Mappings${NC} ($count)"
    echo ""
    db_query "SELECT bm.platform, b.Title, bm.external_title, bm.external_id, bm.last_synced_at
        FROM book_mappings bm
        LEFT JOIN books b ON b.file_id = bm.file_id
        $where
        ORDER BY bm.platform, b.Title" | while IFS='|' read -r plat title ext_title ext_id synced; do
        printf "  %-12s %-30s → %-30s %s\n" \
            "[$plat]" "${title:0:30}" "${ext_title:0:30}" "${synced:+(synced $synced)}"
    done
}

_sync_map() {
    local file_id="${1:-}" platform="${2:-}" external_id="${3:-}"
    if [[ -z "$file_id" || -z "$platform" || -z "$external_id" ]]; then
        echo "Usage: kindle sync map <file_id> <platform> <external_id>"
        return 1
    fi
    local exists
    exists=$(db_query "SELECT COUNT(*) FROM books WHERE file_id = $file_id")
    if [[ "$exists" -eq 0 ]]; then
        echo -e "${RED}Error:${NC} No book with file_id=$file_id"
        return 1
    fi
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local esc_eid
    esc_eid=$(echo "$external_id" | sed "s/'/''/g")
    db_query "INSERT OR REPLACE INTO book_mappings (file_id, platform, external_id, mapped_at)
        VALUES ($file_id, '$(echo "$platform" | sed "s/'/''/g")', '$esc_eid', '$now')"
    echo -e "${GREEN}Mapped${NC} file_id=$file_id → $platform:$external_id"
}

_sync_unmap() {
    local file_id="${1:-}" platform="${2:-}"
    if [[ -z "$file_id" || -z "$platform" ]]; then
        echo "Usage: kindle sync unmap <file_id> <platform>"
        return 1
    fi
    db_query "DELETE FROM book_mappings
        WHERE file_id = $file_id AND platform = '$(echo "$platform" | sed "s/'/''/g")'"
    echo -e "${GREEN}Unmapped${NC} file_id=$file_id from $platform"
}

_sync_platform() {
    local platform="$1"
    shift
    local dry_run=0 filter=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--dry-run) dry_run=1; shift ;;
            *) filter="$1"; shift ;;
        esac
    done

    # Check platform auth
    case "$platform" in
        hardcover)
            if [[ -z "$HARDCOVER_TOKEN" ]]; then
                echo -e "${RED}Error:${NC} HARDCOVER_TOKEN not set."
                echo "Get your token from https://hardcover.app/account/api"
                echo "Add to .env.local: HARDCOVER_TOKEN=your_token_here"
                return 1
            fi
            ;;
    esac

    # Platform-specific init (e.g., fetch user_id)
    if [[ "$dry_run" -eq 0 ]]; then
        if ! "_sync_${platform}_init"; then
            return 1
        fi
    fi

    # Query books with metadata
    local where=""
    if [[ -n "$filter" ]]; then
        local escaped
        escaped=$(echo "$filter" | sed "s/'/''/g")
        where="AND (b.filename LIKE '%${escaped}%' COLLATE NOCASE
                 OR b.Title LIKE '%${escaped}%' COLLATE NOCASE)"
    fi

    local books
    books=$(db_query "SELECT b.file_id, b.filename, b.Title, b.Author, b.ISBN13,
            b.Rating, b.Review, b.Bookshelves
        FROM books b
        WHERE b.Title IS NOT NULL AND b.Title != '' $where
        ORDER BY b.Title")

    if [[ -z "$books" ]]; then
        echo "No books found${filter:+ matching \"$filter\"}."
        return 0
    fi

    [[ "$dry_run" -eq 1 ]] && echo -e "${YELLOW}DRY RUN${NC} — no API calls will be made"
    echo ""

    local total=0 synced=0 skipped=0 failed=0

    while IFS='|' read -r file_id filename title author isbn13 rating review bookshelves; do
        [[ -z "$file_id" ]] && continue
        total=$(( total + 1 ))

        echo -e "${BOLD}${title}${NC}${author:+ by $author}"

        # Look up reading position (same name-matching as cmd_progress in stats.sh:75)
        local short_name percentage
        short_name=$(echo "$filename" | sed 's/\(--\|_[A-F0-9]\{32\}\).*//; s/_/ /g; s/[[:space:]]*$//')
        local esc_short
        esc_short=$(echo "$short_name" | sed "s/'/''/g")
        percentage=$(db_query "SELECT percentage FROM reading_positions
            WHERE book_name LIKE '%${esc_short}%' COLLATE NOCASE
            ORDER BY timestamp DESC LIMIT 1" 2>/dev/null || true)

        # Get or create mapping
        local external_id
        external_id=$(db_query "SELECT external_id FROM book_mappings
            WHERE file_id = $file_id AND platform = '$platform'")

        if [[ -z "$external_id" ]]; then
            if [[ "$dry_run" -eq 1 ]]; then
                echo "  Would search for match (no mapping yet)"
                skipped=$(( skipped + 1 ))
                continue
            fi
            external_id=$(_sync_match_book "$platform" "$title" "$author" "$isbn13" "$file_id" || true)
            if [[ -z "$external_id" ]]; then
                echo -e "  ${YELLOW}Skipped${NC} (no match found)"
                skipped=$(( skipped + 1 ))
                continue
            fi
        fi

        if [[ "$dry_run" -eq 1 ]]; then
            echo -e "  Would sync: ${percentage:+progress ${percentage}% }${bookshelves:+shelf=$bookshelves }${rating:+rating=$rating}"
            synced=$(( synced + 1 ))
            continue
        fi

        # Sync data to platform
        if "_sync_${platform}_push" "$file_id" "$external_id" \
                "$percentage" "$bookshelves" "$rating" "$review"; then
            local now
            now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            db_query "UPDATE book_mappings SET last_synced_at = '$now'
                WHERE file_id = $file_id AND platform = '$platform'"
            echo -e "  ${GREEN}Synced${NC}${percentage:+ (${percentage}%)}"
            synced=$(( synced + 1 ))
        else
            echo -e "  ${RED}Failed${NC}"
            failed=$(( failed + 1 ))
        fi
    done <<< "$books"

    echo ""
    echo -e "${BOLD}Sync complete:${NC} $synced synced, $skipped skipped, $failed failed (of $total books)"
}

_sync_match_book() {
    local platform="$1" title="$2" author="$3" isbn13="$4" file_id="$5"
    local external_id="" external_title="" edition_id="" edition_pages=""

    # Try ISBN13 first (exact edition match)
    if [[ -n "$isbn13" ]]; then
        echo "  Searching by ISBN: $isbn13..." >&2
        local result
        result=$("_sync_${platform}_search_isbn" "$isbn13")
        if [[ -n "$result" ]]; then
            IFS='|' read -r external_id external_title edition_id edition_pages <<< "$result"
            echo -e "  ${GREEN}ISBN match:${NC} $external_title" >&2
        fi
    fi

    # Fall back to title+author search
    if [[ -z "$external_id" ]]; then
        local query="$title"
        [[ -n "$author" ]] && query="$title $author"
        echo "  Searching: $query..." >&2

        local results
        results=$("_sync_${platform}_search_title" "$query")

        if [[ -z "$results" ]]; then
            return 1
        fi

        # Display results for user selection
        local i=0
        echo "  Results:" >&2
        while IFS='|' read -r rid rtitle rauthor; do
            i=$(( i + 1 ))
            echo -e "    ${BOLD}$i)${NC} $rtitle${rauthor:+ by $rauthor}" >&2
        done <<< "$results"
        echo -e "    ${BOLD}0)${NC} Skip this book" >&2

        local choice=1
        if [[ -c /dev/tty ]]; then
            printf "  Select [1]: " >&2
            read -r choice </dev/tty || true
            choice="${choice:-1}"
        else
            echo "  Auto-selecting 1 (no tty)" >&2
        fi

        if [[ "$choice" == "0" ]]; then
            return 1
        fi

        local selected
        selected=$(echo "$results" | sed -n "${choice}p")
        if [[ -z "$selected" ]]; then
            echo -e "  ${RED}Invalid selection${NC}" >&2
            return 1
        fi

        external_id=$(echo "$selected" | cut -d'|' -f1)
        external_title=$(echo "$selected" | cut -d'|' -f2)

        # Get edition details for the selected book
        local edition_info
        edition_info=$("_sync_${platform}_get_edition" "$external_id")
        if [[ -n "$edition_info" ]]; then
            IFS='|' read -r edition_id edition_pages <<< "$edition_info"
        fi
    fi

    # Cache mapping
    if [[ -n "$external_id" ]]; then
        local now
        now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        local esc_title esc_eid
        esc_title=$(echo "$external_title" | sed "s/'/''/g")
        esc_eid=$(echo "$external_id" | sed "s/'/''/g")
        db_query "INSERT OR REPLACE INTO book_mappings
            (file_id, platform, external_id, external_title, edition_id, edition_pages, mapped_at)
            VALUES ($file_id, '$platform', '$esc_eid', '$esc_title',
                    '${edition_id:-}', ${edition_pages:-NULL}, '$now')"
        echo "$external_id"
    fi
}

# ── Hardcover backend ──────────────────────────────────────────────

_HARDCOVER_USER_ID=""

_sync_hardcover_init() {
    echo "Connecting to Hardcover..."
    local response
    response=$(_sync_hardcover_gql '{ me { id username account_privacy_setting_id } }')

    _HARDCOVER_USER_ID=$(echo "$response" | jq -r '(.data.me[0].id // .data.me.id) // empty')
    if [[ -z "$_HARDCOVER_USER_ID" ]]; then
        local err
        err=$(echo "$response" | jq -r '.errors[0].message // "unknown error"')
        echo -e "${RED}Hardcover auth failed:${NC} $err"
        return 1
    fi

    local username
    username=$(echo "$response" | jq -r '(.data.me[0].username // .data.me.username)')
    echo -e "Logged in as ${GREEN}${username}${NC} (id: $_HARDCOVER_USER_ID)"
    echo ""
}

_sync_hardcover_gql() {
    local query="$1"
    local variables="${2:-null}"
    sleep 1  # rate limit: 60 req/min
    curl -s --max-time 30 \
        -H "Authorization: Bearer $HARDCOVER_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg q "$query" --argjson v "$variables" '{query: $q, variables: $v}')" \
        "$HARDCOVER_API"
}

_sync_hardcover_search_isbn() {
    local isbn="$1"
    local response
    response=$(_sync_hardcover_gql \
        'query ($isbn: String!) { editions(where: {isbn_13: {_eq: $isbn}}) { id pages book { id title } } }' \
        "$(jq -n --arg isbn "$isbn" '{isbn: $isbn}')")

    local edition_id
    edition_id=$(echo "$response" | jq -r '.data.editions[0].id // empty')

    if [[ -z "$edition_id" ]]; then
        return 1
    fi

    local book_id book_title pages
    book_id=$(echo "$response" | jq -r '.data.editions[0].book.id // empty')
    book_title=$(echo "$response" | jq -r '.data.editions[0].book.title // empty')
    pages=$(echo "$response" | jq -r '.data.editions[0].pages // empty')

    echo "${book_id}|${book_title}|${edition_id}|${pages}"
}

_sync_hardcover_search_title() {
    local query="$1"
    local response
    response=$(_sync_hardcover_gql \
        'query ($q: String!) { search(query: $q, query_type: "Book", per_page: 5, page: 1) { results } }' \
        "$(jq -n --arg q "$query" '{q: $q}')")

    # results is a Typesense response object with hits[].document
    echo "$response" | jq -r '
        .data.search.results.hits[]?.document |
        [
            (.id // "" | tostring),
            (.title // ""),
            ((.author_names // [])[0] // "")
        ] | join("|")' 2>/dev/null
}

_sync_hardcover_get_edition() {
    local book_id="$1"
    local response
    response=$(_sync_hardcover_gql \
        'query ($id: Int!) { books(where: {id: {_eq: $id}}) { editions(limit: 1, order_by: {users_count: desc_nulls_last}) { id pages } } }' \
        "{\"id\": $book_id}")

    local eid pages
    eid=$(echo "$response" | jq -r '.data.books[0].editions[0].id // empty')
    pages=$(echo "$response" | jq -r '.data.books[0].editions[0].pages // empty')

    [[ -n "$eid" ]] && echo "${eid}|${pages}"
}

_sync_hardcover_ensure_user_book() {
    local file_id="$1" external_id="$2"

    # Check if we have a cached user_book_id
    local user_book_id
    user_book_id=$(db_query "SELECT user_book_id FROM book_mappings
        WHERE file_id = $file_id AND platform = 'hardcover'")

    if [[ -n "$user_book_id" && "$user_book_id" != "" ]]; then
        echo "$user_book_id"
        return 0
    fi

    # Check if user already has this book on Hardcover
    local response
    response=$(_sync_hardcover_gql \
        'query ($bookId: Int!, $userId: Int!) {
            user_books(where: {book_id: {_eq: $bookId}, user_id: {_eq: $userId}}) {
                id status_id rating
                user_book_reads(order_by: {id: desc}, limit: 1) { id progress_pages }
            }
        }' \
        "{\"bookId\": $external_id, \"userId\": $_HARDCOVER_USER_ID}")

    user_book_id=$(echo "$response" | jq -r '.data.user_books[0].id // empty')

    if [[ -n "$user_book_id" ]]; then
        # Cache existing user_book_id and read_id
        local read_id
        read_id=$(echo "$response" | jq -r '.data.user_books[0].user_book_reads[0].id // empty')
        db_query "UPDATE book_mappings
            SET user_book_id = '$user_book_id'${read_id:+, user_book_read_id = '$read_id'}
            WHERE file_id = $file_id AND platform = 'hardcover'"
        echo "$user_book_id"
        return 0
    fi

    # Create new user_book
    local edition_id
    edition_id=$(db_query "SELECT edition_id FROM book_mappings
        WHERE file_id = $file_id AND platform = 'hardcover'")

    local obj
    obj=$(jq -n --argjson bid "$external_id" '{book_id: $bid, status_id: 2}')
    [[ -n "$edition_id" ]] && obj=$(echo "$obj" | jq --argjson eid "$edition_id" '. + {edition_id: $eid}')
    local vars
    vars=$(jq -n --argjson obj "$obj" '{object: $obj}')

    response=$(_sync_hardcover_gql \
        'mutation ($object: UserBookCreateInput!) {
            insert_user_book(object: $object) {
                error
                user_book { id }
            }
        }' "$vars")

    user_book_id=$(echo "$response" | jq -r '.data.insert_user_book.user_book.id // empty')
    local err
    err=$(echo "$response" | jq -r '.data.insert_user_book.error // empty')

    if [[ -n "$err" ]]; then
        echo -e "  ${RED}Failed to add book:${NC} $err" >&2
        return 1
    fi

    if [[ -n "$user_book_id" ]]; then
        db_query "UPDATE book_mappings SET user_book_id = '$user_book_id'
            WHERE file_id = $file_id AND platform = 'hardcover'"
        echo "$user_book_id"
    fi
}

_sync_hardcover_push() {
    local file_id="$1" external_id="$2"
    local percentage="$3" bookshelves="$4" rating="$5" review="$6"

    # Ensure we have a user_book record
    local user_book_id
    user_book_id=$(_sync_hardcover_ensure_user_book "$file_id" "$external_id")
    if [[ -z "$user_book_id" ]]; then
        return 1
    fi

    # Map bookshelves → status_id
    local status_id=""
    case "$bookshelves" in
        to-read)             status_id=1 ;;
        currently-reading)   status_id=2 ;;
        read)                status_id=3 ;;
        did-not-finish|dnf)  status_id=5 ;;
    esac
    # Infer from progress if no explicit shelf
    if [[ -z "$status_id" && -n "$percentage" ]]; then
        local pct_int
        pct_int=$(printf "%.0f" "$percentage" 2>/dev/null || echo 0)
        if [[ "$pct_int" -ge 100 ]]; then
            status_id=3
        elif [[ "$pct_int" -gt 0 ]]; then
            status_id=2
        fi
    fi

    # Update status + rating in a single API call
    local obj="{}"
    [[ -n "$status_id" ]] && obj=$(echo "$obj" | jq --argjson s "$status_id" '. + {status_id: $s}')
    [[ -n "$rating" && "$rating" != "0" ]] && obj=$(echo "$obj" | jq --argjson r "$rating" '. + {rating: $r}')

    if [[ "$obj" != "{}" ]]; then
        local vars
        vars=$(jq -n --argjson id "$user_book_id" --argjson obj "$obj" '{id: $id, object: $obj}')

        local response
        response=$(_sync_hardcover_gql \
            'mutation ($id: Int!, $object: UserBookUpdateInput!) {
                update_user_book(id: $id, object: $object) {
                    error
                    user_book { id status_id rating }
                }
            }' "$vars")

        local err
        err=$(echo "$response" | jq -r '.data.update_user_book.error // empty')
        if [[ -n "$err" ]]; then
            echo -e "  ${RED}Status/rating update failed:${NC} $err" >&2
        fi
    fi

    # Update reading progress (convert percentage → pages)
    if [[ -n "$percentage" && "$percentage" != "0" ]]; then
        local edition_pages
        edition_pages=$(db_query "SELECT edition_pages FROM book_mappings
            WHERE file_id = $file_id AND platform = 'hardcover'")

        if [[ -n "$edition_pages" && "$edition_pages" -gt 0 ]] 2>/dev/null; then
            local pages_read
            pages_read=$(awk "BEGIN { printf \"%.0f\", $edition_pages * $percentage / 100 }")

            local read_id
            read_id=$(db_query "SELECT user_book_read_id FROM book_mappings
                WHERE file_id = $file_id AND platform = 'hardcover'")

            local edition_id
            edition_id=$(db_query "SELECT edition_id FROM book_mappings
                WHERE file_id = $file_id AND platform = 'hardcover'")

            if [[ -n "$read_id" && "$read_id" != "" ]]; then
                # Update existing read
                local read_obj="{\"progress_pages\": $pages_read}"
                [[ "$status_id" == "3" ]] && read_obj=$(echo "$read_obj" | jq --arg f "$(date -u +%Y-%m-%d)" '. + {finished_at: $f}')
                [[ -n "$edition_id" ]] && read_obj=$(echo "$read_obj" | jq --argjson eid "$edition_id" '. + {edition_id: $eid}')

                local response
                response=$(_sync_hardcover_gql \
                    'mutation ($id: Int!, $object: UserBookReadUpdateInput!) {
                        update_user_book_read(id: $id, object: $object) {
                            error
                            user_book_read { id }
                        }
                    }' \
                    "$(jq -n --argjson id "$read_id" --argjson obj "$read_obj" '{id: $id, object: $obj}')")

                local err
                err=$(echo "$response" | jq -r '.data.update_user_book_read.error // empty')
                if [[ -n "$err" ]]; then
                    echo -e "  ${RED}Progress update failed:${NC} $err" >&2
                fi
            else
                # Create new read
                local today
                today=$(date -u +"%Y-%m-%d")
                local read_obj="{\"progress_pages\": $pages_read, \"started_at\": \"$today\"}"
                [[ -n "$edition_id" ]] && read_obj=$(echo "$read_obj" | jq --argjson eid "$edition_id" '. + {edition_id: $eid}')

                local response
                response=$(_sync_hardcover_gql \
                    'mutation ($ubid: Int!, $read: DatesReadInput!) {
                        insert_user_book_read(user_book_id: $ubid, user_book_read: $read) {
                            error
                            user_book_read { id }
                        }
                    }' \
                    "$(jq -n --argjson ubid "$user_book_id" --argjson obj "$read_obj" '{ubid: $ubid, read: $obj}')")

                local err
                err=$(echo "$response" | jq -r '.data.insert_user_book_read.error // empty')
                if [[ -n "$err" ]]; then
                    echo -e "  ${RED}Failed to create read:${NC} $err" >&2
                fi

                local new_read_id
                new_read_id=$(echo "$response" | jq -r '.data.insert_user_book_read.user_book_read.id // empty')
                if [[ -n "$new_read_id" ]]; then
                    db_query "UPDATE book_mappings SET user_book_read_id = '$new_read_id'
                        WHERE file_id = $file_id AND platform = 'hardcover'"
                fi
            fi
        else
            echo -e "  ${YELLOW}No page count for edition — skipping progress${NC}" >&2
        fi
    fi

    return 0
}
