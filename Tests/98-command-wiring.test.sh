#!/bin/sh
# Tests/98-command-wiring.test.sh - every command the engine dispatches has a script to run.
#
# This file exists because of a bug that shipped in plain sight. The main command is the first
# entry in COMMAND_LIST and carries no COMMAND_ID, so the engine resolves its script from the
# command's NAME: OmcExecutor.cp's CreateScriptPathAndShell builds "<NAME>.main" and falls back
# to a literal "main". The AIChat -> Cadabra rename changed NAME to "Cadabra" and left the file
# called AIChat.main.sh, so the engine looked for a script that did not exist.
#
# NOTHING REPORTED IT. A missing script file is not an error in this engine - it logs
# "unable to find script file" and returns - so the applet launched, ran nothing, opened no
# window, and exited with success. The suite was 774 checks green at the time, because every
# one of them dispatches a handler BY COMMAND ID and so walked straight past the one binding
# that is derived from a name instead. A whole-applet defect hid behind per-handler coverage.
#
# So the assertions here are deliberately about the WIRING rather than about behavior: given
# the command table the engine will read, does a script exist for every command it can
# dispatch. That is a question no amount of handler testing answers.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.cadabra.sh"

cad_commands="$OMC_APP_BUNDLE_PATH/Contents/Resources/Command.json"
cad_scripts="$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts"

# plister reads Command.json directly - it is a property list in JSON syntax, and this is the
# same binary the handlers themselves use. Parsing the file with sed or awk would be asserting
# about a text shape rather than about the table the engine actually loads.
cmd_field() { # <index> <key>
    "$cad_plister" get string "$cad_commands" "/COMMAND_LIST/$1/$2" 2>/dev/null
}

section "the command table is readable at all"
# The positive control for everything below. Every later check is of the form "nothing is
# missing", and an unreadable or empty table produces exactly that answer while examining
# nothing - the classic assertion that cannot fail. The count is asserted to be plausible
# rather than exact, so adding a command does not turn this file red for no reason.
cmd_total=$("$cad_plister" get count "$cad_commands" "/COMMAND_LIST" 2>/dev/null)
if [ -z "$cmd_total" ] || [ "$(expr "$cmd_total" : '[0-9][0-9]*$')" -eq 0 ]; then
    cmd_total=0
fi
check "Command.json is present"           "1"  "$([ -f "$cad_commands" ] && echo 1 || echo 0)"
check "the Scripts directory is present"  "1"  "$([ -d "$cad_scripts" ] && echo 1 || echo 0)"
check "the command list has many commands" "1" "$([ "$cmd_total" -gt 50 ] && echo 1 || echo 0)"

section "every command the engine can dispatch has a script"
# The engine's own rule, restated: a command with a COMMAND_ID resolves to <COMMAND_ID>.sh, and
# one without resolves to <NAME>.main.sh. Only exe_script_file commands need a file at all -
# exe_shell_script carries its body inline.
#
# Asserted as an exact filename rather than through omctest's resolver on purpose. The harness
# lowercases the command id and accepts any of several extensions, which is the right latitude
# for a test runner and the wrong thing to assert here: it would answer "some file could serve
# this command" when the question is "does the file the engine will look for exist".
cmd_missing=""
cmd_checked=0
cmd_i=0
while [ "$cmd_i" -lt "$cmd_total" ]; do
    cmd_mode=$(cmd_field "$cmd_i" EXECUTION_MODE)
    if [ "$cmd_mode" = "exe_script_file" ]; then
        cmd_id=$(cmd_field "$cmd_i" COMMAND_ID)
        if [ -n "$cmd_id" ]; then
            cmd_want="$cmd_id.sh"
        else
            cmd_want="$(cmd_field "$cmd_i" NAME).main.sh"
        fi
        cmd_checked=$((cmd_checked + 1))
        if [ ! -f "$cad_scripts/$cmd_want" ]; then
            cmd_missing="$cmd_missing $cmd_want"
        fi
    fi
    cmd_i=$((cmd_i + 1))
done
# Trimmed, so the expected value can be the empty string and the failure message reads as a
# list of filenames rather than as a leading blank.
cmd_missing=$(printf '%s' "$cmd_missing" | /usr/bin/sed 's/^ *//')

check "the loop examined the script-file commands" "1" \
    "$([ "$cmd_checked" -gt 50 ] && echo 1 || echo 0)"
check "no command resolves to a script that is missing" "" "$cmd_missing"

section "a command that only carries a window declares no script at all"
# The other half of the same invariant, and the reason the sweep above can be strict.
#
# A command whose entire job is to carry an ACTIONUI_WINDOW has no work to do: the window is
# shown by the engine and the real code lives in its INIT_SUBCOMMAND_ID. Declaring such a
# command exe_script_file means declaring a script that does nothing, and six of Cadabra's
# seven carriers used to ship exactly that - files containing only comments. That is not merely
# redundant, it is camouflage: it trains the eye to expect a handler script with no statements
# in it, which is indistinguishable from a handler whose body was deleted by accident.
#
# exe_shell_script with no COMMAND is the applet family's answer (PDFUtil.new is the canonical
# one) and Cadabra already had it right for aichat.hf.browse. Asserted generically rather than
# per id, so a new dialog is covered the day it is added.
win_total=0
win_bad_mode=""
win_with_body=""
cmd_i=0
while [ "$cmd_i" -lt "$cmd_total" ]; do
    if [ -n "$("$cad_plister" get type "$cad_commands" "/COMMAND_LIST/$cmd_i/ACTIONUI_WINDOW" 2>/dev/null)" ]; then
        win_total=$((win_total + 1))
        cmd_id=$(cmd_field "$cmd_i" COMMAND_ID)
        if [ "$(cmd_field "$cmd_i" EXECUTION_MODE)" != "exe_shell_script" ]; then
            win_bad_mode="$win_bad_mode $cmd_id"
        fi
        if [ -n "$("$cad_plister" get type "$cad_commands" "/COMMAND_LIST/$cmd_i/COMMAND" 2>/dev/null)" ]; then
            win_with_body="$win_with_body $cmd_id"
        fi
    fi
    cmd_i=$((cmd_i + 1))
done
win_bad_mode=$(printf '%s' "$win_bad_mode" | /usr/bin/sed 's/^ *//')
win_with_body=$(printf '%s' "$win_with_body" | /usr/bin/sed 's/^ *//')

check "the applet has window-carrier commands" "1" "$([ "$win_total" -ge 7 ] && echo 1 || echo 0)"
check "every carrier is exe_shell_script"      ""  "$win_bad_mode"
check "no carrier carries an inline body"      ""  "$win_with_body"

section "the main command, which is the whole of launch"
# Named separately from the sweep above because this one binding is the one that broke, and a
# sweep reports it as one entry in a list. The main command must stay ID-less: giving it a
# COMMAND_ID would change how its script is resolved and silently orphan Cadabra.main.sh again.
check "the main command has no COMMAND_ID" "" "$(cmd_field 0 COMMAND_ID)"
check "its NAME is what the bundle is called" "Cadabra" "$(cmd_field 0 NAME)"
check "the script the engine will look for exists" "1" \
    "$([ -f "$cad_scripts/Cadabra.main.sh" ] && echo 1 || echo 0)"
# The specific regression. A rename that leaves the old file behind is invisible otherwise:
# the new name resolves, the stale one just sits there, and the next rename copies the mistake.
check "no stale AIChat.main.sh left behind" "0" \
    "$([ -f "$cad_scripts/AIChat.main.sh" ] && echo 1 || echo 0)"
# The engine's documented fallback. A file literally named "main.sh" would answer for the main
# command regardless of NAME, which would make the binding above untestable - and would mean a
# future rename appears to work while running the wrong script.
check "no bare main.sh shadowing the fallback" "0" \
    "$([ -f "$cad_scripts/main.sh" ] && echo 1 || echo 0)"

section "a bare launch opens the Local Models dialog"
# The behavior the user meets: double-click the app with nothing selected. ACTIVATION_MODE is
# absent from the main command and therefore act_always, which is what lets this run with no
# file context at all - if someone adds act_file_or_folder, the engine shows a file picker
# before any of this and the launch experience silently changes.
chains_reset
omc_run "Cadabra.main"
check_status "the main command succeeds" 0
check "it asks for the Local Models dialog" "1" "$(chain_asked aichat.select.local.model)"
check "it does not open a chat window"      "0" "$(chain_asked aichat.chat)"
check "it asks exactly once"                "1" "$(chain_asked aichat.select.local.model)"

section "a dropped model opens the chat window instead"
# The other half of the branch, and the reason this command chains imperatively with
# omc_next_command rather than declaratively with NEXT_COMMAND_ID the way PDFUtil does: the two
# outcomes are different windows, so the choice cannot be deferred until one has opened.
chains_reset
cad_dropped="$OMCTEST_WORK/Dropped-Q4_K_M.gguf"
/usr/bin/head -c 2048 /dev/zero > "$cad_dropped"
omc_object "$cad_dropped"
omc_run "Cadabra.main"
check_status "the main command succeeds with an object" 0
check "it opens the chat window"                 "1" "$(chain_asked aichat.chat)"
check "it does not open the Local Models dialog" "0" "$(chain_asked aichat.select.local.model)"

section "the routing follows the object, and the drop leaves nothing sticky"
# The object context has to be cleared EXPLICITLY: omc_run clears the one-shot trigger and
# dialog variables the way the engine does between dispatches, but OMC_OBJ_PATH is not one of
# them - it is the command's input, and it persists until the test says otherwise. Asserting a
# bare launch without clearing it measures the previous section's drop all over again.
#
# What is worth asserting once it IS cleared: that the branch is decided by the object alone.
# The drop path runs aichat.chat.init, which writes settings - a launch preference stored there
# would make every later launch open a chat window and never the picker again, and the user
# would experience that as the app "forgetting" the fix.
chains_reset
omc_object ""
omc_run "Cadabra.main"
check "a bare launch after a drop is back to the picker" "1" "$(chain_asked aichat.select.local.model)"
check "  and does not reuse the earlier drop"            "0" "$(chain_asked aichat.chat)"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids" "" "$(ui_unknown_writes)"
check "no table clobbered by a bare value write" "" "$(ui_suspect_writes)"

omctest_end
