#!/bin/bash
# aichat.select.local.model.delete.sh
# Deletes the selected model file. If the parent folder contains no other
# visible files or directories, offers to delete the folder instead.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"

selected_path="$OMC_ACTIONUI_TABLE_10_COLUMN_3_VALUE"

# ── Safety guards ──────────────────────────────────────────────────────────────

if [ -z "$selected_path" ]; then
    echo "No model selected, aborting"
    exit 0
fi

# Must be a .gguf file
case "$selected_path" in
    *.gguf) ;;
    *)
        echo "Selected path is not a .gguf file — aborting"
        exit 0
        ;;
esac

if [ ! -f "$selected_path" ]; then
    "$alert" \
        --level caution \
        --title "File Not Found" \
        "The model file no longer exists at:

$selected_path"
    exit 0
fi

filename=$(/usr/bin/basename "$selected_path")
parent_dir=$(/usr/bin/dirname "$selected_path")
file_size=$(/usr/bin/stat -f%z -L "$selected_path" 2>/dev/null || echo 0)
size_fmt=$(format_bytes "$file_size")
folder_name=$(/usr/bin/basename "$parent_dir")

# ── Analyze parent directory ───────────────────────────────────────────────────
# Count all visible (non-hidden) items in the parent — files and subdirectories.
# Hidden items (names starting with '.', e.g. .DS_Store) are ignored.

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

read -r visible_count visible_sole_match <<< "$(count_visible_items "$parent_dir")"

# ── Confirmation dialog ────────────────────────────────────────────────────────

if [ "$visible_count" -eq 1 ] && [ "$visible_sole_match" = "yes" ]; then
    # Parent folder holds only this .gguf — offer to delete the whole folder
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
    # Parent has other visible content — only offer to delete the file
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

[ $? -eq 0 ] || exit 0

# ── Delete ─────────────────────────────────────────────────────────────────────

if [ "$delete_mode" = "folder" ]; then
    # Re-verify immediately before rm -rf: contents must still be exactly the
    # one .gguf file and nothing else visible. Guards against a race where
    # another process wrote files into the folder between the dialog and now.
    read -r recheck_count recheck_sole_match <<< "$(count_visible_items "$parent_dir")"
    if [ "$recheck_count" -ne 1 ] || [ "$recheck_sole_match" != "yes" ]; then
        "$alert" \
            --level caution \
            --title "Folder Contents Changed" \
            "The folder \"${folder_name}\" now contains unexpected files. The deletion was cancelled to avoid removing anything unintended.

Please try again."
        exit 0
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
    "$alert" \
        --level caution \
        --title "Delete Failed" \
        "Could not delete the selected item (error ${rm_result}). Check that you have write permission."
    exit 1
fi

echo "Deleted successfully"

# ── Reload table ───────────────────────────────────────────────────────────────
"$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.select.local.model.init"
