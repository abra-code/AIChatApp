#!/bin/sh
# aichat.history.library.sh
# History-store helpers shared by the history window handlers and by the chat window's
# restore-on-open path (aichat.chat.init.sh). Sources the base library for $dialog /
# $pasteboard / pb_get / pb_set / history_root. All read helpers delegate to
# history_store.py (bundled python) so JSON handling stays robust.
[ -n "${__AICHAT_HISTORY_LIB:-}" ] && return 0
__AICHAT_HISTORY_LIB=1

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

history_py="$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3"
history_store="$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/history_store.py"

# history_valid_sid <sid> — guard against path traversal / empties. Session ids are bare
# dir names like 20260707T193808Z-2042 or webui-<id>; never contain "/" "..", never start
# with a dot.
history_valid_sid() {
    case "$1" in
        ""|*/*|*..*|.*) return 1 ;;
        *) return 0 ;;
    esac
}

# history_session_dir <sid> — echo the absolute session directory (validated).
history_session_dir() {
    history_valid_sid "$1" || { echo "invalid session id: $1" >&2; return 1; }
    echo "$history_root/$1"
}

# history_index — TSV rows "title<TAB>session_id" for the sidebar list (recent first).
history_index() {
    "$history_py" "$history_store" index "$history_root"
}

# history_populate_table <win> <table_id> — (re)fill the sidebar list from the store, most
# recent first. Single visible "Title" column (declared in aichat.chat.json); session_id
# rides as the hidden trailing field. Safe to call repeatedly (chat init + refresh).
history_populate_table() {
    local win="$1" table_id="$2" rows
    "$dialog" "$win" "$table_id" omc_table_remove_all_rows
    rows=$(history_index)
    [ -n "$rows" ] && printf "%s" "$rows" | "$dialog" "$win" "$table_id" omc_table_set_rows_from_stdin
}

# history_transcript_json <session_dir> [prime] — ChatTranscript JSON for states["content"].
# Optional prime ("true"/"false"/"defer") rides on the JSON as the transient restore
# directive: "defer" = display only, the element replays the conversation into the agent
# lazily on the next send (the seamless sidebar switch); false = display with a FRESH agent
# context (Read Only); true/absent = replay immediately. See docs/session-prime.md in the
# mlx-agent repo.
history_transcript_json() {
    "$history_py" "$history_store" transcript "$1" ${2:+"$2"}
}

# history_info_line <sid> — one compact "Model · Started · Messages" line for the info strip.
history_info_line() {
    local dir
    dir=$(history_session_dir "$1") || return 1
    "$history_py" "$history_store" info "$dir"
}

# history_title <sid> — display title (meta.title, else first user line, else "(untitled)").
history_title() {
    local dir
    dir=$(history_session_dir "$1") || return 1
    "$history_py" "$history_store" title "$dir"
}

# history_init_meta <session_dir> <sid> <model_path> [agent_label] - write a fresh meta.json
# (JSON-safe, atomic: a concurrent history_index scan never sees a torn/empty file).
#
# model_path and agent_label are mutually exclusive: a conversation runs either the bundled
# model or an external ACP agent, and an external one has no model path to record.
history_init_meta() {
    "$history_py" "$history_store" meta-init "$2" "$3" "${4:-}" > "$1/meta.json.tmp" &&
        /bin/mv -f "$1/meta.json.tmp" "$1/meta.json"
}

# history_meta_field <sid> <key> — echo one string field from a session's meta.json ("" if
# missing/unreadable).
history_meta_field() {
    local dir
    dir=$(history_session_dir "$1") || return 1
    "$history_py" -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
    v=d.get(sys.argv[2],"")
    sys.stdout.write(v if isinstance(v,str) else str(v))
except Exception:
    pass' "$dir/meta.json" "$2"
}

# history_inject_content <window_uuid> <view_id> <sid> [prime] — load a saved transcript
# into the Chat element via states["content"]. Unlike the string-state API this is
# re-injectable (OMC's omc_set_state uses the native setter): each call REPLACES the
# displayed conversation, so selecting different rows swaps the chat in place. Injecting
# {"version":1,"items":[]} (see aichat.chat.new.sh) clears it. Optional prime
# ("true"/"false"/"defer") is the context directive (see history_transcript_json).
history_inject_content() {
    local dir transcript
    dir=$(history_session_dir "$3") || return 1
    transcript=$(history_transcript_json "$dir" ${4:+"$4"})
    [ -n "$transcript" ] || return 1
    "$dialog" "$1" "$2" omc_set_state content "$transcript"
}
