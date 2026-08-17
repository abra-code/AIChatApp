#!/bin/sh
# Tests/10-acp-storage.test.sh - saved ACP agents: the storage layer and the scan merge.
#
# No handlers here. These are the library functions the handlers are built out of, called
# directly, because the rules worth pinning live in named functions rather than in whole
# dispatches: what an id is, what a row looks like, what happens to a tab someone pasted into
# a name, and which of the two owners of /agents is allowed to destroy the other's subtree.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.cadabra.sh"

section "an empty profile answers every question without creating anything"
# The read paths must not create the settings file. A read path that writes is how merely
# opening a window ends up owning a configuration the user never made.
cad_reset
check "count on a nonexistent file"  "0"  "$(cad_call acp_custom_count)"
check "list is empty"                ""   "$(cad_call acp_custom_list)"
check "index of a made-up id"        "1"  "$(cad_call acp_custom_index custom:9 >/dev/null 2>&1; echo $?)"
check "get on a made-up id"          ""   "$(cad_call acp_custom_get custom:9 label)"
check_absent "no file was created"        "$cad_settings"

section "add mints ids from a counter"
a=$(cad_call acp_custom_add "My Agent" "/opt/tools/myagent acp")
b=$(cad_call acp_custom_add "Second")
check "first id"                     "custom:1"                 "$a"
check "second id"                    "custom:2"                 "$b"
check "count"                        "2"                        "$(cad_call acp_custom_count)"
check "counter advanced"             "3"                        "$("$cad_plister" get value "$cad_settings" /agents/customNextId 2>/dev/null)"
check "label round trip"             "My Agent"                 "$(cad_call acp_custom_get "$a" label)"
check "command round trip"           "/opt/tools/myagent acp"   "$(cad_call acp_custom_get "$a" command)"
check "empty command reads back empty" ""                       "$(cad_call acp_custom_get "$b" command)"
# The positive control for the check_absent above: the same accessor, in a section where the
# file is supposed to exist. Without it a wrong path would let "no file was created" pass
# forever while proving nothing.
check_exists "and now the file does exist" "$cad_settings"

section "ids are never reused after a removal"
# Names are not identity here, ids are - and /agents/external/id points at one. Reusing a freed
# id would silently re-point the configured agent at whatever was added next.
cad_call acp_custom_remove "$a"
check "count after remove"           "1"          "$(cad_call acp_custom_count)"
check "removed id is gone"           "1"          "$(cad_call acp_custom_index "$a" >/dev/null 2>&1; echo $?)"
check "survivor moved to index 0"    "custom:2"   "$(cad_get /agents/custom/0/id)"
c=$(cad_call acp_custom_add "Third" "/bin/echo hi")
check "next id skips the freed one"  "custom:3"   "$c"
check "survivor still reachable by id" "Second"   "$(cad_call acp_custom_get custom:2 label)"

section "set writes through, and refuses a field it does not own"
cad_call acp_custom_set custom:2 label "Renamed"
check "label updated"    "Renamed"           "$(cad_call acp_custom_get custom:2 label)"
cad_call acp_custom_set custom:2 command "/usr/bin/true acp"
check "command updated"  "/usr/bin/true acp" "$(cad_call acp_custom_get custom:2 command)"
# The field name is interpolated into a plister pseudopath, so a field that traverses upward
# would let a rename write the LIVE agent command - the setting that decides what gets run.
check "set refuses an unknown field"      "1" "$(cad_call acp_custom_set custom:2 ../external/command pwned >/dev/null 2>&1; echo $?)"
check "and created nothing on the way out" ""  "$(cad_get /agents/external/command)"
check "set on an unknown id fails"        "1" "$(cad_call acp_custom_set custom:99 label x >/dev/null 2>&1; echo $?)"

section "tabs and newlines cannot reach the store"
# The list is tab-separated and read back through a table whose hidden columns carry the
# command and the id. A tab inside a label shifts every later field left, which lands prose in
# the argv column and hands the OK handler a note where the command should be.
d=$(cad_call acp_custom_add "$(printf 'Tab\there')" "$(printf '/bin/sh -c\n"echo hi"')")
check "label tab collapsed"      "Tab here"               "$(cad_call acp_custom_get "$d" label)"
check "command newline collapsed" '/bin/sh -c "echo hi"'  "$(cad_call acp_custom_get "$d" command)"
check "list row still has 3 fields" "3" "$(cad_call acp_custom_list | /usr/bin/awk -F'\t' -v id="$d" '$1==id { print NF }')"

section "the list never emits an empty field"
# An empty field collapses under IFS whitespace when the row is read back, shifting later
# fields left - so "absent" is spelled "-" and never "".
"$cad_plister" set string "" "$cad_settings" /agents/custom/0/command >/dev/null 2>&1
check "a blanked command becomes -"        "-"        "$(cad_call acp_custom_list | /usr/bin/awk -F'\t' '$1=="custom:2" { print $3 }')"
"$cad_plister" set string "" "$cad_settings" /agents/custom/0/label >/dev/null 2>&1
check "unnamed with no command falls back to the id" "custom:2" "$(cad_call acp_custom_list | /usr/bin/awk -F'\t' '$1=="custom:2" { print $2 }')"
"$cad_plister" set string "/opt/nowhere/zzagent acp" "$cad_settings" /agents/custom/0/command >/dev/null 2>&1
check "unnamed falls back to the basename"  "zzagent" "$(cad_call acp_custom_list | /usr/bin/awk -F'\t' '$1=="custom:2" { print $2 }')"

section "the scan merges saved agents after the catalog"
# The section above left custom:2 unnamed and pointed at nothing. Restate both, so what follows
# is about the scan rather than about what an earlier section happened to leave behind.
cad_call acp_custom_set custom:2 label "Second"
cad_call acp_custom_set custom:2 command "/usr/bin/true acp"
cad_call acp_custom_set custom:3 command "/opt/nowhere/zzagent acp"
scan=$(cad_call acp_agent_scan)
check "every scan row has 7 fields" "" "$(printf '%s\n' "$scan" | /usr/bin/awk -F'\t' 'NF!=7 { print NR": "NF }')"
check "catalog rows still present"  "opencode" "$(printf '%s\n' "$scan" | /usr/bin/awk -F'\t' '$1=="opencode" { print $1 }')"
check "saved agents come after the catalog" "yes" \
   "$(printf '%s\n' "$scan" | /usr/bin/awk -F'\t' '/^custom:/ { seen=NR } $1=="custom" { cat=NR } END { print (seen>cat) ? "yes" : "no" }')"
check "a resolvable command scans as found"   "found" "$(printf '%s\n' "$scan" | /usr/bin/awk -F'\t' '$1=="custom:2" { print $3 }')"
check "  and its argv passes through verbatim" "/usr/bin/true acp" \
   "$(printf '%s\n' "$scan" | /usr/bin/awk -F'\t' '$1=="custom:2" { print $4 }')"
check "an unresolvable command scans as missing" "missing" "$(printf '%s\n' "$scan" | /usr/bin/awk -F'\t' '$1=="custom:3" { print $3 }')"
cad_call acp_custom_set custom:3 command ""
check "no command at all scans as empty"  "empty" "$(cad_call acp_agent_scan | /usr/bin/awk -F'\t' '$1=="custom:3" { print $3 }')"
check "  with - in the argv column"       "-"     "$(cad_call acp_agent_scan | /usr/bin/awk -F'\t' '$1=="custom:3" { print $4 }')"
cad_call acp_custom_set custom:3 command "/bin/echo hi"

section "a quoted path with spaces is one word"
# Splitting on the first space would call the executable "/My, report a perfectly good agent as
# missing, and name it "My" in the window title.
check "first word of a quoted path"  "/My Tools/agent" "$(cad_call acp_command_first_word '"/My Tools/agent" acp')"
check "first word unquoted"          "/opt/x"          "$(cad_call acp_command_first_word '/opt/x acp')"
check "first word single-quoted"     "/My Tools/agent" "$(cad_call acp_command_first_word "'/My Tools/agent' acp")"
check "first word of an empty command" ""              "$(cad_call acp_command_first_word '')"
/bin/mkdir -p "$OMCTEST_WORK/My Tools"
printf '#!/bin/sh\n' > "$OMCTEST_WORK/My Tools/agent"; /bin/chmod +x "$OMCTEST_WORK/My Tools/agent"
e=$(cad_call acp_custom_add "Spaced" "\"$OMCTEST_WORK/My Tools/agent\" acp")
check "a quoted absolute path resolves" "found" "$(cad_call acp_agent_scan | /usr/bin/awk -F'\t' -v id="$e" '$1==id { print $3 }')"

section "the window title uses the saved name"
cad_call acp_agent_store custom:2 "/usr/bin/true acp" >/dev/null 2>&1
check "a saved agent titles by its name"  "Second"        "$(cad_call acp_agent_stored_label)"
cad_call acp_custom_set custom:2 label "Renamed Again"
check "  and follows a rename"            "Renamed Again" "$(cad_call acp_agent_stored_label)"
cad_call acp_agent_store custom "/opt/adhoc/thing acp" >/dev/null 2>&1
check "an ad-hoc command titles by basename" "thing"      "$(cad_call acp_agent_stored_label)"
cad_call acp_agent_store opencode "/opt/opencode acp" >/dev/null 2>&1
check "a catalog agent titles by catalog label" "OpenCode" "$(cad_call acp_agent_stored_label)"
cad_call acp_agent_store custom:404 "/opt/gone/agent acp" >/dev/null 2>&1
check "a dangling custom id degrades to the basename" "agent" "$(cad_call acp_agent_stored_label)"

section "the two owners of /agents do not destroy each other"
# /agents/custom belongs to this library and /agents/external to the selection, in ONE file
# shared with the MCP settings. Neither may assume it owns the file - mcp_prefs_write_defaults
# used to begin with rm -f, which would take the other owner's settings with it.
cad_call acp_agent_store custom:2 "/usr/bin/true acp" >/dev/null 2>&1
check "external survives a later custom add" "custom:2" "$(cad_call acp_agent_stored_id)"
before=$(cad_call acp_custom_count)
f=$(cad_call acp_custom_add "Late" "/bin/ls")
check "  the add worked"          "$((before + 1))" "$(cad_call acp_custom_count)"
minted=no; case "$f" in custom:[0-9]*) minted=yes ;; esac
check "  and minted the next id"  "yes" "$minted"
check "  which nothing else holds" "1"  "$(cad_call acp_custom_list | /usr/bin/awk -F'\t' -v id="$f" '$1==id' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
check "  external command intact"  "/usr/bin/true acp" "$(cad_call acp_agent_stored_command)"
n=$(cad_call acp_custom_count)
cad_call acp_custom_ensure_tree
check "ensure_tree is idempotent"          "$n" "$(cad_call acp_custom_count)"
cad_call acp_agent_ensure_tree
check "  and does not wipe custom"         "$n" "$(cad_call acp_custom_count)"
cad_call mcp_prefs_init_if_missing >/dev/null 2>&1
check "MCP seeding leaves custom alone"    "$n" "$(cad_call acp_custom_count)"
check "  and seeded its own subtree"       "0"  "$(cad_type /servers >/dev/null 2>&1; echo $?)"
cad_call mcp_prefs_write_defaults >/dev/null 2>&1
check "Reset to Defaults leaves custom alone"      "$n" "$(cad_call acp_custom_count)"
check "  and leaves the external selection alone"  "custom:2" "$(cad_call acp_agent_stored_id)"

omctest_end
