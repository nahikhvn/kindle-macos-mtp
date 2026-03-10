check_deps() {
    local need_mtp_tools=true

    # Auto-compile mtp-batch helper if possible
    local src="${KINDLE_LIB}/mtp_batch.c"
    if [ -f "$src" ]; then
        if [ ! -x "$MTP_BATCH" ] || [ "$src" -nt "$MTP_BATCH" ]; then
            local mtp_prefix
            mtp_prefix=$(brew --prefix libmtp 2>/dev/null || true)
            if [ -n "$mtp_prefix" ] && [ -f "${mtp_prefix}/include/libmtp.h" ]; then
                mkdir -p "$(dirname "$MTP_BATCH")"
                if cc -o "$MTP_BATCH" "$src" \
                    -I"${mtp_prefix}/include" \
                    -L"${mtp_prefix}/lib" \
                    -lmtp 2>/dev/null; then
                    need_mtp_tools=false
                fi
            fi
        else
            need_mtp_tools=false
        fi
    fi

    if $need_mtp_tools; then
        for cmd in mtp-detect mtp-files mtp-getfile mtp-sendfile mtp-delfile mtp-filetree; do
            if ! command -v "$cmd" &>/dev/null; then
                echo -e "${RED}Error:${NC} $cmd not found."
                echo "Install libmtp: brew install libmtp"
                exit 1
            fi
        done
    fi

    if ! command -v sqlite3 &>/dev/null; then
        echo -e "${RED}Error:${NC} sqlite3 not found (should ship with macOS)."
        exit 1
    fi
}
