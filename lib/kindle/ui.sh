human_size() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ]; then
        printf "%.1f GB" "$(echo "$bytes / 1073741824" | bc -l)"
    elif [ "$bytes" -ge 1048576 ]; then
        printf "%.1f MB" "$(echo "$bytes / 1048576" | bc -l)"
    elif [ "$bytes" -ge 1024 ]; then
        printf "%.1f KB" "$(echo "$bytes / 1024" | bc -l)"
    else
        printf "%d B" "$bytes"
    fi
}

bar() {
    local val=$1 max=$2 width=${3:-20}
    if [ "$max" -eq 0 ]; then
        printf "%${width}s" ""
        return
    fi
    local filled=$(( val * width / max ))
    local empty=$(( width - filled ))
    printf "${GREEN}"
    for ((i=0; i<filled; i++)); do printf "█"; done
    printf "${NC}"
    for ((i=0; i<empty; i++)); do printf "░"; done
}

box_line() {
    local width=$1
    printf "├"
    for ((i=0; i<width; i++)); do printf "─"; done
    printf "┤\n"
}

box_top() {
    local width=$1
    printf "┌"
    for ((i=0; i<width; i++)); do printf "─"; done
    printf "┐\n"
}

box_bottom() {
    local width=$1
    printf "└"
    for ((i=0; i<width; i++)); do printf "─"; done
    printf "┘\n"
}

box_text() {
    local width=$1
    shift
    local text="$*"
    local plain
    plain=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g')
    local pad=$(( width - ${#plain} ))
    if [ "$pad" -lt 0 ]; then pad=0; fi
    printf "│ %b%*s│\n" "$text" "$pad" ""
}

box_empty() {
    local width=$1
    printf "│%*s│\n" "$((width))" ""
}
