# --- scan ---
cmd_scan() {
    db_init

    local tmpfile
    tmpfile=$(mktemp)
    trap "rm -f '$tmpfile'" EXIT

    if [ -x "$MTP_BATCH" ]; then
        _scan_batch "$tmpfile"
    else
        _scan_legacy "$tmpfile"
    fi

    # --- Store books in db ---
    local total_files
    total_files=$(wc -l < "$tmpfile" | tr -d ' ')

    if [ "$total_files" -eq 0 ]; then
        echo -e "${RED}Failed to list files. Is the Kindle connected?${NC}"
        return 1
    fi

    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    db_query "DELETE FROM books;"
    while IFS='|' read -r id name size; do
        local ext
        ext=$(echo "$name" | sed -n 's/.*\(\.[a-zA-Z0-9]*\)$/\1/p' | tr '[:upper:]' '[:lower:]')
        case "$ext" in
            .kfx|.mobi|.pdf|.epub)
                local safe_name
                safe_name=$(echo "$name" | sed "s/'/''/g")
                db_query "INSERT OR REPLACE INTO books(file_id, filename, size, extension, scanned_at)
                          VALUES($id, '$safe_name', $size, '$ext', '$now');"
                ;;
        esac
    done < "$tmpfile"

    local book_count
    book_count=$(db_query "SELECT COUNT(*) FROM books;")
    db_query "INSERT INTO scans(scanned_at, book_count) VALUES('$now', $book_count);"

    echo -e "  ${GREEN}Found ${total_files} files, ${BOLD}${book_count}${NC}${GREEN} books${NC}"
    echo ""

    # --- Import data from pulled files ---
    echo -e "${BOLD}[Phase 2]${NC} Extracting reading data..."

    local clip_file="${KINDLE_CACHE_DIR}/My Clippings.txt"
    if [ -f "$clip_file" ]; then
        import_clippings "$clip_file" "$now"
        local ccount
        ccount=$(db_query "SELECT COUNT(*) FROM clippings;")
        echo -e "  ${GREEN}Imported ${ccount} clippings${NC}"
    fi

    import_kindle_dbs

    echo ""
    echo -e "${GREEN}Scan complete.${NC} Run ${BOLD}kindle stats${NC}, ${BOLD}kindle progress <book>${NC}, or ${BOLD}kindle ls${NC}"
}

# Single MTP session: list files + pull targets at once. No replugging.
_scan_batch() {
    local tmpfile="$1"
    echo -e "${BOLD}[Phase 1]${NC} Scanning Kindle (single session)..."
    echo ""

    "$MTP_BATCH" scan "$KINDLE_CACHE_DIR" \
        "${KINDLE_TARGET_DBS[@]}" "My Clippings.txt" \
        > "$tmpfile"

    # Update cached_files records for successfully pulled files
    local now_ts
    now_ts=$(date '+%Y-%m-%d %H:%M:%S')
    for target in "${KINDLE_TARGET_DBS[@]}" "My Clippings.txt"; do
        if [ -f "${KINDLE_CACHE_DIR}/${target}" ]; then
            local safe_name fsize
            safe_name=$(echo "$target" | sed "s/'/''/g")
            fsize=$(stat -f%z "${KINDLE_CACHE_DIR}/${target}" 2>/dev/null || echo 0)
            db_query "INSERT OR REPLACE INTO cached_files(filename, device_size, device_id, pulled_at)
                      VALUES('$safe_name', $fsize, 0, '$now_ts');"
        fi
    done
}

# Fallback: individual mtp-* tools with replug prompts between pulls
_scan_legacy() {
    local tmpfile="$1"
    echo -e "${BOLD}[Phase 1]${NC} Listing files on Kindle..."

    mtp-files 2>&1 | parse_mtp_files > "$tmpfile" || true

    local total_files
    total_files=$(wc -l < "$tmpfile" | tr -d ' ')
    if [ "$total_files" -eq 0 ]; then
        return
    fi

    echo -e "  Found $(wc -l < "$tmpfile" | tr -d ' ') files"
    echo ""

    # Find target files on device
    local targets_found=""
    for target in "${KINDLE_TARGET_DBS[@]}"; do
        local match
        match=$(grep "|${target}|" "$tmpfile" 2>/dev/null || true)
        if [ -n "$match" ]; then
            targets_found="${targets_found}${match}\n"
        fi
    done
    local clip_match
    clip_match=$(grep -i '[Cc]lippings\.txt' "$tmpfile" 2>/dev/null || true)
    if [ -n "$clip_match" ]; then
        targets_found="${targets_found}${clip_match}\n"
    fi

    if [ -z "$targets_found" ]; then
        echo -e "  ${YELLOW}No target files found on device.${NC}"
        return
    fi

    # Compare with cache, pull only what changed
    local pullfile
    pullfile=$(mktemp)
    trap "rm -f '$tmpfile' '$pullfile'" EXIT

    local cache_count=0
    echo -e "  Comparing with local cache..."
    while IFS='|' read -r id name size; do
        [ -z "$id" ] && continue
        local safe_name
        safe_name=$(echo "$name" | sed "s/'/''/g")
        local cached_size
        cached_size=$(db_query "SELECT device_size FROM cached_files WHERE filename='$safe_name';" 2>/dev/null || true)
        local local_file="${KINDLE_CACHE_DIR}/${name}"

        if [ -z "$cached_size" ] || [ ! -f "$local_file" ]; then
            printf "    ${GREEN}+${NC} %-30s (%s)  ${GREEN}new${NC}\n" "$name" "$(human_size "$size")"
            echo "${id}|${name}|${size}" >> "$pullfile"
        elif [ "$cached_size" != "$size" ]; then
            printf "    ${YELLOW}~${NC} %-30s %s → %s  ${YELLOW}changed${NC}\n" "$name" "$(human_size "$cached_size")" "$(human_size "$size")"
            echo "${id}|${name}|${size}" >> "$pullfile"
        else
            printf "    ${CYAN}=${NC} %-30s (%s)  ${CYAN}cached${NC}\n" "$name" "$(human_size "$size")"
            cache_count=$((cache_count + 1))
        fi
    done < <(echo -e "$targets_found")

    local pull_count=0
    if [ -s "$pullfile" ]; then
        pull_count=$(wc -l < "$pullfile" | tr -d ' ')
    fi

    echo ""

    if [ "$pull_count" -eq 0 ]; then
        echo -e "  ${GREEN}All files up to date.${NC} ($cache_count cached)"
        rm -f "$pullfile"
        return
    fi

    echo -e "  ${BOLD}${pull_count}${NC} to sync, ${cache_count} cached"
    echo ""
    echo -e "  ${YELLOW}Replug Kindle and press Enter to start syncing (s to skip all):${NC}"
    read -r reply </dev/tty

    if [ "$reply" = "s" ] || [ "$reply" = "S" ]; then
        echo -e "  ${YELLOW}Skipped sync.${NC}"
        rm -f "$pullfile"
        return
    fi

    local pulled=0 idx=0
    while IFS='|' read -r id name size; do
        [ -z "$id" ] && continue
        idx=$((idx + 1))
        local dest="${KINDLE_CACHE_DIR}/${name}"
        printf "  [%d/%d] Pulling %s... " "$idx" "$pull_count" "$name"

        if mtp-getfile "$id" "$dest" &>/dev/null && [ -f "$dest" ]; then
            echo -e "${GREEN}ok${NC}"
            local safe_name pull_ts
            safe_name=$(echo "$name" | sed "s/'/''/g")
            pull_ts=$(date '+%Y-%m-%d %H:%M:%S')
            db_query "INSERT OR REPLACE INTO cached_files(filename, device_size, device_id, pulled_at)
                      VALUES('$safe_name', $size, $id, '$pull_ts');"
            pulled=$((pulled + 1))
        else
            echo ""
            if [ "$idx" -lt "$pull_count" ]; then
                echo -en "    ${YELLOW}Device locked. Replug and press Enter (s to skip remaining):${NC} "
            else
                echo -en "    ${YELLOW}Device locked. Replug and press Enter (s to skip):${NC} "
            fi
            read -r reply </dev/tty
            if [ "$reply" = "s" ] || [ "$reply" = "S" ]; then
                echo -e "    ${YELLOW}Skipped remaining${NC}"
                break
            fi
            printf "  [%d/%d] Pulling %s... " "$idx" "$pull_count" "$name"
            if mtp-getfile "$id" "$dest" &>/dev/null && [ -f "$dest" ]; then
                echo -e "${GREEN}ok${NC}"
                local safe_name pull_ts
                safe_name=$(echo "$name" | sed "s/'/''/g")
                pull_ts=$(date '+%Y-%m-%d %H:%M:%S')
                db_query "INSERT OR REPLACE INTO cached_files(filename, device_size, device_id, pulled_at)
                          VALUES('$safe_name', $size, $id, '$pull_ts');"
                pulled=$((pulled + 1))
            else
                echo -e "${RED}failed${NC}"
            fi
        fi
    done < "$pullfile"

    echo ""
    echo -e "  ${GREEN}Synced: ${pulled}${NC} file(s)"
    if [ "$pulled" -lt "$pull_count" ]; then
        echo -e "  ${YELLOW}Skipped: $((pull_count - pulled))${NC} file(s)"
    fi

    rm -f "$pullfile"
}

# --- detect ---
cmd_detect() {
    echo -e "${CYAN}Scanning for MTP devices...${NC}"
    if [ -x "$MTP_BATCH" ]; then
        local output
        if output=$("$MTP_BATCH" detect 2>/dev/null); then
            echo -e "${GREEN}Kindle detected!${NC}"
            echo "$output" | while IFS='|' read -r key val; do
                [ -n "$val" ] && echo "  ${key}: ${val}"
            done
            return 0
        else
            echo -e "${RED}No MTP devices found.${NC}"
            echo "Make sure your Kindle is plugged in via USB."
            return 1
        fi
    else
        local output
        if output=$(mtp-detect 2>&1); then
            if echo "$output" | grep -qi "kindle\|amazon"; then
                echo -e "${GREEN}Kindle detected!${NC}"
                echo "$output" | grep -i "friendly\|model\|serial\|manufacturer" | head -6
                return 0
            fi
        fi
        echo -e "${RED}No MTP devices found.${NC}"
        echo "Make sure your Kindle is plugged in via USB."
        return 1
    fi
}

# --- pull ---
cmd_pull() {
    local file_id="${1:-}"
    local dest="${2:-}"

    if [ -z "$file_id" ]; then
        echo -e "${RED}Usage:${NC} kindle pull <file_id> [destination]"
        echo "Use 'kindle ls' to find file IDs."
        return 1
    fi

    if [ -z "$dest" ]; then
        dest="./mtp-download-${file_id}"
        echo -e "${YELLOW}No destination specified, saving to: ${dest}${NC}"
    fi

    echo -e "${CYAN}Downloading file ID ${file_id}...${NC}"
    if [ -x "$MTP_BATCH" ]; then
        if "$MTP_BATCH" get "$file_id" "$dest" 2>/dev/null && [ -f "$dest" ]; then
            echo -e "${GREEN}Saved to: ${dest}${NC}"
        else
            echo -e "${RED}Failed to download file ID ${file_id}.${NC}"
            return 1
        fi
    else
        if mtp-getfile "$file_id" "$dest" 2>&1; then
            echo -e "${GREEN}Saved to: ${dest}${NC}"
        else
            echo -e "${RED}Failed to download file ID ${file_id}.${NC}"
            return 1
        fi
    fi
}

# --- push ---
cmd_push() {
    local file="${1:-}"
    local parent_id="${2:-0}"

    if [ -z "$file" ] || [ ! -f "$file" ]; then
        echo -e "${RED}Usage:${NC} kindle push <local_file> [parent_folder_id]"
        echo "parent_folder_id defaults to 0 (root). Use 'kindle ls' to find folder IDs."
        return 1
    fi

    echo -e "${CYAN}Uploading ${file} to Kindle (parent folder ID: ${parent_id})...${NC}"
    if [ -x "$MTP_BATCH" ]; then
        if "$MTP_BATCH" send "$file" "$parent_id" 2>/dev/null; then
            echo -e "${GREEN}Uploaded: ${file}${NC}"
        else
            echo -e "${RED}Failed to upload ${file}.${NC}"
            return 1
        fi
    else
        if mtp-sendfile "$file" "$parent_id" 2>&1; then
            echo -e "${GREEN}Uploaded: ${file}${NC}"
        else
            echo -e "${RED}Failed to upload ${file}.${NC}"
            return 1
        fi
    fi
}

# --- clippings (standalone) ---
cmd_clippings() {
    local dest="${1:-./My Clippings.txt}"

    echo -e "${CYAN}Finding and pulling My Clippings.txt...${NC}"
    if [ -x "$MTP_BATCH" ]; then
        local tmpdir
        tmpdir=$(mktemp -d)
        "$MTP_BATCH" scan "$tmpdir" "My Clippings.txt" > /dev/null 2>&1
        if [ -f "$tmpdir/My Clippings.txt" ]; then
            mv "$tmpdir/My Clippings.txt" "$dest"
        else
            echo -e "${RED}Could not find My Clippings.txt on the device.${NC}"
            rm -rf "$tmpdir"
            return 1
        fi
        rm -rf "$tmpdir"
    else
        local output
        output=$(mtp-files 2>&1) || {
            echo -e "${RED}Failed to connect. Is the Kindle connected?${NC}"
            return 1
        }
        local clip_id
        clip_id=$(echo "$output" | parse_mtp_files | grep -i '[Cc]lippings\.txt' | head -1 | cut -d'|' -f1)
        if [ -z "$clip_id" ]; then
            echo -e "${RED}Could not find My Clippings.txt on the device.${NC}"
            return 1
        fi
        mtp-getfile "$clip_id" "$dest" &>/dev/null || {
            echo -e "${RED}Failed to pull My Clippings.txt.${NC}"
            return 1
        }
    fi

    if [ -f "$dest" ]; then
        echo -e "${GREEN}Saved to: ${dest}${NC}"
        db_init
        local now
        now=$(date '+%Y-%m-%d %H:%M:%S')
        import_clippings "$dest" "$now"
        local cnt
        cnt=$(db_query "SELECT COUNT(*) FROM clippings;")
        echo -e "${GREEN}Imported ${cnt} clippings into ${KINDLE_DB}${NC}"
    fi
}

# --- books (bulk download) ---
cmd_books() {
    local dest_dir="${1:-.}"
    mkdir -p "$dest_dir"

    if [ -x "$MTP_BATCH" ]; then
        echo -e "${CYAN}Downloading all books from Kindle (single session)...${NC}"
        "$MTP_BATCH" books "$dest_dir"
    else
        local book_lines=""
        if [ -f "$KINDLE_DB" ]; then
            book_lines=$(db_query "SELECT file_id, filename FROM books;" || true)
        fi
        if [ -z "$book_lines" ]; then
            echo -e "${CYAN}No scan data — scanning for book files on Kindle...${NC}"
            local output
            output=$(mtp-files 2>&1) || {
                echo -e "${RED}Failed to connect. Is the Kindle connected?${NC}"
                return 1
            }
            book_lines=$(echo "$output" | parse_mtp_files | grep -iE '\.(kfx|mobi|pdf|epub)' || true)
        fi
        if [ -z "$book_lines" ]; then
            echo -e "${YELLOW}No book files found.${NC}"
            return 0
        fi
        local count=0
        while IFS='|' read -r id name _rest; do
            if [ -n "$id" ] && [ -n "$name" ]; then
                echo -e "  Pulling: ${name} (ID: ${id})"
                mtp-getfile "$id" "${dest_dir}/${name}" 2>&1 || echo -e "  ${RED}Failed: ${name}${NC}"
                count=$((count + 1))
            fi
        done <<< "$book_lines"
        echo -e "${GREEN}Downloaded ${count} book(s) to ${dest_dir}/${NC}"
    fi
}

# --- tree ---
cmd_tree() {
    echo -e "${CYAN}File tree on Kindle:${NC}"
    echo ""
    if [ -x "$MTP_BATCH" ]; then
        # List all files from single session
        local listing
        listing=$("$MTP_BATCH" scan /dev/null 2>/dev/null) || {
            echo -e "${RED}Failed to connect. Is the Kindle connected?${NC}"
            return 1
        }
        echo "$listing" | while IFS='|' read -r id name size; do
            printf "  [%s]  %-50s  %s\n" "$id" "$name" "$(human_size "$size")"
        done
    else
        mtp-filetree 2>&1 || {
            echo -e "${RED}Failed to read file tree. Is the Kindle connected?${NC}"
            return 1
        }
    fi
    echo ""
}

# --- rm ---
cmd_rm() {
    local file_id="${1:-}"

    if [ -z "$file_id" ]; then
        echo -e "${RED}Usage:${NC} kindle rm <file_id>"
        return 1
    fi

    echo -e "${YELLOW}Deleting file ID ${file_id} from Kindle...${NC}"
    if [ -x "$MTP_BATCH" ]; then
        if "$MTP_BATCH" rm "$file_id" 2>/dev/null; then
            echo -e "${GREEN}Deleted file ID ${file_id}.${NC}"
            if [ -f "$KINDLE_DB" ]; then
                db_query "DELETE FROM books WHERE file_id = $file_id;" 2>/dev/null || true
            fi
        else
            echo -e "${RED}Failed to delete file ID ${file_id}.${NC}"
            return 1
        fi
    else
        if mtp-delfile -n "$file_id" 2>&1; then
            echo -e "${GREEN}Deleted file ID ${file_id}.${NC}"
            if [ -f "$KINDLE_DB" ]; then
                db_query "DELETE FROM books WHERE file_id = $file_id;" 2>/dev/null || true
            fi
        else
            echo -e "${RED}Failed to delete file ID ${file_id}.${NC}"
            return 1
        fi
    fi
}
