#!/bin/sh
# Tests/60-mcp-prefs.test.sh - the MCP server settings layer.
#
# /servers and /allow-network are one of the two subtrees in the shared settings file, and they
# decide what the sandboxed local server may read and write. A wrong answer here is not a
# cosmetic bug: an array entry that fails to delete is a path the model keeps access to after
# the user revoked it, and a duplicate that slips past the guard is the same path granted twice.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.cadabra.sh"

cad_import_ids aichat.mcp.servers.init.sh MCP_

# in_list <key-path> <value>  ->  1 when the array holds exactly that value.
# -Fx, not a substring match: "/private/tmp" and "/private/tmpfoo" are different grants.
in_list() {
    cad_call mcp_prefs_array_list "$1" | /usr/bin/grep -Fxq -- "$2" && echo 1 || echo 0
}

section "the ids this file drives are the ones the dialog declares"
check "the tables and toggles resolved" "320 330 210 240" \
    "$MCP_RW_TABLE_ID $MCP_RO_TABLE_ID $MCP_TIME_TOGGLE_ID $MCP_NETWORK_TOGGLE_ID"

section "defaults are written for a profile that has never been configured"
cad_reset
check "writing defaults succeeds" "0" "$(cad_call mcp_prefs_write_defaults >/dev/null 2>&1; echo $?)"
# READ RAW, not through mcp_prefs_get_bool. That accessor returns "true" for a key that is
# absent, unreadable or non-boolean - which is the right behavior for callers and exactly the
# wrong instrument here. Asserting "true" through it on a profile that was just reset asserts
# the FALLBACK, and stays green if mcp_prefs_write_defaults stores no booleans at all.
check "network is allowed"        "true" "$(cad_raw /allow-network)"
check "time is on"                "true" "$(cad_raw /servers/time/enabled)"
check "search is on"              "true" "$(cad_raw /servers/search/enabled)"
check "pdf is on"                 "true" "$(cad_raw /servers/pdf/enabled)"
check "pdf editing is on"         "true" "$(cad_raw /servers/pdf/writable)"
check "the local server is on"    "true" "$(cad_raw /servers/local/enabled)"
# Types too: a string "true" would read identically above and behave differently everywhere.
check "and they are booleans"     "bool bool bool" \
    "$(cad_type /allow-network) $(cad_type /servers/time/enabled) $(cad_type /servers/pdf/writable)"
check "no project is chosen"      ""     "$(cad_call mcp_prefs_get_string servers/local/project)"
check "  but the key exists"      "string" "$(cad_type /servers/local/project)"
check "the temp dir is writable"  "1"    "$(in_list servers/local/allowed-write /private/tmp)"
check "the session temp is granted" "true" "$(cad_raw /servers/local/include-session-tmpdir)"
check "a system data dir is readable" "1" "$(in_list servers/local/allowed-read /usr/share)"
# Stated plainly because it is the one thing a reader of the default list should not assume:
# the system executable dirs are granted by the sandbox baseline, not by this array, so their
# absence here is correct rather than an oversight.
check "the system bin dirs are NOT listed" "0" "$(in_list servers/local/allowed-read /usr/bin)"
check "  nor the system libraries"         "0" "$(in_list servers/local/allowed-read /usr/lib)"

section "the default seeding only grants directories that exist"
# Every entry is guarded by [ -d ], and the LAST guard in the loop is $HOME/.nvm - which is why
# the function ends with an explicit `return 0`. Without it, the function's exit status is that
# final test, and it reports failure on any machine without nvm. An isolated $HOME is what
# makes this assertable at all: here nvm is reliably absent, and reliably creatable.
cad_reset
check_absent "no nvm in a fresh home" "$HOME/.nvm"
check "defaults still report success" "0" "$(cad_call mcp_prefs_write_defaults >/dev/null 2>&1; echo $?)"
check "  and nvm is not granted"      "0" "$(in_list servers/local/allowed-read "$HOME/.nvm")"
/bin/mkdir -p "$HOME/.nvm"
cad_reset
cad_call mcp_prefs_write_defaults >/dev/null 2>&1
check "with nvm installed it IS granted" "1" "$(in_list servers/local/allowed-read "$HOME/.nvm")"
/bin/rmdir "$HOME/.nvm"

section "seeding tests for the subtree, not for the file"
# The regression this guards: the file may already exist because the AGENT dialog wrote
# /agents into it. A file-existence test would then decide the servers were configured,
# leaving every mcp_prefs_get_* silently on its fallback and the dialog showing defaults it
# had never actually stored.
cad_reset
cad_call acp_custom_add "Some Agent" "/bin/echo acp" >/dev/null 2>&1
check_exists "the agent dialog created the file" "$cad_settings"
check "  and there are no servers in it yet" "" "$(cad_type /servers)"
cad_call mcp_prefs_init_if_missing
check "seeding still runs"        "dict" "$(cad_type /servers)"
check "  and kept the agent"      "1"    "$(cad_call acp_custom_count)"

section "seeding a second time changes nothing"
cad_call mcp_prefs_set_bool servers/time/enabled false
cad_call mcp_prefs_init_if_missing
check "a configured server is not reset" "false" "$(cad_call mcp_prefs_get_bool servers/time/enabled)"

section "a boolean falls back to on, whatever the stored value looks like"
# The fallback is deliberate - the bundled servers are on unless the user says otherwise - so
# the failure mode to guard is a stored value that is neither true nor false being read as
# false, which would silently disable a server the user never turned off.
cad_reset
cad_call mcp_prefs_write_defaults >/dev/null 2>&1
check "an absent key reads on"    "true"  "$(cad_call mcp_prefs_get_bool servers/nosuch/enabled)"
cad_call mcp_prefs_set_bool servers/time/enabled false
check "an explicit false reads off" "false" "$(cad_call mcp_prefs_get_bool servers/time/enabled)"
cad_call mcp_prefs_set_bool servers/time/enabled true
check "  and back on again"         "true"  "$(cad_call mcp_prefs_get_bool servers/time/enabled)"
cad_call mcp_prefs_set_string servers/time/enabled "yes"
check "a non-boolean reads on"      "true"  "$(cad_call mcp_prefs_get_bool servers/time/enabled)"

section "the project workspace is stored verbatim"
cad_reset
cad_call mcp_prefs_write_defaults >/dev/null 2>&1
cad_call mcp_prefs_set_string servers/local/project "/Users/someone/My Project"
check "a path with a space"  "/Users/someone/My Project" "$(cad_call mcp_prefs_get_string servers/local/project)"
cad_call mcp_prefs_set_string servers/local/project "/tmp/it's \"quoted\""
check "a path with quotes"   "/tmp/it's \"quoted\""      "$(cad_call mcp_prefs_get_string servers/local/project)"
cad_call mcp_prefs_set_string servers/local/project ""
check "and can be cleared"   ""                          "$(cad_call mcp_prefs_get_string servers/local/project)"

section "granting a path refuses to grant it twice"
cad_reset
cad_call mcp_prefs_write_defaults >/dev/null 2>&1
before=$(cad_call mcp_prefs_array_count servers/local/allowed-read)
check "a new path is appended"      "0" "$(cad_call mcp_prefs_array_append servers/local/allowed-read /Users/Shared; echo $?)"
check "  and the count grew"        "$((before + 1))" "$(cad_call mcp_prefs_array_count servers/local/allowed-read)"
check "the same path is refused"    "1" "$(cad_call mcp_prefs_array_append servers/local/allowed-read /Users/Shared; echo $?)"
check "  and the count held"        "$((before + 1))" "$(cad_call mcp_prefs_array_count servers/local/allowed-read)"
# The duplicate guard reads an INDEX back from plister and tests it with [ -n ]. Index 0 is a
# perfectly good index that prints as "0", and a guard written with [ -z ] or an arithmetic
# test would let the FIRST entry in every array be granted a second time. /private/tmp is
# index 0 of allowed-write by construction, so this is the case that catches it.
check "the first entry in an array is also refused" "1" \
    "$(cad_call mcp_prefs_array_append servers/local/allowed-write /private/tmp; echo $?)"
check "  and allowed-write did not grow" "1" "$(cad_call mcp_prefs_array_count servers/local/allowed-write)"

section "revoking a path"
check "an existing path is removed"  "0" "$(cad_call mcp_prefs_array_remove_value servers/local/allowed-read /Users/Shared; echo $?)"
check "  and is gone from the list"  "0" "$(in_list servers/local/allowed-read /Users/Shared)"
check "removing it again reports so" "1" "$(cad_call mcp_prefs_array_remove_value servers/local/allowed-read /Users/Shared; echo $?)"
check "a path never granted"         "1" "$(cad_call mcp_prefs_array_remove_value servers/local/allowed-read /nope; echo $?)"
# The index-0 case again, from the other side: revoking the first entry must actually revoke it.
check "the first entry can be revoked" "0" \
    "$(cad_call mcp_prefs_array_remove_value servers/local/allowed-write /private/tmp; echo $?)"
check "  leaving the array empty"      "0" "$(cad_call mcp_prefs_array_count servers/local/allowed-write)"

section "a granted path with a space survives the round trip"
cad_call mcp_prefs_array_append servers/local/allowed-read "/Volumes/My Disk/data"
check "it is listed exactly"  "1" "$(in_list servers/local/allowed-read "/Volumes/My Disk/data")"
check "  and revokes cleanly" "0" "$(cad_call mcp_prefs_array_remove_value servers/local/allowed-read "/Volumes/My Disk/data"; echo $?)"

section "an absent array counts as nothing, not as zero"
# plister prints NOTHING for `get count` on a key that does not exist, where a caller reading
# it as a number would see an empty string. Pinned because it is surprising, and because the
# obvious "fix" - making it print 0 - would silently turn "never configured" into "configured
# and empty" for every caller.
cad_reset
check "no array, no count" "" "$(cad_call mcp_prefs_array_count servers/local/allowed-read)"

section "the session temp dir is canonical, and inside the test scratch"
td=$(cad_call mcp_session_tmpdir)
check "it resolves symlinks the way the generator does" "$( (cd "$TMPDIR" && pwd -P) )" "$td"
# Compared against the CANONICAL scratch root, not against $OMCTEST_SCRATCH itself: the scratch
# lives under /tmp, which is a symlink to /private/tmp, so the raw variable and a pwd -P result
# never share a prefix. Getting this wrong is how an isolation check ends up asserting that the
# isolation failed.
scratch_real=$( (cd "$OMCTEST_SCRATCH" && pwd -P) )
check "  and the harness really redirected TMPDIR" "1" \
    "$(printf '%s' "$td" | /usr/bin/grep -q "^$scratch_real/" && echo 1 || echo 0)"

section "the path tables are repainted from the arrays"
cad_reset
cad_call mcp_prefs_write_defaults >/dev/null 2>&1
cad_call mcp_prefs_array_append servers/local/allowed-read /Users/Shared
cad_ui_reset
cad_call mcp_refresh_path_table "$OMC_ACTIONUI_WINDOW_UUID" "$MCP_RO_TABLE_ID" servers/local/allowed-read
# Asserted as a DELTA rather than against mcp_prefs_array_count, which is the same library
# reading the same array - a comparison that agrees with itself by construction.
rows_before=$(ui_row_count "$MCP_RO_TABLE_ID")
cad_call mcp_prefs_array_append servers/local/allowed-read /Users/Shared/second
cad_call mcp_refresh_path_table "$OMC_ACTIONUI_WINDOW_UUID" "$MCP_RO_TABLE_ID" servers/local/allowed-read
check "one more grant is one more row" "$((rows_before + 1))" "$(ui_row_count "$MCP_RO_TABLE_ID")"
cad_call mcp_prefs_array_remove_value servers/local/allowed-read /Users/Shared/second
cad_call mcp_refresh_path_table "$OMC_ACTIONUI_WINDOW_UUID" "$MCP_RO_TABLE_ID" servers/local/allowed-read
check "  and revoking is one fewer"    "$rows_before" "$(ui_row_count "$MCP_RO_TABLE_ID")"
check "  including the one just added" "1" \
    "$(ui_rows "$MCP_RO_TABLE_ID" | /usr/bin/grep -Fxq /Users/Shared && echo 1 || echo 0)"

section "an emptied array leaves an empty table, not a stale one"
# The refresh removes all rows and only then writes: a repaint that appended would leave the
# revoked path on screen, which is the one thing a permissions table must never do.
# BOUNDED. The loop terminates only because remove_value reports failure, so a remove that
# returns 0 without removing would hang the file forever with no timeout and no diagnostic.
drain_guard=0
while [ -n "$(cad_call mcp_prefs_array_list servers/local/allowed-read)" ]; do
    cad_call mcp_prefs_array_remove_value servers/local/allowed-read \
        "$(cad_call mcp_prefs_array_list servers/local/allowed-read | /usr/bin/head -1)" || break
    drain_guard=$((drain_guard + 1))
    [ "$drain_guard" -gt 50 ] && break
done
check "the array drained rather than spun" "1" "$([ "$drain_guard" -le 50 ] && echo 1 || echo 0)"
cad_call mcp_refresh_path_table "$OMC_ACTIONUI_WINDOW_UUID" "$MCP_RO_TABLE_ID" servers/local/allowed-read
check "no rows remain" "0" "$(ui_row_count "$MCP_RO_TABLE_ID")"

section "the read-write table shows the session temp as a row it never stores"
cad_reset
cad_call mcp_prefs_write_defaults >/dev/null 2>&1
cad_ui_reset
cad_call mcp_refresh_rw_table "$OMC_ACTIONUI_WINDOW_UUID" "$MCP_RW_TABLE_ID"
check "the stored path is shown"  "1" \
    "$(ui_rows "$MCP_RW_TABLE_ID" | /usr/bin/grep -Fxq /private/tmp && echo 1 || echo 0)"
check "the session temp is shown" "1" \
    "$(ui_rows "$MCP_RW_TABLE_ID" | /usr/bin/grep -Fxq "$td" && echo 1 || echo 0)"
check "  but was never stored"    "0" "$(in_list servers/local/allowed-write "$td")"
check "two rows, no more"         "2" "$(ui_row_count "$MCP_RW_TABLE_ID")"

section "revoking the session temp hides the row"
cad_call mcp_prefs_set_bool servers/local/include-session-tmpdir false
cad_ui_reset
cad_call mcp_refresh_rw_table "$OMC_ACTIONUI_WINDOW_UUID" "$MCP_RW_TABLE_ID"
check "only the stored path is left" "1" "$(ui_row_count "$MCP_RW_TABLE_ID")"
check "  and it is the stored one"   "/private/tmp" "$(ui_rows "$MCP_RW_TABLE_ID")"

section "cumulative: no handler wrote to a view id the window does not declare"
# cad_unknown_writes_all, not ui_unknown_writes: ui_reset DELETES unknown_ids.log along with
# the windows, so the plain form covers only what happened since the last reset - which in a
# file that resets per section is close to nothing. Measured: a handler scribbling on a
# made-up view id went entirely unnoticed by the plain form.
check "no undeclared ids" "" "$(cad_unknown_writes_all)"
check "no table clobbered by a bare value write" "" "$(cad_suspect_writes_all)"

omctest_end
