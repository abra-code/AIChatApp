#!/bin/bash
# aichat.hf.browse.download.sh
# Downloads the selected model into the shared Hugging Face cache
# (~/.cache/huggingface/hub/models--<author>--<name>/snapshots/main/). Download-ONLY: the
# browser stays open and nothing is loaded - loading is an explicit decision made in the
# model picker, which owns the RAM warning and the agentic/regular path choice (auto-loading
# from here used to force the non-agentic regular chat path).
# Two shapes, chosen by the format stashed by model.selection.changed:
#   GGUF - one quant FILE (table 213 selection); AICHAT_MODEL_PATH = that .gguf file.
#   MLX  - the whole repo tree (config + *.safetensors shards + tokenizer); AICHAT_MODEL_PATH =
#          the snapshot DIRECTORY. Resumes (skips full-size files), cancellable across the whole
#          operation, with disk + RAM preflight and a shard-completeness check.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"

echo "[$(/usr/bin/basename "$0")]"

INFO_TEXT_ID=211
PROGRESS_ID=230
PROGRESS_LABEL_ID=231
DOWNLOAD_BTN_ID=222
# There is no Cancel BUTTON in this window - closing it is the red X, which the engine routes
# to aichat.hf.browse.cancel as END_CANCEL_SUBCOMMAND_ID, and that is where a download in
# progress is queried. This file used to enable and disable an id 221 that the dialog JSON has
# not declared for as long as anyone can tell: three writes into a view that does not exist,
# which omc_dialog_control accepts in silence. Tests/99-hf-download.test.sh is what noticed.
dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

PB_LAST_QUERY="hf_last_query_${window_uuid}"
PB_DL_PID="hf_download_pid_${window_uuid}"
PB_DL_DEST="hf_download_dest_${window_uuid}"
PB_DL_FILE="hf_download_file_${window_uuid}"
PB_DL_STOP="hf_download_stop_${window_uuid}"
# The single file currently being written (the only thing a Stop deletes). PB_DL_DEST is just
# the operation marker (a file for GGUF, a directory for MLX) so cancel can prompt across the
# whole operation; it is NOT deleted wholesale, because both formats share the repo's HF-cache
# snapshot dir - an MLX Stop must never rm -rf a GGUF file (possibly loaded) sitting alongside.
PB_DL_PARTIAL="hf_download_partial_${window_uuid}"
PB_FORMAT="hf_model_format_${window_uuid}"

# Free space this refuses to eat into, over and above the download itself. macOS needs room for
# swap and system caches, and a Mac driven to zero by a model pull is a Mac that stops working
# rather than a Mac that is merely full.
#
# Named through a variable for the same reason curl is: a test cannot free 15 GB, so with the
# number hardcoded every download test would pass or fail on how full the developer's disk
# happened to be that day - and on a machine below the bar, silently assert nothing at all.
DISK_HEADROOM_GB="${CADABRA_DISK_HEADROOM_GB:-15}"

repo_id="$OMC_ACTIONUI_TABLE_202_COLUMN_3_VALUE"
fmt="$(pb_get "$PB_FORMAT")"
echo "Repo: $repo_id  Format: $fmt"

if [ -z "$repo_id" ]; then
    echo "Missing repo, aborting"
    exit 0
fi

author="${repo_id%%/*}"
name="${repo_id##*/}"
# The canonical HF cache location, shared with other tools. snapshots/main holds the files
# directly (real files, not blob symlinks) - enough for the loader and the local picker, which
# both take a path; model_display_label renders models--<author>--<name>/snapshots/* as
# "<author>/<name>".
hf_cache="$HOME/.cache/huggingface/hub/models--${author}--${name}/snapshots/main"

# ── Shared helpers ────────────────────────────────────────────────────────────

reset_ui() {
    "$dialog_tool" "$window_uuid" $PROGRESS_ID omc_hide
    "$dialog_tool" "$window_uuid" $PROGRESS_LABEL_ID omc_hide
    "$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_enable
}

cleanup_dl_state() {
    pb_set "$PB_DL_PID" ""
    pb_set "$PB_DL_DEST" ""
    pb_set "$PB_DL_FILE" ""
    pb_set "$PB_DL_STOP" ""
    pb_set "$PB_DL_PARTIAL" ""
    rm -f "$manifest" 2>/dev/null
}

stop_requested() { [ "$(pb_get "$PB_DL_STOP")" = "1" ]; }

# stop_exit <log-msg> - user-Stop epilogue. The browser stays open for further downloads
# now, so a Stop must restore the idle UI instead of leaving a stale progress bar and a
# disabled Download button behind.
stop_exit() {
    echo "$1"
    reset_ui
    "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Download stopped."
    exit 0
}

# download_finished <label> - download-only epilogue: browser stays open, user loads the
# model explicitly from the model picker (Select Model), where the RAM warning and the
# agentic/regular decision live.
#
# Two wordings, because the next step genuinely differs. In the ordinary case the picker is a
# menu away and the user goes there when they feel like it. In the browser LAUNCH opened - the
# Mac had no model at all - closing this window IS what opens the picker (see the cancel
# handler), so telling that user to go find a menu would describe a detour around the path they
# are already on.
download_finished() {
    reset_ui
    hf_first_run_armed_for "$window_uuid"
    if [ $? -eq 0 ]; then
        "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Downloaded \"$1\".

Close this window to pick it from the Local Models list and start chatting."
    else
        "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Downloaded. Load \"$1\" from the model picker (Select Model) when you want to chat with it."
    fi
}

# ══ Staged transfers ══════════════════════════════════════════════════════════
# NOTHING IS EVER WRITTEN AT THE NAME A READER LOOKS FOR. Every transfer lands in
# "<final>.part" and is renamed into place only once it is whole, because the alternative is
# what this replaces: curl writing straight to Foo-Q4_K_M.gguf, and any death the script cannot
# clean up after - a force quit, a panic, a power cut - leaving a truncated file at exactly the
# name the model picker scans for. The picker listed it, sized it, and handed a corrupt model to
# a loader that could only fail, with nothing anywhere saying why.
#
# The staging name is invisible to every reader by construction: ".part" does not match the
# picker's *.gguf scan, and it is neither config.json nor *.safetensors for the MLX one.
#
# The rename is the commit, and it is guarded by SIZE. curl exiting 0 is not proof the file is
# whole - a proxy can close a stream cleanly mid-body - so a transfer whose result does not
# match the length the server declared is rejected rather than published.
#
# ── WHAT A LEFTOVER IS ALLOWED TO BE RESUMED AGAINST ──────────────────────────
# A staging file outlives the attempt that made it, which is the point, and it is also the risk:
# the thing on the other end of the URL can change in between. Resuming then splices the head of
# one revision onto the tail of another, and because the second half IS the length the server
# now declares, the result passes the size check and gets published as a model. Right length,
# wrong contents - the one failure worse than starting over, and the exact class this whole
# change exists to stop.
#
# So a partial is only resumed against the revision it came from. Every staging file carries a
# sidecar, "<final>.part.id", holding whatever identity the caller could learn about the file it
# was fetching: the ETag for a GGUF (out of the size probe that already happens) and the git
# object id from the tree listing for an MLX shard. A leftover whose sidecar does not match what
# the server says today is not a partial of this file, and is dropped rather than continued.
#
# FAILS CLOSED. No identity, no sidecar, or an unreadable one all mean "start over": a resume
# that cannot prove what it is continuing is a resume nobody can check.

# part_id_path <part-path> - the sidecar that says which revision a staging file belongs to.
part_id_path() { printf '%s.id' "$1"; }

# part_drop <part-path> - remove a staging file and its sidecar together. They are one fact in
# two files, and a sidecar outliving its part would authorize the next transfer's leftover.
part_drop() {
    /bin/rm -f "$1"
    /bin/rm -f "$(part_id_path "$1")"
}

# prepare_part <part-path> <expected-bytes|""> <identity|""> -> complete | resume | fresh
#
# Decides what a leftover staging file is worth. "complete" is a transfer that finished and died
# before its rename - there is nothing left to fetch. "resume" is a real partial of the same
# revision. Anything else is dropped: a different revision, a size that is not smaller than the
# whole file, or no expected size to judge either against.
prepare_part() {
    if [ ! -f "$1" ]; then
        echo fresh
        return 0
    fi
    case "$2" in
        ''|*[!0-9]*|0)
            part_drop "$1"
            echo fresh
            return 0 ;;
    esac

    # Identity before size, and before the "complete" shortcut especially: a staging file that is
    # exactly the right length but belongs to a superseded revision is the most convincing wrong
    # answer this function can give.
    local want_id
    want_id="$3"
    local have_id
    have_id=$(/bin/cat "$(part_id_path "$1")" 2>/dev/null)
    if [ -z "$want_id" ] || [ "$have_id" != "$want_id" ]; then
        # To stderr, not stdout: this function's stdout IS its return value.
        echo "staging file for $1 is not this revision - starting over" >&2
        part_drop "$1"
        echo fresh
        return 0
    fi

    local have
    have=$(/usr/bin/stat -f%z -L "$1" 2>/dev/null || echo 0)
    if [ "$have" -eq "$2" ] 2>/dev/null; then
        echo complete
        return 0
    fi
    if [ "$have" -gt 0 ] 2>/dev/null && [ "$have" -lt "$2" ] 2>/dev/null; then
        echo resume
        return 0
    fi
    part_drop "$1"
    echo fresh
}

# commit_part <part-path> <final-path> <expected-bytes|""> - publish a finished transfer.
# 0 published; 1 the staging file is not the size the server declared; 2 the rename failed.
#
# Two failures rather than one because they call for opposite things. A wrong SIZE is not a
# partial transfer, it is a wrong one - resuming from it would append the tail of the file onto
# the wrong prefix - so those bytes are dropped. A failed rename leaves a whole, correct file
# staged, and the next attempt commits it without fetching anything.
commit_part() {
    case "$3" in
        ''|*[!0-9]*|0) ;;
        *)
            local have
            have=$(/usr/bin/stat -f%z -L "$1" 2>/dev/null || echo 0)
            if [ "$have" != "$3" ]; then
                echo "size mismatch on $1: got $have, expected $3"
                part_drop "$1"
                return 1
            fi ;;
    esac
    /bin/mv -f "$1" "$2"
    if [ $? -ne 0 ]; then
        echo "could not move $1 into place at $2"
        return 2
    fi
    /bin/rm -f "$(part_id_path "$1")"
    return 0
}

# transfer_file <url> <part> <resume 0|1> <base-done> <grand-total|""> - one curl, with the
# progress bar showing (base-done + bytes so far) against grand-total. Returns curl's status.
#
# One implementation for both formats: GGUF passes base-done 0 and the file's own size as the
# grand total, MLX passes the bytes of the files already done and the size of the whole tree.
transfer_file() {
    /bin/mkdir -p "$(/usr/bin/dirname "$2")"
    pb_set "$PB_DL_PARTIAL" "$2"

    if [ "$3" = "1" ]; then
        "$hf_curl" -fsSL -C - -o "$2" "$1" &
    else
        "$hf_curl" -fsSL -o "$2" "$1" &
    fi
    local pid=$!
    pb_set "$PB_DL_PID" "$pid"

    local cur done_bytes pct
    while kill -0 "$pid" 2>/dev/null; do
        case "$5" in
            ''|*[!0-9]*|0) ;;
            *)  cur=$(/usr/bin/stat -f%z -L "$2" 2>/dev/null || echo 0)
                done_bytes=$((${4:-0} + cur))
                pct=$((done_bytes * 100 / $5))
                [ "$pct" -gt 100 ] && pct=100
                "$dialog_tool" "$window_uuid" $PROGRESS_ID "$pct"
                "$dialog_tool" "$window_uuid" $PROGRESS_LABEL_ID "$(format_bytes "$done_bytes") / $(format_bytes "$5") (${pct}%)"
                ;;
        esac
        sleep 0.5
    done
    local rc
    wait "$pid"
    rc=$?
    pb_set "$PB_DL_PID" ""
    return $rc
}

# fetch_verified <url> <final> <expected-bytes|""> <identity|""> <base-done> <grand-total|"">
#
# The whole staged transfer: resume what is there and is provably the same revision, fetch what
# is not, verify, rename. 0 when <final> is on disk and whole. On failure it sets $fetch_detail
# to a phrase for the info pane and returns non-zero, LEAVING the staging file in place so the
# next attempt resumes rather than restarts.
fetch_verified() {
    fetch_detail=""
    local part="${2}.part"

    local stage
    stage=$(prepare_part "$part" "$3" "$4")
    if [ "$stage" != "complete" ]; then
        local resume=0
        [ "$stage" = "resume" ] && resume=1

        # Written before the first byte, so a transfer interrupted at any point leaves a staging
        # file that says what it is. Written on a resume too, which is a no-op by construction -
        # prepare_part only returns "resume" when the sidecar already says exactly this.
        printf '%s' "$4" > "$(part_id_path "$part")"

        local rc
        transfer_file "$1" "$part" "$resume" "$5" "$6"
        rc=$?

        # A resume the other end will not honor fails where a fresh transfer would have worked,
        # and the leftover the user cannot see would make every later attempt fail the same way.
        # So that case is spent once, dropped, and retried from the top.
        #
        # ONLY THAT CASE. This used to fire on any nonzero status from a resumed transfer, which
        # quietly made resume useless on the connections that need it most: a link that drops
        # after two hours returns 56, and deleting the partial on that reading means the next
        # attempt starts at zero and drops again at the same place. Progress could never exceed
        # what one unbroken connection managed. 33 is "server does not support byte ranges" and
        # 36 is "cannot continue this download"; every other status leaves the bytes alone.
        case "$rc" in
            33|36)
                if stop_requested; then return "$rc"; fi
                echo "resume refused (curl exit $rc) - retrying from the start"
                part_drop "$part"
                printf '%s' "$4" > "$(part_id_path "$part")"
                transfer_file "$1" "$part" 0 "$5" "$6"
                rc=$?
                ;;
        esac

        if [ "$rc" != 0 ]; then
            fetch_detail="transfer error ${rc}"
            return "$rc"
        fi
    fi

    local commit_rc
    commit_part "$part" "$2" "$3"
    commit_rc=$?
    if [ "$commit_rc" = "1" ]; then
        fetch_detail="the download did not match the size the server declared"
        return "$commit_rc"
    fi
    if [ "$commit_rc" != 0 ]; then
        fetch_detail="the download could not be moved into place"
        return "$commit_rc"
    fi
    pb_set "$PB_DL_PARTIAL" ""
    return 0
}

# ══ GGUF: single quant file ═══════════════════════════════════════════════════
download_gguf() {
    local filename="$OMC_ACTIONUI_TABLE_213_COLUMN_3_VALUE"
    echo "GGUF file: $filename"
    if [ -z "$filename" ]; then
        echo "Missing filename, aborting"
        exit 0
    fi

    local dest_path="${hf_cache}/${filename}"
    # URL-encode the filename (spaces/#/?/% ) so an unusual quant name does not break the URL.
    local filename_enc="$(printf '%s' "$filename" | /usr/bin/sed 's/%/%25/g; s/ /%20/g; s/#/%23/g; s/?/%3F/g')"
    local download_url="https://huggingface.co/${repo_id}/resolve/main/${filename_enc}"
    echo "Destination: $dest_path"

    # Commit to a download: make the window cancellable for the whole operation.
    trap cleanup_dl_state EXIT
    pb_set "$PB_DL_DEST" "$dest_path"
    pb_set "$PB_DL_FILE" "$filename"
    pb_set "$PB_DL_STOP" ""
    pb_set "$PB_DL_PID" ""

    # Probe size AND identity, in one request. The ETag is what lets a leftover staging file be
    # resumed against the revision it actually came from - see prepare_part.
    "$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_disable
    "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Checking download size…"
    local headers
    headers="$("$hf_curl" -fsSIL "$download_url" 2>/dev/null | /usr/bin/tr -d '\r')"
    local total_bytes
    total_bytes="$(printf '%s\n' "$headers" \
        | /usr/bin/awk '/^[Cc]ontent-[Ll]ength:/{len=$2} END{print len}')"
    local file_id
    file_id="$(printf '%s\n' "$headers" \
        | /usr/bin/awk '/^[Ee][Tt]ag:/{tag=$2} END{print tag}' | /usr/bin/tr -d '"')"
    echo "Total bytes: '${total_bytes}'  etag: '${file_id}'"
    if stop_requested; then stop_exit "cancelled during size probe"; fi

    # Already cached? Asked AFTER the probe, and by SIZE rather than by "a file with that name
    # exists", which is what let a truncated download from an older build sit here forever: this
    # path called it cached and never offered to repair it, so the picker went on listing a
    # corrupt model that clicking Download could not fix. A local file that is not the length
    # the server declares is not the file the user just asked for.
    #
    # With no declared length there is nothing to compare, so an existing file is taken at face
    # value - the old behavior, kept for the case where it is the only behavior available.
    if [ -f "$dest_path" ]; then
        local have
        have=$(/usr/bin/stat -f%z -L "$dest_path" 2>/dev/null || echo 0)
        if [ -z "$total_bytes" ] || [ "$have" = "$total_bytes" ]; then
            echo "File already cached: $dest_path"
            "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Already downloaded. Load \"${filename%.gguf}\" from the model picker (Select Model)."
            exit 0
        fi
        echo "cached file is $have bytes, server says $total_bytes - fetching it again"
    fi

    # Disk preflight (see DISK_HEADROOM_GB).
    local safety_headroom=$((DISK_HEADROOM_GB * 1024 * 1024 * 1024))
    if [ -n "$total_bytes" ] && [ "$total_bytes" -gt 0 ] 2>/dev/null; then
        local avail_kb="$(df -Pk "$HOME" | /usr/bin/awk 'NR==2{print $4}')"
        local avail_bytes=$((avail_kb * 1024))
        local needed=$((total_bytes + safety_headroom))
        if [ "$avail_bytes" -lt "$needed" ] 2>/dev/null; then
            reset_ui
            "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Select a model from the list."
            "$alert" --level caution --title "Not Enough Disk Space" \
                "Not enough disk space to safely download this model.

Model size:       $(format_bytes "$total_bytes")
System headroom:  $(format_bytes "$safety_headroom")
Available space:  $(format_bytes "$avail_bytes")

macOS needs free space for swap files and system caches. Free up space and try again."
            exit 0
        fi
    fi

    # (No RAM preflight here: this is a pure download now, and the load-time RAM warning
    # lives in the model picker's OK handler.)

    # Download.
    "$dialog_tool" "$window_uuid" $PROGRESS_ID omc_show
    "$dialog_tool" "$window_uuid" $PROGRESS_LABEL_ID omc_show
    "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Downloading ${filename} from Hugging Face…"
    /bin/mkdir -p "$hf_cache"

    # The running label is transfer_file's to write; this is only the state it starts in. An
    # unknown size is normalized to empty here, which is what tells prepare_part it has nothing
    # to judge a leftover against and transfer_file that there is no percentage to show.
    if [ -n "$total_bytes" ] && [ "$total_bytes" -gt 0 ] 2>/dev/null; then
        "$dialog_tool" "$window_uuid" $PROGRESS_ID omc_set_property "total" "100"
        "$dialog_tool" "$window_uuid" $PROGRESS_LABEL_ID "0 B / $(format_bytes "$total_bytes") (0%)"
    else
        total_bytes=""
        "$dialog_tool" "$window_uuid" $PROGRESS_LABEL_ID "Downloading…"
    fi

    local fetch_rc
    fetch_verified "$download_url" "$dest_path" "$total_bytes" "$file_id" 0 "$total_bytes"
    fetch_rc=$?

    if stop_requested; then stop_exit "stopped during download"; fi

    if [ "$fetch_rc" != 0 ]; then
        echo "download failed: $fetch_detail"
        reset_ui
        # The partial is KEPT, under its staging name where nothing will offer it as a model,
        # so selecting Download again picks up where this left off. The old code deleted it and
        # sent the user back to zero bytes.
        "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Download failed (${fetch_detail}).

What was downloaded is kept - select Download again to resume. Check your internet connection and try again."
        exit 1
    fi

    echo "Download complete: $dest_path"
    download_finished "${filename%.gguf}"
}

# ══ MLX: whole repo tree ══════════════════════════════════════════════════════
download_mlx() {
    local dest_dir="$hf_cache"
    manifest="${TMPDIR:-/tmp}/aichatv2_hf_manifest_$$.tsv"
    echo "Destination dir: $dest_dir"

    # No "is it already here" shortcut before the file list, and that is the fix for a second
    # way a corrupt model used to become permanent. The check that stood here asked
    # mlx_shards_complete, which tests that every shard NAME exists - so a shard left truncated
    # at its real name by an older build satisfied it, this path reported the model as already
    # downloaded, and the loop below, whose per-file size check would have repaired it, was
    # never reached. The question is asked from the manifest instead, where there are sizes to
    # ask it with (see "nothing missing" below).

    # Commit to a download (cancellable from here, including the tree fetch / preflight window).
    trap cleanup_dl_state EXIT
    pb_set "$PB_DL_DEST" "$dest_dir"
    pb_set "$PB_DL_FILE" "$name"
    pb_set "$PB_DL_STOP" ""
    pb_set "$PB_DL_PID" ""

    # Fetch the repo file tree.
    "$dialog_tool" "$window_uuid" $DOWNLOAD_BTN_ID omc_disable
    "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Reading file list for ${name}…"
    local tree_json="${TMPDIR:-/tmp}/aichatv2_hf_tree_$$.json"
    local http_code="$("$hf_curl" -fsSL \
        "https://huggingface.co/api/models/${repo_id}/tree/main?recursive=true" \
        -o "$tree_json" -w '%{http_code}' 2>/dev/null)"
    if stop_requested; then rm -f "$tree_json"; stop_exit "cancelled during tree fetch"; fi
    if [ "$http_code" != "200" ] || [ ! -s "$tree_json" ]; then
        echo "HF tree API error: HTTP $http_code"
        reset_ui
        "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Could not read the model file list (HTTP ${http_code}). Check your connection and try again."
        rm -f "$tree_json"
        exit 1
    fi

    # Build a manifest of downloadable files as "<size><TAB><relpath>" lines. A temp file (not a
    # shell array) keeps this portable and lets the download loop read it with a subshell-free
    # `while read < file` so the byte counter persists.
    #
    # Three fields per line, not two: the git object id rides along as the file's IDENTITY, which
    # is what lets a staging file left by an earlier attempt be resumed against the revision it
    # came from rather than spliced onto a newer one (see prepare_part). The path stays LAST,
    # because it is the only field that can contain a space.
    : > "$manifest"
    local entries="$("$plister" get count "$tree_json" / 2>/dev/null)"
    local total_bytes=0
    local missing_bytes=0
    local missing_files=0
    local weights_bytes=0
    local file_count=0
    local tab="$(printf '\t')"
    local k=0
    while [ "$k" -lt "$entries" ]; do
        local etype="$("$plister" get value "$tree_json" "/$k/type" 2>/dev/null)"
        local epath="$("$plister" get value "$tree_json" "/$k/path" 2>/dev/null)"
        local esize="$("$plister" get value "$tree_json" "/$k/size" 2>/dev/null)"
        local eoid="$("$plister" get value "$tree_json" "/$k/oid" 2>/dev/null)"
        [ -n "$esize" ] && [ "$esize" -gt 0 ] 2>/dev/null || esize=0
        k=$((k + 1))
        [ "$etype" = "file" ] || continue
        case "${epath##*/}" in ""|.gitattributes) continue ;; esac
        printf '%s%s%s%s%s\n' "$esize" "$tab" "$eoid" "$tab" "$epath" >> "$manifest"
        file_count=$((file_count + 1))
        total_bytes=$((total_bytes + esize))
        case "$epath" in *.safetensors) weights_bytes=$((weights_bytes + esize)) ;; esac

        # What this download would actually have to fetch. A file already on disk at exactly its
        # expected size costs nothing; one that is there at the WRONG size costs all of it,
        # because it is going to be fetched again.
        #
        # ABSENCE IS COUNTED SEPARATELY FROM SIZE, and not as a nicety: a listing entry with no
        # size (or zero) normalizes to 0 above, so comparing sizes alone would score a file that
        # is not there at all as costing nothing - and with every other file present, the "nothing
        # missing" test below would call the model complete while one of its files had never
        # arrived. The HF listing always gives sizes, so this is the guard for the day it does not.
        #
        # It errs toward fetching: a NON-empty file whose entry is sizeless reads as the wrong
        # size and is fetched again on every press, since there is no length that would let it
        # read as right. Safe rather than tidy - a sizeless entry also disables the commit-time
        # size guard, so the one thing worth being sure of is that the bytes came from here.
        if [ ! -f "${dest_dir}/${epath}" ]; then
            missing_bytes=$((missing_bytes + esize))
            missing_files=$((missing_files + 1))
        else
            local ehave
            ehave=$(/usr/bin/stat -f%z -L "${dest_dir}/${epath}" 2>/dev/null || echo 0)
            if [ "$ehave" != "$esize" ]; then
                missing_bytes=$((missing_bytes + esize))
                missing_files=$((missing_files + 1))
            fi
        fi
    done
    rm -f "$tree_json"

    echo "Files: ${file_count}  total=${total_bytes}B  weights=${weights_bytes}B  missing=${missing_files} files / ${missing_bytes}B"
    if [ "$file_count" -eq 0 ]; then
        reset_ui
        "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "This repository has no downloadable files."
        exit 1
    fi

    # Nothing missing: every file is present at the size the listing gives for it. This is the
    # "already downloaded" the name-based check used to make before the listing existed, now
    # made from the sizes that are the only thing able to tell a whole shard from a truncated one.
    if [ "$missing_files" -eq 0 ]; then
        echo "Model already complete: $dest_dir"
        reset_ui
        "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Already downloaded. Load \"$(model_display_label "$dest_dir")\" from the model picker (Select Model)."
        exit 0
    fi

    # Disk preflight (see DISK_HEADROOM_GB), against what is still MISSING rather than the whole
    # tree. Charging a resume for the bytes it already has would refuse a download that needs one
    # more shard on a disk with room for exactly that - and now that "already complete" is
    # decided above, the whole-tree figure could refuse a model with nothing left to fetch at all.
    local safety_headroom=$((DISK_HEADROOM_GB * 1024 * 1024 * 1024))
    if [ "$missing_bytes" -gt 0 ]; then
        local avail_kb="$(df -Pk "$HOME" | /usr/bin/awk 'NR==2{print $4}')"
        local avail_bytes=$((avail_kb * 1024))
        local needed=$((missing_bytes + safety_headroom))
        if [ "$avail_bytes" -lt "$needed" ] 2>/dev/null; then
            reset_ui
            "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Select a model from the list."
            "$alert" --level caution --title "Not Enough Disk Space" \
                "Not enough disk space to safely download this model.

Still to download: $(format_bytes "$missing_bytes")
System headroom:  $(format_bytes "$safety_headroom")
Available space:  $(format_bytes "$avail_bytes")

macOS needs free space for swap files and system caches. Free up space and try again."
            exit 0
        fi
    fi
    if stop_requested; then stop_exit "cancelled during preflight"; fi

    # (No RAM preflight here: pure download; the model picker's OK handler owns the
    # load-time RAM warning.)

    # Download all files sequentially.
    "$dialog_tool" "$window_uuid" $PROGRESS_ID omc_show
    "$dialog_tool" "$window_uuid" $PROGRESS_LABEL_ID omc_show
    "$dialog_tool" "$window_uuid" $PROGRESS_ID omc_set_property "total" "100"
    "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Downloading ${name} from Hugging Face…"
    /bin/mkdir -p "$dest_dir"

    local base_done=0
    local dl_failed=""
    # Read via redirect (NOT a pipe) so base_done persists in this shell.
    local rel eoid
    while IFS="$tab" read -r esize eoid rel; do
        [ -n "$rel" ] || continue
        if stop_requested; then stop_exit "stopped before $rel"; fi
        local out="${dest_dir}/${rel}"
        /bin/mkdir -p "$(/usr/bin/dirname "$out")"

        # Skip a file already present at its full expected size (resume a partial run).
        if [ -f "$out" ] && [ "$esize" -gt 0 ] 2>/dev/null; then
            local have="$(/usr/bin/stat -f%z -L "$out" 2>/dev/null || echo 0)"
            if [ "$have" -eq "$esize" ]; then
                echo "skip (complete): $rel"
                base_done=$((base_done + esize))
                continue
            fi
        fi

        # URL-encode spaces and a few reserved chars in the repo-relative path (keep slashes).
        local rel_enc="$(printf '%s' "$rel" | /usr/bin/sed 's/%/%25/g; s/ /%20/g; s/#/%23/g; s/?/%3F/g')"

        echo "downloading: $rel (${esize}B)"
        local fetch_rc
        fetch_verified "https://huggingface.co/${repo_id}/resolve/main/${rel_enc}" \
            "$out" "$esize" "$eoid" "$base_done" "$total_bytes"
        fetch_rc=$?

        if stop_requested; then stop_exit "stopped during $rel"; fi
        if [ "$fetch_rc" != 0 ]; then
            echo "failed on $rel: $fetch_detail"
            dl_failed="$rel"
            break
        fi
        base_done=$((base_done + esize))
    done < "$manifest"

    if [ -n "$dl_failed" ]; then
        # Nothing to remove: every file that got here is either whole and at its real name, or
        # still under its staging name, where the next attempt will resume it. That is the whole
        # point of the staging - this used to delete the file that failed, because it was sitting
        # at its real name looking like a shard.
        reset_ui
        "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Download failed on ${dl_failed} (${fetch_detail}). What was downloaded is kept - select Download again to resume.

Check your internet connection and try again."
        exit 1
    fi

    if ! mlx_shards_complete "$dest_dir"; then
        echo "Downloaded tree is missing config.json or safetensors shards"
        reset_ui
        "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "The downloaded repository is missing config.json or its safetensors weights and cannot be loaded."
        exit 1
    fi

    echo "Download complete: $dest_dir"
    download_finished "$(model_display_label "$dest_dir")"
}

# ══ Dispatch ══════════════════════════════════════════════════════════════════
manifest=""
case "$fmt" in
    mlx)  download_mlx ;;
    gguf) download_gguf ;;
    *)
        echo "No format recorded for this selection"
        "$dialog_tool" "$window_uuid" $INFO_TEXT_ID "Select a model from the list."
        exit 0
        ;;
esac
