#!/bin/sh
# aichat.hf.browse.library.sh
# Shared helpers for the Hugging Face browser's LIST handlers (init / search / sort). The
# three used to duplicate the same curl + parse + table-populate loop; they now all call
# hf_fetch_rows here, which honours the Source picker (Any | MLX | GGUF): a single-format
# query for MLX/GGUF, or a deduped union of both for "Any".
[ -n "${__AICHAT_HF_BROWSE_LIB:-}" ] && return 0
__AICHAT_HF_BROWSE_LIB=1
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

hf_python3="$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3"
hf_query_py="$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/hf_models_query.py"
hf_list_limit=50

# hf_source -> any | mlx | gguf
# The Source segmented control (view 205). Empty (e.g. on first dialog open, before the view
# reports a value) defaults to "any".
hf_source() {
    case "${OMC_ACTIONUI_VIEW_205_VALUE:-}" in
        gguf) echo "gguf" ;;
        mlx)  echo "mlx" ;;
        *)    echo "any" ;;
    esac
}

# hf_source_noun -> "GGUF " | "MLX " | "" (trailing space so it slots into "... ${noun}models")
hf_source_noun() {
    case "$(hf_source)" in
        gguf) echo "GGUF " ;;
        mlx)  echo "MLX " ;;
        *)    echo "" ;;
    esac
}

# hf_sort_param <tag> -> the HF API sort field for the sort picker's tag
hf_sort_param() {
    case "$1" in
        trending) echo "trendingScore" ;;
        recent)   echo "lastModified" ;;
        *)        echo "downloads" ;;
    esac
}

# hf_sort_suffix <tag> -> human wording for the status line
hf_sort_suffix() {
    case "$1" in
        trending) echo "trending" ;;
        recent)   echo "recently updated" ;;
        *)        echo "most downloaded" ;;
    esac
}

# Detail-pane epoch: every list reload (sort/search/source) and every model selection bumps
# this per-window counter. model.selection.changed does a blocking ?blobs=true fetch that can
# take seconds; it captures the epoch before the fetch and only applies its results if the epoch
# is still its own afterwards, so a stale response for a selection the user has since replaced
# (or a list they have since reloaded) is dropped instead of repopulating the detail pane.
hf_detail_epoch_bump() {
    local k="hf_detail_epoch_${OMC_ACTIONUI_WINDOW_UUID}"
    local n="$(pb_get "$k")"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    n=$((n + 1))
    pb_set "$k" "$n"
    echo "$n"
}
hf_detail_epoch_get() { pb_get "hf_detail_epoch_${OMC_ACTIONUI_WINDOW_UUID}"; }

# hf_curl <url> <out_json> -> 0 on HTTP 200 with a non-empty body
hf_curl() {
    local code="$(/usr/bin/curl -fsSL "$1" -o "$2" -w '%{http_code}' 2>/dev/null)"
    [ "$code" = "200" ] && [ -s "$2" ]
}

# hf_fetch_rows <sort_param> <direction> <search_query>
# Echoes table rows as TSV (name<TAB>downloads<TAB>repo_id), one per line, honouring the
# Source picker. Returns 0 on success (even with zero rows), non-zero only when every HTTP
# fetch failed (so the caller can distinguish "no results" from "network/API error").
hf_fetch_rows() {
    local sort_param="$1"
    local direction="$2"
    local query="$3"
    local source="$(hf_source)"
    local common="sort=${sort_param}&direction=${direction}&limit=${hf_list_limit}"
    if [ -n "$query" ]; then
        local encoded="$(printf '%s' "$query" | /usr/bin/sed 's/ /+/g')"
        common="search=${encoded}&${common}"
    fi
    # downloads is returned on every row, so it can be globally sorted; trending/recent are not
    # (their sort key is absent from the row), so the union preserves each list's API order.
    local order="rank"
    [ "$sort_param" = "downloads" ] && order="downloads"

    local base="https://huggingface.co/api/models"
    local tmp_g="/tmp/aichatv2_hf_g_$$.json"
    local tmp_m="/tmp/aichatv2_hf_m_$$.json"
    local files=""
    case "$source" in
        gguf) hf_curl "${base}?filter=gguf&${common}" "$tmp_g" && files="$tmp_g" ;;
        mlx)  hf_curl "${base}?filter=mlx&${common}"  "$tmp_m" && files="$tmp_m" ;;
        *)
            hf_curl "${base}?filter=gguf&${common}" "$tmp_g" && files="$tmp_g"
            hf_curl "${base}?filter=mlx&${common}"  "$tmp_m" && files="${files:+$files }$tmp_m"
            ;;
    esac

    if [ -z "$files" ]; then
        rm -f "$tmp_g" "$tmp_m"
        return 1
    fi
    "$hf_python3" "$hf_query_py" "$order" "$hf_list_limit" $files
    rm -f "$tmp_g" "$tmp_m"
    return 0
}
