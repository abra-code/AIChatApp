#!/bin/bash
# aichat.select.local.model.delete.sh
# Deletes the selected model, dispatching on engine because the two engines have different
# SHAPES on disk (the same distinction model_engine exists to make): a GGUF model is a single
# FILE, an MLX model is a DIRECTORY of *.safetensors shards.
#
#   GGUF: delete the file, and offer the parent folder when the file is all that is in it.
#   MLX:  delete the model directory - but in the Hugging Face cache, escalate to the REPO
#         directory when it holds a single revision. A snapshot folder holds only SYMLINKS
#         into ../../blobs, so removing it on its own frees nothing while telling the user a
#         30GB model is gone.
#
# Whatever the engine, anything deleted out of a Hugging Face cache repo is followed by a
# blob prune, because in that layout the bytes never live where the picker points. Blobs no
# surviving snapshot references are removed; blobs shared with a revision (or a variant) that
# is staying are not.
#
# Recursive rm is unavoidable here, so every directory handed to one is sanity-checked by
# path_is_safe_to_remove and re-verified immediately before the rm (the same race guard the
# GGUF folder branch has always had). The MLX branch additionally resolves its target with
# cd -P first, since it is the branch that can be pointed at a symlinked model root.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"

echo "[$(/usr/bin/basename "$0")]"

LOAD_BUTTON_ID=3
INFO_TEXT_ID=12
REVEAL_BUTTON_ID=20
DELETE_BUTTON_ID=24
BENCH_TEXT_ID=50
BENCH_BTN_ID=51

# An *.incomplete blob is referenced by nothing until its download finishes, so it is
# indistinguishable from an abandoned partial - except by age. Anything touched this recently
# is treated as a live download and left alone; see orphan_blobs.
# An hour rather than a minute because the two errors are not symmetric: sparing a partial too
# long only defers its reclamation to the next delete, while taking one from a download that
# merely STALLED (rate limit, retry backoff) throws away the transfer and then breaks its
# final rename.
INCOMPLETE_GRACE_SECONDS=3600

window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

# Column 3 (hidden) holds the full model path
selected_path="$OMC_ACTIONUI_TABLE_10_COLUMN_3_VALUE"

# ── Shared helpers ─────────────────────────────────────────────────────────────

# path_is_safe_to_remove <absolute-path>
# Last line of defence in front of rm -rf. A surviving ".." means either the path was never
# resolved or the resolution failed, and in both cases it cannot be trusted.
path_is_safe_to_remove() {
    local p="$1"
    case "$p" in
        /*) ;;
        *) return 1 ;;
    esac
    case "$p" in
        *"/../"*|*/..) return 1 ;;
    esac
    [ "$p" = "/" ] && return 1
    [ "$p" = "$HOME" ] && return 1
    # At least three components (/a/b/c). Rules out /, /Users, /Volumes and any home dir;
    # every real model location sits far deeper.
    local depth=$(printf '%s' "${p#/}" | /usr/bin/awk -F'/' '{print NF}')
    [ "$depth" -ge 3 ] || return 1
    return 0
}

# dir_bytes <dir> -> bytes actually occupied on disk (du, so symlinks count as links and
# shared blobs are counted once). Unlike model_bytes this includes tokenizer/config files,
# which is what the user gets back by deleting.
dir_bytes() {
    local kb=$(/usr/bin/du -sk "$1" 2>/dev/null | /usr/bin/awk '{print $1; exit}')
    case "$kb" in ""|*[!0-9]*) echo 0; return 0 ;; esac
    echo $((kb * 1024))
}

# count_subdirs <dir> -> number of immediate subdirectories.
# Hidden ones are COUNTED: the only caller asks "is this the sole revision", and a dot-named
# directory under snapshots/ still holds symlinks that referenced_inodes will honour. Counting
# it keeps the two in agreement, and the disagreement would resolve the unsafe way - deleting
# the whole repo out from under it.
count_subdirs() {
    /usr/bin/find "$1" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
        | /usr/bin/wc -l | /usr/bin/tr -d ' '
}

# clear_selection_ui - put the picker back into its no-selection state before the table is
# reloaded. Mirrors the empty branch of aichat.select.local.model.selection.changed.sh: the
# model the panes describe no longer exists, so leaving Load/Reveal/Delete lit would offer
# actions against a dead path. If the reloaded table ends up with a selection its own
# handler enables them again.
clear_selection_ui() {
    [ -n "$window_uuid" ] || return 0
    pb_set "aichatv2_selected_model_${window_uuid}" ""
    "$dialog" "$window_uuid" $LOAD_BUTTON_ID omc_disable
    "$dialog" "$window_uuid" $REVEAL_BUTTON_ID omc_disable
    "$dialog" "$window_uuid" $DELETE_BUTTON_ID omc_disable
    "$dialog" "$window_uuid" $BENCH_BTN_ID omc_disable
    "$dialog" "$window_uuid" $BENCH_TEXT_ID "Select a model from the list."
    "$dialog" "$window_uuid" $INFO_TEXT_ID "Select a model from the list."
}

# alert_delete_failed <code>
alert_delete_failed() {
    "$alert" \
        --level caution \
        --title "Delete Failed" \
        "Could not delete the selected item (error ${1}). Check that you have write permission."
}

# ── Hugging Face cache layout ──────────────────────────────────────────────────
# <hub>/models--<org>--<name>/{blobs,refs,snapshots/<revision>[/<variant>...]}
# Both engines can land inside one of these, so the layout helpers are engine-agnostic.

# hf_repo_dir_for <path> -> the models--<org>--<name> directory this path lives in, or "".
# Walks UP looking for a "snapshots" component rather than testing the immediate parent, so it
# answers for a revision root AND for anything nested below one - multi-variant repos really
# do ship snapshots/<rev>/4bit/config.json, and the picker lists those (init scans to depth 5).
hf_repo_dir_for() {
    local dir="$1"
    # Absolute only: dirname "." is "." forever, so a relative path would spin this walk
    # (forking twice per turn) until the app quits.
    case "$dir" in /*) ;; *) return 0 ;; esac
    while [ -n "$dir" ] && [ "$dir" != "/" ]; do
        local parent=$(/usr/bin/dirname "$dir")
        if [ "$(/usr/bin/basename "$dir")" = "snapshots" ]; then
            case "$(/usr/bin/basename "$parent")" in
                models--*) path_is_safe_to_remove "$parent" && printf '%s' "$parent" ;;
            esac
            return 0
        fi
        dir="$parent"
    done
}

# hf_revision_root_for <path> <repo-dir> -> the <repo>/snapshots/<revision> ancestor of path
# (which may be path itself), or "".
hf_revision_root_for() {
    local dir="$1"
    local snaps="$2/snapshots"
    case "$dir" in /*) ;; *) return 0 ;; esac
    while [ -n "$dir" ] && [ "$dir" != "/" ]; do
        [ "$(/usr/bin/dirname "$dir")" = "$snaps" ] && { printf '%s' "$dir"; return 0; }
        dir=$(/usr/bin/dirname "$dir")
    done
}

# referenced_inodes <repo-dir> [path-to-exclude]
# Prints the inode of every blob still reachable through a snapshot, ignoring anything at or
# below <path-to-exclude> (what is about to be deleted). Excluding by path prefix rather than
# by whole snapshot directory is what lets a single-variant delete be measured and pruned.
#
# Snapshot entries are SYMLINKS into blobs/, and matching by INODE rather than by resolved
# path keeps this working without realpath(1) (absent on older macOS) and regardless of how
# the link is spelled. BOTH -L flags are load-bearing and for DIFFERENT reasons: find -L makes
# -type f see through the link, and stat -L makes it report the BLOB's inode instead of the
# symlink's own. Without the stat -L nothing ever matches, every blob looks orphaned, and
# pruning one revision wipes the shards of all the others.
# This is the ONE walk in this file that must be NUL-delimited rather than line-delimited.
# Every other loop here errs on the safe side if a path splits (a bogus path simply fails to
# stat and nothing is deleted), but a surviving snapshot entry that drops out of THIS list is
# a blob that looks orphaned and gets pruned out from under a live revision. Names with
# newlines should be impossible in a Hub-managed cache; "should be impossible" is not a reason
# to let the failure land on the delete side.
referenced_inodes() {
    local snaps="$1/snapshots"
    local exclude="$2"
    [ -d "$snaps" ] || return 0
    # The subshell the pipeline creates is harmless: this function only prints.
    /usr/bin/find -L "$snaps" -type f -print0 2>/dev/null \
    | while IFS= read -r -d '' _file; do
        if [ -n "$exclude" ]; then
            case "$_file" in
                "$exclude"|"$exclude"/*) continue ;;
            esac
        fi
        /usr/bin/stat -L -f '%i' "$_file" 2>/dev/null
    done
}

# orphan_blobs <repo-dir> [path-to-exclude]
# Prints every blob no live snapshot references - i.e. what deleting that path orphans.
# Leftover *.incomplete downloads count as orphans (they belong to this repo and to nothing
# else) EXCEPT while they are still being written: hf_hub_download creates the snapshot
# symlink only once the blob is finished, so an in-flight shard is referenced by nothing and
# pruning it would restart a multi-GB download from zero. Anything older than the grace period
# is a genuinely abandoned partial and is reclaimed.
orphan_blobs() {
    local repo="$1"
    local exclude="$2"
    [ -d "$repo/blobs" ] || return 0
    local keep=$(referenced_inodes "$repo" "$exclude" | /usr/bin/sort -u)
    local now=$(/bin/date +%s)
    local _blob _inode _mtime
    while IFS= read -r _blob; do
        [ -n "$_blob" ] || continue
        # find always emits absolute paths here, so a RELATIVE line can only be the tail
        # fragment of a name containing a newline. A bare fragment resolves against the
        # handler's cwd, where it could name an unrelated real file - which would stat fine,
        # match no keep-set inode, and be deleted as an "orphan". Refusing it is what makes
        # this loop keep-side safe and lets the rest of the file stay line-delimited.
        case "$_blob" in /*) ;; *) continue ;; esac
        case "$_blob" in
            *.incomplete)
                _mtime=$(/usr/bin/stat -L -f '%m' "$_blob" 2>/dev/null)
                case "$_mtime" in ""|*[!0-9]*) _mtime=0 ;; esac
                [ $((now - _mtime)) -lt "$INCOMPLETE_GRACE_SECONDS" ] && continue
                ;;
        esac
        _inode=$(/usr/bin/stat -L -f '%i' "$_blob" 2>/dev/null)
        [ -n "$_inode" ] || continue
        printf '%s\n' "$keep" | /usr/bin/grep -qxF "$_inode" && continue
        printf '%s\n' "$_blob"
    done <<EOF
$(/usr/bin/find "$repo/blobs" -mindepth 1 -maxdepth 1 -type f 2>/dev/null)
EOF
}

# orphan_blob_bytes <repo-dir> [path-to-exclude] -> bytes the prune would reclaim.
orphan_blob_bytes() {
    local total=0
    local _blob _size
    while IFS= read -r _blob; do
        [ -n "$_blob" ] || continue
        _size=$(/usr/bin/stat -L -f%z "$_blob" 2>/dev/null || echo 0)
        total=$((total + _size))
    done <<EOF
$(orphan_blobs "$1" "$2")
EOF
    echo "$total"
}

# prune_orphan_blobs <repo-dir> - drop blobs left unreferenced by whatever was just removed.
prune_orphan_blobs() {
    local _blob
    while IFS= read -r _blob; do
        [ -n "$_blob" ] || continue
        echo "Pruning orphaned blob: $_blob"
        /bin/rm -f "$_blob"
    done <<EOF
$(orphan_blobs "$1")
EOF
}

# prune_refs_to <repo-dir> <revision> - drop refs/* pointing at a revision that is now gone,
# so huggingface_hub does not later report the cache as corrupted.
prune_refs_to() {
    local refs="$1/refs"
    local rev="$2"
    [ -d "$refs" ] && [ -n "$rev" ] || return 0
    local _ref
    while IFS= read -r _ref; do
        [ -n "$_ref" ] || continue
        case "$_ref" in /*) ;; *) continue ;; esac   # same cwd-fragment guard as orphan_blobs
        [ "$(/bin/cat "$_ref" 2>/dev/null)" = "$rev" ] && /bin/rm -f "$_ref"
    done <<EOF
$(/usr/bin/find "$refs" -type f 2>/dev/null)
EOF
}

# hf_reclaim_after_delete <deleted-path> - the shared tail for ANY deletion out of a Hugging
# Face repo, whatever the engine: drop refs to a revision that no longer exists, then prune the
# blobs nothing references any more. A no-op outside the cache layout (no blobs directory).
hf_reclaim_after_delete() {
    local repo_dir=$(hf_repo_dir_for "$1")
    [ -n "$repo_dir" ] || return 0
    local rev_root=$(hf_revision_root_for "$1" "$repo_dir")
    # Deleting the last variant (or the last .gguf) can EMPTY the revision it lived in.
    # rmdir, never rm -rf: it can only ever succeed on an already-empty directory, so this
    # cannot widen the delete. Leaving the husk matters beyond tidiness - it still counts as a
    # revision, so a later delete of a real sibling revision would take snapshot mode instead
    # of escalating to the repo, and the skeletons would accumulate.
    [ -n "$rev_root" ] && [ -d "$rev_root" ] && /bin/rmdir "$rev_root" 2>/dev/null
    if [ -n "$rev_root" ] && [ ! -d "$rev_root" ]; then
        prune_refs_to "$repo_dir" "$(/usr/bin/basename "$rev_root")"
    fi
    prune_orphan_blobs "$repo_dir"
}

# ── GGUF: the model is a single FILE ───────────────────────────────────────────

# count_visible_items <dir> -> "<count> <yes|no>", the second field saying whether the one
# item found is the selected model. Hidden entries (.DS_Store and friends) are ignored.
count_visible_items() {
    local dir="$1"
    local _count=0
    local _sole_match="no"
    local _item
    while IFS= read -r _item; do
        [ -n "$_item" ] || continue
        _count=$((_count + 1))
        [ "$_item" = "$selected_path" ] && _sole_match="yes"
    done <<< "$(/usr/bin/find "$dir" -mindepth 1 -maxdepth 1 ! -name '.*' 2>/dev/null)"
    echo "$_count $_sole_match"
}

# delete_gguf -> 0 if a deletion was attempted (caller reloads the table), 1 if nothing was
# touched (cancelled or refused).
delete_gguf() {
    if [ ! -f "$selected_path" ]; then
        "$alert" \
            --level caution \
            --title "File Not Found" \
            "The model file no longer exists at:

$selected_path"
        return 1
    fi

    local filename=$(/usr/bin/basename "$selected_path")
    local parent_dir=$(/usr/bin/dirname "$selected_path")
    # -L because a .gguf pulled by huggingface_hub is a SYMLINK into blobs/; the blob is both
    # the real size and, once hf_reclaim_after_delete runs, what is really reclaimed.
    local file_size=$(/usr/bin/stat -f%z -L "$selected_path" 2>/dev/null || echo 0)
    local size_fmt=$(format_bytes "$file_size")
    local folder_name=$(/usr/bin/basename "$parent_dir")

    local visible_count visible_sole_match
    read -r visible_count visible_sole_match <<< "$(count_visible_items "$parent_dir")"

    local delete_mode
    if [ "$visible_count" -eq 1 ] && [ "$visible_sole_match" = "yes" ]; then
        # Parent folder holds only this .gguf - offer to delete the whole folder
        delete_mode="folder"
        "$alert" \
            --level stop \
            --title "Delete Model Folder?" \
            --ok "Delete Folder" \
            --cancel "Cancel" \
            "\"${folder_name}\" contains only this model file:

  ${filename} (${size_fmt})

The folder and its contents will be permanently deleted. This cannot be undone."
    else
        # Parent has other visible content - only offer to delete the file
        delete_mode="file"
        "$alert" \
            --level stop \
            --title "Delete Model File?" \
            --ok "Delete File" \
            --cancel "Cancel" \
            "Permanently delete \"${filename}\" (${size_fmt})?

This cannot be undone.

The parent folder \"${folder_name}\" contains other files and will not be removed. "
    fi

    [ $? -eq 0 ] || return 1

    local rm_result
    if [ "$delete_mode" = "folder" ]; then
        # Re-verify immediately before rm -rf: contents must still be exactly the
        # one .gguf file and nothing else visible. Guards against a race where
        # another process wrote files into the folder between the dialog and now.
        local recheck_count recheck_sole_match
        read -r recheck_count recheck_sole_match <<< "$(count_visible_items "$parent_dir")"
        if [ "$recheck_count" -ne 1 ] || [ "$recheck_sole_match" != "yes" ]; then
            "$alert" \
                --level caution \
                --title "Folder Contents Changed" \
                "The folder \"${folder_name}\" now contains unexpected files. The deletion was cancelled to avoid removing anything unintended.

Please try again."
            return 1
        fi
        if ! path_is_safe_to_remove "$parent_dir"; then
            "$alert" \
                --level stop \
                --title "Refusing to Delete" \
                "\"$parent_dir\" does not look like a model folder, so nothing was deleted."
            return 1
        fi
        echo "Deleting folder: $parent_dir"
        /bin/rm -rf "$parent_dir"
        rm_result=$?
    else
        echo "Deleting file: $selected_path"
        /bin/rm -f "$selected_path"
        rm_result=$?
    fi

    if [ "$rm_result" -ne 0 ]; then
        alert_delete_failed "$rm_result"
        return 0
    fi

    # In the Hugging Face cache the .gguf just removed was a symlink and the bytes are still
    # sitting in blobs/. Without this the delete reports success, frees nothing, and the repo
    # drops out of the picker - so the stranded GBs become invisible as well as unreclaimed.
    hf_reclaim_after_delete "$parent_dir"

    echo "Deleted successfully"
    return 0
}

# ── MLX: the model is a DIRECTORY ──────────────────────────────────────────────

# delete_mlx -> 0 if a deletion was attempted (caller reloads the table), 1 if nothing was
# touched (cancelled or refused).
delete_mlx() {
    # Resolve the PHYSICAL path first. A model reached through a symlinked root would
    # otherwise have its LINK removed and its multi-GB payload left on disk - a delete that
    # reports success and frees nothing. cd -P so a ".." in a recents entry cannot be
    # collapsed lexically onto a different directory than the one we end up in. The link
    # itself is cleaned up at the end.
    local model_dir=$(cd -P "$selected_path" 2>/dev/null && pwd -P)
    if [ -z "$model_dir" ] || [ ! -d "$model_dir" ]; then
        "$alert" \
            --level caution \
            --title "Model Not Found" \
            "The model folder no longer exists at:

$selected_path"
        return 1
    fi

    if ! path_is_safe_to_remove "$model_dir"; then
        "$alert" \
            --level stop \
            --title "Refusing to Delete" \
            "\"$model_dir\" does not look like a model folder, so nothing was deleted."
        return 1
    fi

    local label=$(model_display_label "$selected_path")
    local repo_dir=$(hf_repo_dir_for "$model_dir")
    local rev_root=""
    [ -n "$repo_dir" ] && rev_root=$(hf_revision_root_for "$model_dir" "$repo_dir")

    # Four shapes, decided by what is actually on disk rather than by the path's spelling:
    #   repo     - HF cache, this is the only cached revision: take the repo, which is where
    #              the bytes are.
    #   snapshot - HF cache, other revisions exist: take this revision only, then prune the
    #              blobs it alone referenced. Taking the repo would destroy a revision the
    #              user never selected.
    #   variant  - HF cache, the model sits BELOW a revision root (snapshots/<rev>/4bit):
    #              take that subtree only, then prune. Its siblings share the revision.
    #   dir      - any non-HF layout (LM Studio, a manual download): take the directory.
    local mode target bytes
    local snapshot_count=0
    if [ -n "$repo_dir" ] && [ "$model_dir" = "$rev_root" ]; then
        snapshot_count=$(count_subdirs "$repo_dir/snapshots")
        if [ "$snapshot_count" -le 1 ]; then
            mode="repo"
            target="$repo_dir"
            bytes=$(dir_bytes "$target")
        else
            mode="snapshot"
            target="$model_dir"
            bytes=$(orphan_blob_bytes "$repo_dir" "$model_dir")
        fi
    elif [ -n "$repo_dir" ] && [ -n "$rev_root" ]; then
        mode="variant"
        target="$model_dir"
        bytes=$(orphan_blob_bytes "$repo_dir" "$model_dir")
    else
        mode="dir"
        target="$model_dir"
        bytes=$(dir_bytes "$target")
    fi

    local size_fmt=$(format_bytes "$bytes")

    # ── Confirmation ──────────────────────────────────────────────────────────
    case "$mode" in
        repo)
            "$alert" \
                --level stop \
                --title "Delete Model?" \
                --ok "Delete Model" \
                --cancel "Cancel" \
                "Permanently delete \"${label}\" (${size_fmt})?

The model and its cached data will be removed from:

  ${repo_dir}

This cannot be undone."
            ;;
        snapshot)
            "$alert" \
                --level stop \
                --title "Delete Model Revision?" \
                --ok "Delete Revision" \
                --cancel "Cancel" \
                "\"${label}\" has ${snapshot_count} revisions cached. Only the selected one will be deleted:

  $(/usr/bin/basename "$model_dir")  (${size_fmt} reclaimed)

The other revisions and the data they share are kept. This cannot be undone."
            ;;
        variant)
            "$alert" \
                --level stop \
                --title "Delete Model Variant?" \
                --ok "Delete Variant" \
                --cancel "Cancel" \
                "\"${label}\" keeps several variants in one cached revision. Only the selected one will be deleted:

  ${model_dir#"${rev_root}"/}  (${size_fmt} reclaimed)

The other variants and the data they share are kept. This cannot be undone."
            ;;
        *)
            "$alert" \
                --level stop \
                --title "Delete Model Folder?" \
                --ok "Delete Folder" \
                --cancel "Cancel" \
                "Permanently delete \"${label}\" (${size_fmt})?

The folder and everything in it will be removed:

  ${model_dir}

This cannot be undone."
            ;;
    esac

    [ $? -eq 0 ] || return 1

    # ── Re-verify, then delete ────────────────────────────────────────────────
    # Same guard the GGUF folder branch uses: the dialog is modal to us but not to the disk.
    if [ ! -d "$target" ] || ! path_is_safe_to_remove "$target"; then
        "$alert" \
            --level caution \
            --title "Model Changed" \
            "\"${label}\" is no longer where it was when the dialog opened. The deletion was cancelled.

Please try again."
        return 1
    fi
    if [ "$mode" = "repo" ] && [ "$(count_subdirs "$repo_dir/snapshots")" -gt 1 ]; then
        # Another revision appeared while the dialog was up - taking the repo would now
        # destroy a model the user never selected.
        "$alert" \
            --level caution \
            --title "Model Changed" \
            "Another revision of \"${label}\" was added while the dialog was open. The deletion was cancelled to avoid removing it.

Please try again."
        return 1
    fi
    if [ "$mode" = "dir" ] && [ "$(model_engine "$target")" != "mlx" ]; then
        "$alert" \
            --level caution \
            --title "Model Changed" \
            "\"${target}\" is no longer a loadable MLX model folder. The deletion was cancelled.

Please try again."
        return 1
    fi

    echo "Deleting $mode: $target"
    /bin/rm -rf "$target"
    local rm_result=$?

    if [ "$rm_result" -ne 0 ]; then
        alert_delete_failed "$rm_result"
        return 0
    fi

    if [ "$mode" = "repo" ]; then
        # The repo's lock directory is a SIBLING of the repo, under <hub>/.locks, so it
        # survives the rm above and would accumulate forever.
        local hub_dir=$(/usr/bin/dirname "$repo_dir")
        local locks_dir="$hub_dir/.locks/$(/usr/bin/basename "$repo_dir")"
        [ -d "$locks_dir" ] && /bin/rm -rf "$locks_dir"
    else
        # snapshot / variant: the repo is still there, so reclaim what the removed subtree
        # was holding. A no-op for the non-HF dir mode.
        hf_reclaim_after_delete "$target"
    fi

    # The picker listed a symlink to the model, and the payload it pointed at is gone.
    if [ "$selected_path" != "$model_dir" ] && [ -L "$selected_path" ]; then
        echo "Removing dangling link: $selected_path"
        /bin/rm -f "$selected_path"
    fi

    echo "Deleted successfully"
    return 0
}

# ── Dispatch ───────────────────────────────────────────────────────────────────

if [ -z "$selected_path" ]; then
    echo "No model selected, aborting"
    exit 0
fi

engine=$(model_engine "$selected_path")
echo "Selected model: $selected_path (engine=${engine:-unknown})"

case "$engine" in
    foundation)
        # Unreachable through the UI - the trash is disabled for this row - but this is a
        # DESTRUCTIVE handler, so it answers for itself rather than inheriting the catch-all
        # below, which would test the sentinel with -e, find nothing, and report the model as
        # having been moved or deleted. It is part of macOS; there is nothing of ours to remove.
        deleted=1
        "$alert" \
            --level caution \
            --title "Nothing to Delete" \
            "Apple Foundation Models is part of macOS, not a download this app manages. To remove it, turn off Apple Intelligence in System Settings."
        ;;
    gguf)
        delete_gguf
        deleted=$?
        ;;
    mlx)
        delete_mlx
        deleted=$?
        ;;
    *)
        # model_engine also answers "" for a path that is no longer on disk, which is the
        # likelier case here: the row came from a scan that has since gone stale.
        deleted=1
        if [ -e "$selected_path" ]; then
            "$alert" \
                --level caution \
                --title "Not a Model" \
                "\"$selected_path\" is not a GGUF file or an MLX model folder, so there is nothing to delete."
        else
            "$alert" \
                --level caution \
                --title "Model Not Found" \
                "The model no longer exists at:

$selected_path"
            # The row is stale either way, so refresh the list.
            deleted=0
        fi
        ;;
esac

# ── Reload table ───────────────────────────────────────────────────────────────
if [ "$deleted" -eq 0 ]; then
    clear_selection_ui
    "$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.select.local.model.init"
fi
