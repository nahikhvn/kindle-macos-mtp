# --- ls ---
cmd_ls() {
    local filter="${1:-}"

    db_require || return 1

    echo ""
    printf "${BOLD}%-8s  %-50s  %10s${NC}\n" "ID" "Filename" "Size"
    printf "%-8s  %-50s  %10s\n" "--------" "--------------------------------------------------" "----------"

    local query="SELECT file_id, filename, size FROM books"
    if [ -n "$filter" ]; then
        local safe_filter
        safe_filter=$(echo "$filter" | sed "s/'/''/g")
        query="$query WHERE filename LIKE '%${safe_filter}%' COLLATE NOCASE"
    fi
    query="$query ORDER BY filename;"

    db_query "$query" | while IFS='|' read -r id name size; do
        printf "%-8s  %-50s  %10s\n" "$id" "$name" "$size"
    done

    if [ -n "$filter" ]; then
        local cnt
        cnt=$(db_query "SELECT COUNT(*) FROM books WHERE filename LIKE '%$(echo "$filter" | sed "s/'/''/g")%' COLLATE NOCASE;")
        if [ "$cnt" = "0" ]; then
            echo "(no matches for '$filter')"
        fi
    fi
    echo ""
}

# --- progress ---
cmd_progress() {
    local filter="${1:-}"

    if [ -z "$filter" ]; then
        echo -e "${RED}Usage:${NC} kindle progress <book_name>"
        echo "Search by book title or partial name."
        return 1
    fi

    db_require || return 1
    echo ""

    local safe_filter
    safe_filter=$(echo "$filter" | sed "s/'/''/g")

    # Find matching books
    local books
    books=$(db_query "SELECT file_id, filename, size FROM books
                      WHERE filename LIKE '%${safe_filter}%' COLLATE NOCASE
                      ORDER BY filename;")

    if [ -z "$books" ]; then
        echo -e "  ${YELLOW}No books matching '${filter}'.${NC}"
        echo "  Use ${BOLD}kindle ls${NC} to see all books."
        return 0
    fi

    echo "$books" | while IFS='|' read -r id name size; do
        local display_name="$name"
        # Strip extension and UUID suffix for cleaner display
        display_name=$(echo "$display_name" | sed 's/_[A-F0-9]\{32\}\.kfx$/.kfx/')
        if [ ${#display_name} -gt 60 ]; then
            display_name="${display_name:0:57}..."
        fi

        echo -e "  ${BOLD}${display_name}${NC}"
        echo -e "  ${CYAN}$(printf '%.0s─' $(seq 1 60))${NC}"
        echo -e "  Size:       $(human_size "$size")"

        # Extract short book name for clippings matching (before first _ or --)
        local short_name
        short_name=$(echo "$name" | sed 's/\(--\|_[A-F0-9]\{32\}\).*//; s/_/ /g; s/[[:space:]]*$//')

        local has_progress=false

        # --- Bookmark from clippings (most reliable progress indicator) ---
        local bookmark_loc=""
        local bookmark_date=""
        local bm_data
        bm_data=$(db_query "SELECT location FROM clippings
                            WHERE type='bookmark'
                              AND (book LIKE '%${safe_filter}%' COLLATE NOCASE
                                   OR book LIKE '%${short_name}%' COLLATE NOCASE)
                            ORDER BY id DESC LIMIT 1;" 2>/dev/null || true)
        local bookmark_page=""
        if [ -n "$bm_data" ]; then
            bookmark_loc=$(echo "$bm_data" | sed -n 's/.*Location \([0-9]*\).*/\1/p')
            bookmark_page=$(echo "$bm_data" | sed -n 's/.*[Pp]age \([0-9]*\).*/\1/p')
            bookmark_date=$(echo "$bm_data" | sed -n 's/.*Added on \(.*\)/\1/p')
        fi

        # --- Furthest highlight/note location ---
        local max_highlight_loc=""
        local hl_data
        hl_data=$(db_query "SELECT location FROM clippings
                            WHERE type IN ('highlight','note')
                              AND (book LIKE '%${safe_filter}%' COLLATE NOCASE
                                   OR book LIKE '%${short_name}%' COLLATE NOCASE)
                            ORDER BY id DESC;" 2>/dev/null || true)
        if [ -n "$hl_data" ]; then
            # Find the highest location number across all highlights
            max_highlight_loc=$(echo "$hl_data" | sed -n 's/.*Location \([0-9]*\)[-–].*/\1/p; s/.*Location \([0-9]*\).*/\1/p' \
                | sort -n | tail -1)
        fi

        # Show bookmark position
        if [ -n "$bookmark_loc" ] || [ -n "$bookmark_page" ]; then
            if [ -n "$bookmark_page" ] && [ -n "$bookmark_loc" ]; then
                echo -e "  Bookmark:   Page ${BOLD}${bookmark_page}${NC} (Location ${bookmark_loc})"
            elif [ -n "$bookmark_page" ]; then
                echo -e "  Bookmark:   Page ${BOLD}${bookmark_page}${NC}"
            else
                echo -e "  Bookmark:   Location ${BOLD}${bookmark_loc}${NC}"
            fi
            has_progress=true
            if [ -n "$bookmark_date" ]; then
                echo -e "  Bookmarked: ${bookmark_date}"
            fi
        fi

        # Show furthest highlight if beyond bookmark
        if [ -n "$max_highlight_loc" ]; then
            if [ -z "$bookmark_loc" ] || [ "$max_highlight_loc" -gt "$bookmark_loc" ] 2>/dev/null; then
                echo -e "  Read to:    Location ${BOLD}${max_highlight_loc}${NC} (furthest highlight)"
                has_progress=true
            fi
        fi

        # --- Estimated page calculation ---
        local current_loc="${bookmark_loc:-$max_highlight_loc}"
        if [ -n "$current_loc" ] && [ "$current_loc" -gt 0 ] 2>/dev/null; then
            # Try to get total locations from reading_positions (ksdk data)
            local total_locs=""
            local safe_short
            safe_short=$(echo "$short_name" | sed "s/'/''/g")
            local rp_data
            rp_data=$(db_query "SELECT total_positions FROM reading_positions
                                WHERE total_positions > 0
                                  AND (book_name LIKE '%${safe_filter}%' COLLATE NOCASE
                                       OR book_name LIKE '%${safe_short}%' COLLATE NOCASE)
                                ORDER BY timestamp DESC LIMIT 1;" 2>/dev/null || true)
            if [ -n "$rp_data" ] && [ "$rp_data" -gt 0 ] 2>/dev/null; then
                total_locs="$rp_data"
            fi

            local est_page=$(( current_loc / LOCS_PER_PAGE ))
            [ "$est_page" -eq 0 ] && est_page=1

            if [ -n "$total_locs" ]; then
                local est_total=$(( total_locs / LOCS_PER_PAGE ))
                [ "$est_total" -eq 0 ] && est_total=1
                local est_pct=$(( current_loc * 100 / total_locs ))
                [ "$est_pct" -gt 100 ] && est_pct=100
                echo -e "  Est. Page:  ${BOLD}~${est_page}${NC} of ~${est_total} (${est_pct}%) [${KINDLE_SCREEN}\" screen]"
            else
                echo -e "  Est. Page:  ${BOLD}~${est_page}${NC} [${KINDLE_SCREEN}\" screen, default font]"
            fi
            has_progress=true
        fi

        # Highlight/note counts
        local highlight_count note_count bookmark_count
        highlight_count=$(db_query "SELECT COUNT(*) FROM clippings
                                    WHERE type='highlight'
                                      AND (book LIKE '%${safe_filter}%' COLLATE NOCASE
                                           OR book LIKE '%${short_name}%' COLLATE NOCASE);" 2>/dev/null || echo 0)
        note_count=$(db_query "SELECT COUNT(*) FROM clippings
                               WHERE type='note'
                                 AND (book LIKE '%${safe_filter}%' COLLATE NOCASE
                                      OR book LIKE '%${short_name}%' COLLATE NOCASE);" 2>/dev/null || echo 0)
        bookmark_count=$(db_query "SELECT COUNT(*) FROM clippings
                                   WHERE type='bookmark'
                                     AND (book LIKE '%${safe_filter}%' COLLATE NOCASE
                                          OR book LIKE '%${short_name}%' COLLATE NOCASE);" 2>/dev/null || echo 0)

        if [ "$highlight_count" -gt 0 ] || [ "$note_count" -gt 0 ] || [ "$bookmark_count" -gt 0 ]; then
            local parts=""
            [ "$bookmark_count" -gt 0 ] && parts="Bookmarks: ${BOLD}${bookmark_count}${NC}"
            [ "$highlight_count" -gt 0 ] && parts="${parts:+$parts  }Highlights: ${BOLD}${highlight_count}${NC}"
            [ "$note_count" -gt 0 ] && parts="${parts:+$parts  }Notes: ${BOLD}${note_count}${NC}"
            echo -e "  ${parts}"
            has_progress=true
        fi

        if ! $has_progress; then
            echo -e "  Progress:   ${YELLOW}No reading data. Rescan with device connected.${NC}"
        fi
        echo ""
    done
}

# --- stats ---
cmd_stats() {
    local W=62

    db_require || return 1
    echo ""

    local total_books
    total_books=$(db_query "SELECT COUNT(*) FROM books;")

    local total_size
    total_size=$(db_query "SELECT COALESCE(SUM(size),0) FROM books;")

    local ext_stats
    ext_stats=$(db_query "SELECT COUNT(*), extension, SUM(size) FROM books GROUP BY extension ORDER BY COUNT(*) DESC;")

    local max_ext_count=0
    if [ -n "$ext_stats" ]; then
        max_ext_count=$(echo "$ext_stats" | head -1 | cut -d'|' -f1)
    fi

    local top_books
    top_books=$(db_query "SELECT file_id, filename, size FROM books ORDER BY size DESC LIMIT 5;")

    # Clippings
    local total_highlights=0 total_notes=0 total_bookmarks=0 clipped_book_count=0
    local clippings_found=false

    local clip_count
    clip_count=$(db_query "SELECT COUNT(*) FROM clippings;" 2>/dev/null || echo 0)
    if [ "$clip_count" -gt 0 ]; then
        clippings_found=true
        total_highlights=$(db_query "SELECT COUNT(*) FROM clippings WHERE type='highlight';")
        total_notes=$(db_query "SELECT COUNT(*) FROM clippings WHERE type='note';")
        total_bookmarks=$(db_query "SELECT COUNT(*) FROM clippings WHERE type='bookmark';")
        clipped_book_count=$(db_query "SELECT COUNT(DISTINCT book) FROM clippings;")
    fi

    local clip_books=""
    if $clippings_found; then
        clip_books=$(db_query "SELECT COUNT(*), book FROM clippings WHERE type='highlight' GROUP BY book ORDER BY COUNT(*) DESC LIMIT 8;")
    fi

    # Vocabulary
    local vocab_count=0
    vocab_count=$(db_query "SELECT COUNT(*) FROM vocabulary;" 2>/dev/null || echo 0)

    # Reading positions
    local position_count=0
    position_count=$(db_query "SELECT COUNT(*) FROM reading_positions;" 2>/dev/null || echo 0)

    # ─── RENDER ───

    box_top $W
    box_empty $W
    box_text $W "${BOLD}              Kindle Reading Stats${NC}"
    box_empty $W
    box_line $W
    box_empty $W

    # Library
    box_text $W "  ${BOLD}Library${NC}"
    box_text $W "  ${CYAN}─────────────────────────────${NC}"
    box_text $W "  Books:             ${BOLD}$total_books${NC}"
    box_text $W "  Total Size:        ${BOLD}$(human_size $total_size)${NC}"
    box_empty $W

    # Format breakdown
    if [ -n "$ext_stats" ]; then
        box_text $W "  ${BOLD}By Format${NC}"
        box_text $W "  ${CYAN}─────────────────────────────${NC}"
        echo "$ext_stats" | while IFS='|' read -r cnt ext esize; do
            local pct bar_str size_str
            if [ "$total_books" -gt 0 ]; then
                pct=$(( cnt * 100 / total_books ))
            else
                pct=0
            fi
            bar_str=$(bar "$cnt" "$max_ext_count" 16)
            size_str=$(human_size "${esize:-0}")
            printf "│  %-6s %b  %3d (%2d%%)  %8s  │\n" "$ext" "$bar_str" "$cnt" "$pct" "$size_str"
        done
        box_empty $W
    fi

    # Largest books
    if [ -n "$top_books" ]; then
        box_text $W "  ${BOLD}Largest Books${NC}"
        box_text $W "  ${CYAN}─────────────────────────────${NC}"
        local rank=1
        echo "$top_books" | while IFS='|' read -r _id name size; do
            local hsize
            if [ "$size" -gt 0 ] 2>/dev/null; then
                hsize=$(human_size "$size")
            else
                hsize="???"
            fi
            if [ ${#name} -gt 38 ]; then
                name="${name:0:35}..."
            fi
            printf "│  %d. %-40s %8s    │\n" "$rank" "$name" "$hsize"
            rank=$((rank + 1))
        done
        box_empty $W
    fi

    box_line $W
    box_empty $W

    # Clippings
    box_text $W "  ${BOLD}Clippings & Highlights${NC}"
    box_text $W "  ${CYAN}─────────────────────────────${NC}"

    if $clippings_found; then
        box_text $W "  Highlights:       ${BOLD}$total_highlights${NC}"
        box_text $W "  Notes:            ${BOLD}$total_notes${NC}"
        box_text $W "  Bookmarks:        ${BOLD}$total_bookmarks${NC}"
        box_text $W "  Books Clipped:    ${BOLD}$clipped_book_count${NC}"
        box_empty $W

        if [ -n "$clip_books" ]; then
            box_text $W "  ${BOLD}Most Highlighted Books${NC}"
            box_text $W "  ${CYAN}─────────────────────────────${NC}"

            local max_clip_count
            max_clip_count=$(echo "$clip_books" | head -1 | cut -d'|' -f1)
            echo "$clip_books" | while IFS='|' read -r cnt btitle; do
                if [ ${#btitle} -gt 36 ]; then
                    btitle="${btitle:0:33}..."
                fi
                local clip_bar
                clip_bar=$(bar "$cnt" "$max_clip_count" 10)
                printf "│  %-38s %b %3d    │\n" "$btitle" "$clip_bar" "$cnt"
            done
        fi
    else
        box_text $W "  ${YELLOW}No clippings. Run: kindle scan (with device)${NC}"
    fi

    # Vocabulary
    if [ "$vocab_count" -gt 0 ]; then
        box_empty $W
        box_line $W
        box_empty $W
        box_text $W "  ${BOLD}Vocabulary${NC}"
        box_text $W "  ${CYAN}─────────────────────────────${NC}"
        box_text $W "  Words Looked Up:  ${BOLD}$vocab_count${NC}"

        local recent_words
        recent_words=$(db_query "SELECT word, book FROM vocabulary ORDER BY timestamp DESC LIMIT 5;")
        if [ -n "$recent_words" ]; then
            box_empty $W
            box_text $W "  ${BOLD}Recent Lookups${NC}"
            echo "$recent_words" | while IFS='|' read -r word book; do
                if [ ${#book} -gt 30 ]; then
                    book="${book:0:27}..."
                fi
                if [ -n "$book" ]; then
                    printf "│    %-20s  %s│\n" "$word" "$(printf "%-30s " "$book")"
                else
                    printf "│    %-52s│\n" "$word"
                fi
            done
        fi
    fi

    box_empty $W
    box_bottom $W
    echo ""
}
