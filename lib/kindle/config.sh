# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Paths
KINDLE_DATA_DIR="${HOME}/.kindle"
KINDLE_DB="${KINDLE_DATA_DIR}/kindle.db"
KINDLE_CACHE_DIR="${KINDLE_DATA_DIR}/cache"

# Kindle database files to pull during scan
KINDLE_TARGET_DBS=(
    "fmcache.db"
    "fmcache.db-wal"
    "fmcache.db-shm"
    "ksdk_annotation_v1.db"
    "Index.db"
    "vocab.db"
)

# Compiled MTP helper (auto-built on first scan)
MTP_BATCH="${KINDLE_DATA_DIR}/mtp-batch"

# Book extensions to track
KINDLE_BOOK_EXTS="('.kfx','.mobi','.pdf','.epub')"

# Reader screen size: "6" or "7" (override with KINDLE_SCREEN env var)
KINDLE_SCREEN="${KINDLE_SCREEN:-6}"

# Estimated Kindle locations per screen page (at default font size)
# 6" (Paperwhite/basic): ~1280 chars/page ÷ 128 chars/loc ≈ 10
# 7" (Oasis):            ~1664 chars/page ÷ 128 chars/loc ≈ 13
# Override with LOCS_PER_PAGE env var to tune for your font size
case "$KINDLE_SCREEN" in
    7)  LOCS_PER_PAGE=${LOCS_PER_PAGE:-13} ;;
    *)  LOCS_PER_PAGE=${LOCS_PER_PAGE:-10} ;;
esac

# Sync: Hardcover (https://hardcover.app/account/api)
HARDCOVER_TOKEN="${HARDCOVER_TOKEN:-}"
HARDCOVER_API="https://api.hardcover.app/v1/graphql"

# Sync: Goodreads (session-based auth via Playwright)
GOODREADS_SESSION="${KINDLE_DATA_DIR}/goodreads-session.json"
