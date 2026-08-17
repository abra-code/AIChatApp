#!/bin/sh
# Tests/90-model-picker.test.sh - the local model list and its info pane.
#
# Every scan root this window walks is under $HOME, which is what makes the list assertable at
# all: the harness gives each test file its own home, so "these are the models on this Mac" is
# a fact the test writes rather than one it has to tolerate.
#
# One gap is stated rather than worked around: recently-opened models come from `defaults read
# com.abracode.Cadabra`, and cfprefsd keys the user domain by uid rather than by $HOME - so the
# developer's real recents are still read here and can add rows. Nothing below asserts a total
# row count for that reason; the fixtures are identified by path instead.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.cadabra.sh"

cad_import_ids aichat.select.local.model.selection.changed.sh LM_
FOUNDATION="foundation:apple-on-device"
MODELS="$HOME/Library/Application Support/Cadabra/Models"

# row_for <path> -> the picker row whose hidden path column matches, tab separated.
row_for() { ui_rows "$LM_TABLE_ID" | /usr/bin/awk -F'\t' -v p="$1" '$3 == p { print; exit }'; }
field()   { row_for "$1" | /usr/bin/cut -f"$2"; }

# What the user meets, rather than which verb produced it: "" (never touched) and "0"
# (explicitly disabled) are the same button to a person, and only "1" is clickable.
bench_btn_state() {
    [ "$(ui_enabled "$LM_BENCH_BTN_ID")" = "1" ] && echo enabled || echo "not enabled"
}

# An MLX model: config.json plus a shard. The tokenizer config is what decides the tools badge.
mk_mlx() { # <dir> <bytes> [tokenizer-json]
    /bin/mkdir -p "$1"
    echo '{}' > "$1/config.json"
    /usr/bin/head -c "$2" /dev/zero > "$1/model.safetensors"
    [ -n "$3" ] && printf '%s' "$3" > "$1/tokenizer_config.json"
    return 0
}

section "the ids this file drives are the ones the dialog declares"
check "the picker's controls resolved" "10 12 3 20 24 30 51" \
    "$LM_TABLE_ID $LM_INFO_TEXT_ID $LM_LOAD_BUTTON_ID $LM_REVEAL_BUTTON_ID $LM_DELETE_BUTTON_ID $LM_USE_TOOLS_TOGGLE_ID $LM_BENCH_BTN_ID"

section "a model's chat template decides whether tools are offered"
# Both failure modes here are documented in the applet and both are silent. A false positive
# auto-ticks the tools toggle and spawns MCP servers the user never asked for; a false negative
# hides tool support on a model that has it.
TOOLS_TMPL='{"chat_template": "{% for m in messages %}{{ m.content }}{% endfor %}{{ tool_call }}"}'
PLAIN_TMPL='{"chat_template": "{% for m in messages %}{{ m.content }}{% endfor %}"}'
VOCAB_ONLY='{"added_tokens_decoder": {"1": {"content": "<|tool_call_start|>"}}}'
mk_mlx "$MODELS/mlx-tools" 4096 "$TOOLS_TMPL"
mk_mlx "$MODELS/mlx-plain" 4096 "$PLAIN_TMPL"
mk_mlx "$MODELS/mlx-vocab" 4096 "$VOCAB_ONLY"
mk_mlx "$MODELS/mlx-jinja" 4096 "$PLAIN_TMPL"
printf '%s' '{% if tool_call %}{{ tool_call }}{% endif %}' > "$MODELS/mlx-jinja/chat_template.jinja"
mk_mlx "$MODELS/mlx-bare"  4096
check "a template that renders tool calls counts" "0" \
    "$(cad_call_lib aichat.model.library.sh model_supports_tools "$MODELS/mlx-tools" mlx; echo $?)"
check "a template without them does not"          "1" \
    "$(cad_call_lib aichat.model.library.sh model_supports_tools "$MODELS/mlx-plain" mlx; echo $?)"
# The false POSITIVE: tokenizer_config.json also carries added_tokens_decoder, so a model that
# merely has the token in its VOCABULARY matches a naive grep of the whole file.
check "a tool token in the vocabulary alone does not" "1" \
    "$(cad_call_lib aichat.model.library.sh model_supports_tools "$MODELS/mlx-vocab" mlx; echo $?)"
# The false NEGATIVE: newer HF exports put the template in chat_template.jinja and leave no
# chat_template key in tokenizer_config.json at all.
check "a template in chat_template.jinja counts"     "0" \
    "$(cad_call_lib aichat.model.library.sh model_supports_tools "$MODELS/mlx-jinja" mlx; echo $?)"
check "a model with no template at all does not"     "1" \
    "$(cad_call_lib aichat.model.library.sh model_supports_tools "$MODELS/mlx-bare" mlx; echo $?)"

section "the picker lists what is on this Mac"
/usr/bin/head -c 2048 /dev/zero > "$MODELS/Tiny-Instruct-Q4_K_M.gguf"
cad_ui_reset
omc_run aichat.select.local.model.init
check_status "init ran" 0
check "the table is titled Model and Size" "Model
Size" "$(ui_columns "$LM_TABLE_ID")"
check "the gguf is listed"     "1" "$([ -n "$(row_for "$MODELS/Tiny-Instruct-Q4_K_M.gguf")" ] && echo 1 || echo 0)"
check "the mlx model is listed" "1" "$([ -n "$(row_for "$MODELS/mlx-tools")" ] && echo 1 || echo 0)"
check "a gguf is badged GGUF"  "Tiny-Instruct-Q4_K_M [GGUF]" "$(field "$MODELS/Tiny-Instruct-Q4_K_M.gguf" 1)"
check "  and sized"            "0.0 GB" "$(field "$MODELS/Tiny-Instruct-Q4_K_M.gguf" 2)"
check "an mlx model is badged MLX and hammered" "mlx-tools [MLX] $(printf '\360\237\224\250')" \
    "$(field "$MODELS/mlx-tools" 1)"
check "one without tools gets no hammer" "mlx-plain [MLX]" "$(field "$MODELS/mlx-plain" 1)"

section "a directory that only looks like a model is not listed"
# config.json with no shards is an HF snapshot of a GGUF repo. The picker scans FOR config.json,
# so this is the case where the scan and model_engine must agree, and the scan defers.
/bin/mkdir -p "$MODELS/not-a-model"
echo '{}' > "$MODELS/not-a-model/config.json"
cad_ui_reset
omc_run aichat.select.local.model.init
check "a config with no shards is skipped" "" "$(row_for "$MODELS/not-a-model")"

section "the same file under two roots is two rows, because dedup is by path"
# Stated as what it IS rather than as "listed once", which is what this fixture looked like it
# was testing and is not. add_row dedupes on the path STRING, and two roots reaching one file
# through a symlink yield two different strings - so both are listed, and that is the designed
# behavior rather than a bug being pinned.
#
# The case the dedup actually exists for - a recents entry naming a model the scan already
# found - is NOT reachable under test: recents come from `defaults read com.abracode.Cadabra`,
# and cfprefsd keys the user domain by uid rather than by $HOME, so the only way to set it up
# would be to write the developer's real preferences. Left uncovered deliberately; see the
# commit note.
/bin/mkdir -p "$HOME/.lmstudio/models"
/bin/ln -sfn "$MODELS/Tiny-Instruct-Q4_K_M.gguf" "$HOME/.lmstudio/models/Tiny-Instruct-Q4_K_M.gguf"
cad_ui_reset
omc_run aichat.select.local.model.init
check "the original path appears exactly once" "1" \
    "$(ui_rows "$LM_TABLE_ID" | /usr/bin/awk -F'\t' -v p="$MODELS/Tiny-Instruct-Q4_K_M.gguf" '$3 == p' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
check "  and the symlinked root adds its own row" "1" \
    "$([ -n "$(row_for "$HOME/.lmstudio/models/Tiny-Instruct-Q4_K_M.gguf")" ] && echo 1 || echo 0)"
check "  which the picker sizes identically"      "0.0 GB" \
    "$(field "$HOME/.lmstudio/models/Tiny-Instruct-Q4_K_M.gguf" 2)"

section "the on-device model heads the list, and is never sized"
# Its availability depends on the machine, so what is asserted is the SHAPE: at most one row,
# first when present, carrying the sentinel and the word "system" rather than a measurement.
# Written as IMPLICATIONS rather than as an if/else, for two reasons. A branch taken only when
# the row is absent, whose single check re-tests the very condition that selected it, cannot
# fail. And a file whose check COUNT depends on the host makes "690 passed" unverifiable - this
# way the same five run on every Mac, and each is a real claim on both branches.
fnd=$(ui_rows "$LM_TABLE_ID" | /usr/bin/awk -F'\t' -v s="$FOUNDATION" '$3 == s')
fnd_count=$(printf '%s' "$fnd" | /usr/bin/grep -c . | /usr/bin/tr -d ' ')
# THE ANTECEDENT IS THE PROBE, NOT THE ROW. Every check below is of the form "if the row is
# present, then ...", and that family shares one blind spot: deleting add_foundation_row
# entirely satisfies all of them vacuously. What decides whether the row SHOULD exist is
# foundation_offerable, so that is what the presence of the row is checked against.
fnd_reason=$(cad_call_lib aichat.model.library.sh foundation_probe | /usr/bin/cut -f1)
if cad_call_lib aichat.model.library.sh foundation_offerable "$fnd_reason"; then want_row=1; else want_row=0; fi
check "the row exists exactly when the engine is offerable" "$want_row" \
    "$([ -n "$fnd" ] && echo 1 || echo 0)"
check "never more than one on-device row" "1" "$([ "$fnd_count" -le 1 ] && echo 1 || echo 0)"
check "if present, it heads the list" "1" \
    "$([ -z "$fnd" ] && echo 1 || { [ "$fnd" = "$(ui_rows "$LM_TABLE_ID" | /usr/bin/head -1)" ] && echo 1 || echo 0; })"
check "if present, its size reads system" "1" \
    "$([ -z "$fnd" ] && echo 1 || { [ "$(printf '%s' "$fnd" | /usr/bin/cut -f2)" = "system" ] && echo 1 || echo 0; })"
check "never sized in GB"     "0" "$(cad_has "$(printf '%s' "$fnd" | /usr/bin/cut -f2)" "GB")"
check "if present, badged Apple" "1" \
    "$([ -z "$fnd" ] && echo 1 || cad_has "$(printf '%s' "$fnd" | /usr/bin/cut -f1)" "[Apple]")"

section "with nothing selected the pane says so and everything is disabled"
cad_ui_reset
omc_table_cell "$LM_TABLE_ID" 3 ""
omc_run aichat.select.local.model.selection.changed
check_status "the handler ran" 0
check "Load is disabled"    "0" "$(ui_enabled "$LM_LOAD_BUTTON_ID")"
check "Reveal is disabled"  "0" "$(ui_enabled "$LM_REVEAL_BUTTON_ID")"
check "Delete is disabled"  "0" "$(ui_enabled "$LM_DELETE_BUTTON_ID")"
check "Benchmark is disabled" "0" "$(ui_enabled "$LM_BENCH_BTN_ID")"
check "the pane prompts"    "Select a model from the list." "$(ui_value "$LM_INFO_TEXT_ID")"
check "  and is not markdown" "" "$(ui_content_type "$LM_INFO_TEXT_ID")"
check "no model is remembered" "" "$(cad_pb_get "aichatv2_selected_model_$OMC_ACTIONUI_WINDOW_UUID")"

section "selecting a gguf fills the pane"
cad_ui_reset
omc_table_cell "$LM_TABLE_ID" 3 "$MODELS/Tiny-Instruct-Q4_K_M.gguf"
omc_run aichat.select.local.model.selection.changed
check "Load is enabled"   "1" "$(ui_enabled "$LM_LOAD_BUTTON_ID")"
check "Reveal is enabled" "1" "$(ui_enabled "$LM_REVEAL_BUTTON_ID")"
check "Delete is enabled" "1" "$(ui_enabled "$LM_DELETE_BUTTON_ID")"
check "the pane is markdown" "markdown" "$(ui_content_type "$LM_INFO_TEXT_ID")"
info=$(ui_value "$LM_INFO_TEXT_ID")
check "it names the model"  "1" "$(cad_has "$info" "Tiny-Instruct-Q4_K_M")"
check "it names the engine" "1" "$(cad_has "$info" "GGUF (llama-server)")"
check "it names the source" "1" "$(cad_has "$info" "Downloaded")"
check "it shows the path"   "1" "$(cad_has "$info" "$MODELS/Tiny-Instruct-Q4_K_M.gguf")"
check "the selection is remembered" "$MODELS/Tiny-Instruct-Q4_K_M.gguf" \
    "$(cad_pb_get "aichatv2_selected_model_$OMC_ACTIONUI_WINDOW_UUID")"

section "the tools toggle follows the model, not the last model"
# It is WRITTEN on both branches rather than only when supported: leaving it alone would carry
# the previous row's answer onto a model that cannot use tools, which is how a toggle ends up
# claiming a capability the model does not have.
cad_ui_reset
omc_table_cell "$LM_TABLE_ID" 3 "$MODELS/mlx-tools"
omc_run aichat.select.local.model.selection.changed
check "a tool-capable model ticks it" "true" "$(ui_value "$LM_USE_TOOLS_TOGGLE_ID")"
check "  and the pane agrees"         "1" "$(cad_has "$(ui_value "$LM_INFO_TEXT_ID")" "Supported")"
cad_ui_reset
omc_table_cell "$LM_TABLE_ID" 3 "$MODELS/mlx-plain"
omc_run aichat.select.local.model.selection.changed
check "one without tools unticks it"  "false" "$(ui_value "$LM_USE_TOOLS_TOGGLE_ID")"
check "  and the pane says so"        "1" "$(cad_has "$(ui_value "$LM_INFO_TEXT_ID")" "Not detected")"

section "a listed model that has since been deleted offers nothing to delete"
cad_ui_reset
omc_table_cell "$LM_TABLE_ID" 3 "$MODELS/gone-since.gguf"
omc_run aichat.select.local.model.selection.changed
check "Load stays enabled"  "1" "$(ui_enabled "$LM_LOAD_BUTTON_ID")"
check "but Delete does not" "0" "$(ui_enabled "$LM_DELETE_BUTTON_ID")"
check "and the engine is unrecognised" "1" "$(cad_has "$(ui_value "$LM_INFO_TEXT_ID")" "Unrecognised")"

section "where a model came from is read off its path"
i=0
for pair in \
    ".cache/huggingface/hub/m.gguf|Hugging Face" \
    ".lmstudio/models/m.gguf|LM Studio" \
    ".ollama/models/m.gguf|Ollama" \
    ".localai/models/m.gguf|LocalAI" \
    "Library/Application Support/Jan/data/models/m.gguf|Jan" \
    "Library/Application Support/nomic.ai/GPT4All/m.gguf|GPT4All"; do
    rel=${pair%|*}; want=${pair#*|}
    p="$HOME/$rel"
    /bin/mkdir -p "$(/usr/bin/dirname "$p")"
    /usr/bin/head -c 512 /dev/zero > "$p"
    cad_ui_reset
    omc_table_cell "$LM_TABLE_ID" 3 "$p"
    omc_run aichat.select.local.model.selection.changed
    check "  $want" "1" "$(cad_has "$(ui_value "$LM_INFO_TEXT_ID")" "$want")"
    i=$((i + 1))
done
p="$OMCTEST_WORK/loose/m.gguf"
/bin/mkdir -p "$OMCTEST_WORK/loose"
/usr/bin/head -c 512 /dev/zero > "$p"
cad_ui_reset
omc_table_cell "$LM_TABLE_ID" 3 "$p"
omc_run aichat.select.local.model.selection.changed
check "  anything else is a local file" "1" "$(cad_has "$(ui_value "$LM_INFO_TEXT_ID")" "Local file")"

section "the benchmark button waits for a run in flight, but not forever"
now=$(/bin/date +%s)
cad_ui_reset
cad_pb_set "aichatv2_bench_running_$OMC_ACTIONUI_WINDOW_UUID" "$MODELS/mlx-plain|$now"
omc_table_cell "$LM_TABLE_ID" 3 "$MODELS/mlx-plain"
omc_run aichat.select.local.model.selection.changed
# The user-visible guarantee is that the button does not become CLICKABLE while a run is in
# flight - not that the handler takes any particular route to that. Two earlier forms of this
# check were both wrong in the same direction: expecting ui_enabled to be "" (its value for
# "never touched") and expecting cad_writes to be 0 each pin the applet's current silence, so
# each would turn red if someone made the handler disable the button explicitly, which is the
# obvious improvement. Asserting the state the user meets covers both routes and still fails
# for the only thing that matters - the button coming back to life mid-run.
check "a live run does not re-enable the button" "not enabled" "$(bench_btn_state)"
cad_ui_reset
cad_pb_set "aichatv2_bench_running_$OMC_ACTIONUI_WINDOW_UUID" "$MODELS/mlx-plain|$((now - 7300))"
omc_run aichat.select.local.model.selection.changed
check "a stale stamp is not believed" "enabled" "$(bench_btn_state)"
# A killed handler can leave a stamp that never parses. Treated as dead rather than as "now",
# which would disable the button until the window is closed.
cad_ui_reset
cad_pb_set "aichatv2_bench_running_$OMC_ACTIONUI_WINDOW_UUID" "$MODELS/mlx-plain|wedged"
omc_run aichat.select.local.model.selection.changed
check "a malformed stamp is treated as dead" "enabled" "$(bench_btn_state)"
cad_pb_set "aichatv2_bench_running_$OMC_ACTIONUI_WINDOW_UUID" ""

section "the on-device row offers nothing to reveal, delete or measure"
cad_ui_reset
omc_table_cell "$LM_TABLE_ID" 3 "$FOUNDATION"
omc_run aichat.select.local.model.selection.changed
check_status "the handler ran" 0
# Load stays live even when the model is unavailable: pressing it is how the user reaches the
# explanation and the Settings hop. A disabled button would state the problem and offer no way
# out of it.
check "Load stays enabled"     "1" "$(ui_enabled "$LM_LOAD_BUTTON_ID")"
check "Reveal is disabled"     "0" "$(ui_enabled "$LM_REVEAL_BUTTON_ID")"
check "Delete is disabled"     "0" "$(ui_enabled "$LM_DELETE_BUTTON_ID")"
check "Benchmark is disabled"  "0" "$(ui_enabled "$LM_BENCH_BTN_ID")"
# Tools OFF for this engine, though it supports them: every tool definition is spent from the
# same small window the conversation lives in.
check "tools start off"        "false" "$(ui_value "$LM_USE_TOOLS_TOGGLE_ID")"
info=$(ui_value "$LM_INFO_TEXT_ID")
check "the pane names the model" "1" "$(cad_has "$info" "Apple Foundation Models")"
check "  and its engine"         "1" "$(cad_has "$info" "Foundation Models (on device)")"
check "  and says there is nothing to download" "1" "$(cad_has "$info" "part of macOS")"
check "  and never sizes it in GB"              "0" "$(cad_has "$info" "GB")"
check "the benchmark pane explains itself"      "1" \
    "$(cad_has "$(ui_value "$LM_BENCH_TEXT_ID")" "nothing here to measure")"

section "cumulative: no handler wrote to a view id the window does not declare"
# cad_unknown_writes_all, not ui_unknown_writes: ui_reset DELETES unknown_ids.log along with
# the windows, so the plain form covers only what happened since the last reset - which in a
# file that resets per section is close to nothing. Measured: a handler scribbling on a
# made-up view id went entirely unnoticed by the plain form.
check "no undeclared ids" "" "$(cad_unknown_writes_all)"
check "no table clobbered by a bare value write" "" "$(cad_suspect_writes_all)"

omctest_end
