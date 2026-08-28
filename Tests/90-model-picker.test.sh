#!/bin/sh
# Tests/90-model-picker.test.sh - the local model list and its info pane.
#
# Every scan root this window walks is under $HOME, which is what makes the list assertable at
# all: the harness gives each test file its own home, so "these are the models on this Mac" is
# a fact the test writes rather than one it has to tolerate.
#
# Recently-opened models used to be the one gap: they came from `defaults read
# com.abracode.Cadabra`, and cfprefsd keys the user domain by uid rather than by $HOME, so the
# developer's real recents were read here and could add rows that no fixture put there. They
# live in the app's own settings file now, which the isolated home does cover, so they are
# asserted below like everything else. Row counts are still stated per path rather than as a
# total, which is the honest shape for a list assembled from a disk scan.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.cadabra.sh"

cad_import_ids aichat.select.local.model.selection.changed.sh LM_
FOUNDATION="foundation:apple-on-device"
MODELS="$HOME/Library/Application Support/Cadabra/Models"

# row_for <path> -> the picker row whose hidden path column matches, tab separated.
#
# Five values per row against four drawn columns: format icon, name, tools icon, size, path.
# Picking a row BY its path is therefore also an assertion that the hidden column is still
# where the ok / reveal / delete / benchmark / selection.changed handlers read it from.
row_for() { ui_rows "$LM_TABLE_ID" | /usr/bin/awk -F'\t' -v p="$1" '$5 == p { print; exit }'; }
# field <path> <column> -> 1 format icon, 2 name, 3 tools icon, 4 size, 5 path.
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

section "whether this Mac has any model at all - the question launch asks"
# Launch opens the Hugging Face browser instead of this picker when the answer is no
# (Cadabra.main.sh), so a wrong answer here is a wrong window: a false yes opens a picker with
# nothing in it, a false no sends a user who has models to a download browser they did not ask
# for. Asserted FIRST, while the isolated home really is empty - every later section in this
# file puts a model in one of the scanned roots, and after that the negative case is gone.
#
# Each case cleans up after itself: a fixture left behind would become an extra row in the
# picker assertions below, which count them.
check "a Mac with nothing installed reports none" "1" \
    "$(cad_model_call model_any_installed; echo $?)"

/bin/mkdir -p "$MODELS"
/usr/bin/head -c 1024 /dev/zero > "$MODELS/Probe-Q4_K_M.gguf"
check "one downloaded gguf is enough"             "0" \
    "$(cad_model_call model_any_installed; echo $?)"
/bin/rm -f "$MODELS/Probe-Q4_K_M.gguf"

mk_mlx "$MODELS/probe-mlx" 1024
check "and so is one mlx directory"               "0" \
    "$(cad_model_call model_any_installed; echo $?)"
/bin/rm -rf "$MODELS/probe-mlx"

# The same trap model_engine exists for: an HF snapshot dir of a GGUF repo carries a
# config.json, so "there is a config.json under a root" is not the question being asked.
/bin/mkdir -p "$MODELS/probe-notamodel"
echo '{}' > "$MODELS/probe-notamodel/config.json"
check "a config.json with no weights beside it is not a model" "1" \
    "$(cad_model_call model_any_installed; echo $?)"
/bin/rm -rf "$MODELS/probe-notamodel"

# Recents are the only trace of a model living outside every scanned root, so the launch check
# has to read them for the same reason the list does - otherwise a user whose only model sits on
# their Desktop is told they have none.
PROBE_OUTSIDE="$HOME/Desktop/Probe-Outside-Q4_K_M.gguf"
/bin/mkdir -p "$HOME/Desktop"
/usr/bin/head -c 1024 /dev/zero > "$PROBE_OUTSIDE"
check "a model outside the roots is invisible until it is remembered" "1" \
    "$(cad_model_call model_any_installed; echo $?)"
cad_model_call model_recents_add "$PROBE_OUTSIDE"
check "  and counts once it is"                    "0" \
    "$(cad_model_call model_any_installed; echo $?)"
# A remembered path that is no longer on disk is not a model either - recents outlive files.
/bin/rm -f "$PROBE_OUTSIDE"
check "  but not after the file is gone"           "1" \
    "$(cad_model_call model_any_installed; echo $?)"

# The on-device model is on every eligible Mac and needs no download, so counting it would mean
# the first-run browser never opened on the machines the whole branch was written for.
cad_model_call model_recents_add "$FOUNDATION"
check "the on-device model does not count as installed" "1" \
    "$(cad_model_call model_any_installed; echo $?)"
cad_reset

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
ui_reset
omc_run aichat.select.local.model.init
check_status "init ran" 0
# The two icon columns are headerless on purpose - a marker column with a title reads as data.
# Asserted as four columns rather than as two, because a header list that silently loses one
# is how the row values and the columns drift apart.
check "the table draws two headerless columns around Model and Size" "
Model

Size" "$(ui_columns "$LM_TABLE_ID")"
check "the gguf is listed"     "1" "$([ -n "$(row_for "$MODELS/Tiny-Instruct-Q4_K_M.gguf")" ] && echo 1 || echo 0)"
check "the mlx model is listed" "1" "$([ -n "$(row_for "$MODELS/mlx-tools")" ] && echo 1 || echo 0)"
# The format and the tool loop are marked in their own columns, and the name is only the name.
# Both icons are SF Symbol names the table's Image columns resolve; a name that resolves to
# nothing draws nothing, which is what the empty tools cell relies on.
check "a gguf is marked in the format column" "g.square" \
    "$(field "$MODELS/Tiny-Instruct-Q4_K_M.gguf" 1)"
check "  its name carries no badge"           "Tiny-Instruct-Q4_K_M" \
    "$(field "$MODELS/Tiny-Instruct-Q4_K_M.gguf" 2)"
check "  and sized"                           "0.0 GB" \
    "$(field "$MODELS/Tiny-Instruct-Q4_K_M.gguf" 4)"
check "an mlx model is marked mlx"            "m.square" "$(field "$MODELS/mlx-tools" 1)"
check "  with a clean name"                   "mlx-tools" "$(field "$MODELS/mlx-tools" 2)"
check "  and a tools marker"                  "hammer"   "$(field "$MODELS/mlx-tools" 3)"
# Anchored on the WHOLE row rather than on field 3. field() returns "" for a row it cannot
# find, which is the value this check wants - so on its own it would go green for a picker
# that dropped the row, or shifted its fields, which is the one thing this file exists to
# catch. Spelling the row out pins the empty cell AND its position among the other four.
check "one without tools gets an empty cell" \
    "$(printf 'm.square\tmlx-plain\t\t0.0 GB\t%s' "$MODELS/mlx-plain")" \
    "$(row_for "$MODELS/mlx-plain")"

section "a directory that only looks like a model is not listed"
# config.json with no shards is an HF snapshot of a GGUF repo. The picker scans FOR config.json,
# so this is the case where the scan and model_engine must agree, and the scan defers.
/bin/mkdir -p "$MODELS/not-a-model"
echo '{}' > "$MODELS/not-a-model/config.json"
ui_reset
omc_run aichat.select.local.model.init
check "a config with no shards is skipped" "" "$(row_for "$MODELS/not-a-model")"

section "a shard set with a hole in it is not listed either"
# The other half of the same rule, and the one that used to get through. A multi-shard model
# whose download stopped partway leaves config.json beside SOME of its shards, and "there is a
# safetensors in here" - all model_engine used to ask - cannot tell that from a whole model. The
# picker listed the wreckage, put a size next to it, and handed it to a loader that could only
# fail. See mlx_shards_complete.
INDEX_TWO='{"weight_map": {"a": "model-00001-of-00002.safetensors", "b": "model-00002-of-00002.safetensors"}}'
/bin/mkdir -p "$MODELS/mlx-halfshard"
echo '{}' > "$MODELS/mlx-halfshard/config.json"
printf '%s' "$INDEX_TWO" > "$MODELS/mlx-halfshard/model.safetensors.index.json"
/usr/bin/head -c 4096 /dev/zero > "$MODELS/mlx-halfshard/model-00001-of-00002.safetensors"
ui_reset
omc_run aichat.select.local.model.init
check "a model missing a shard its index names is skipped" "" "$(row_for "$MODELS/mlx-halfshard")"
check "  and model_engine agrees it is not one"           "" \
    "$(cad_model_call model_engine "$MODELS/mlx-halfshard")"
# The positive control, in the same fixture: the ONLY thing wrong with it was the missing shard.
/usr/bin/head -c 4096 /dev/zero > "$MODELS/mlx-halfshard/model-00002-of-00002.safetensors"
ui_reset
omc_run aichat.select.local.model.init
check "the last shard arriving is what makes it a model" "mlx" \
    "$(cad_model_call model_engine "$MODELS/mlx-halfshard")"
check "  and the picker lists it"                        "1" \
    "$([ -n "$(row_for "$MODELS/mlx-halfshard")" ] && echo 1 || echo 0)"
# An index that names nothing is a broken index, not a license to accept whatever is lying
# about - which is what falling back to the no-index rule would have meant.
/bin/mkdir -p "$MODELS/mlx-emptyindex"
echo '{}' > "$MODELS/mlx-emptyindex/config.json"
echo '{"weight_map": {}}' > "$MODELS/mlx-emptyindex/model.safetensors.index.json"
/usr/bin/head -c 4096 /dev/zero > "$MODELS/mlx-emptyindex/model.safetensors"
check "an index naming no shards is not trusted" "" \
    "$(cad_model_call model_engine "$MODELS/mlx-emptyindex")"
# And the case that has nothing to be incomplete AGAINST keeps the old, looser rule: a repo that
# ships one weights file and no index is a whole model, and every mlx fixture above is one.
check "a single-file model with no index is still a model" "mlx" \
    "$(cad_model_call model_engine "$MODELS/mlx-bare")"

section "the same file under two roots is two rows, because dedup is by path"
# Stated as what it IS rather than as "listed once", which is what this fixture looked like it
# was testing and is not. add_row dedupes on the path STRING, and two roots reaching one file
# through a symlink yield two different strings - so both are listed, and that is the designed
# behavior rather than a bug being pinned.
#
# The case the dedup actually exists for - a recents entry naming a model the scan already found
# - is covered in "a model opened from outside the caches" below. It was unreachable while
# recents lived in a preferences domain.
/bin/mkdir -p "$HOME/.lmstudio/models"
/bin/ln -sfn "$MODELS/Tiny-Instruct-Q4_K_M.gguf" "$HOME/.lmstudio/models/Tiny-Instruct-Q4_K_M.gguf"
ui_reset
omc_run aichat.select.local.model.init
check "the original path appears exactly once" "1" \
    "$(ui_rows "$LM_TABLE_ID" | /usr/bin/awk -F'\t' -v p="$MODELS/Tiny-Instruct-Q4_K_M.gguf" '$5 == p' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
check "  and the symlinked root adds its own row" "1" \
    "$([ -n "$(row_for "$HOME/.lmstudio/models/Tiny-Instruct-Q4_K_M.gguf")" ] && echo 1 || echo 0)"
check "  which the picker sizes identically"      "0.0 GB" \
    "$(field "$HOME/.lmstudio/models/Tiny-Instruct-Q4_K_M.gguf" 4)"

section "the on-device model heads the list, and is never sized"
# Its availability depends on the machine, so what is asserted is the SHAPE: at most one row,
# first when present, carrying the sentinel and the word "system" rather than a measurement.
# Written as IMPLICATIONS rather than as an if/else, for two reasons. A branch taken only when
# the row is absent, whose single check re-tests the very condition that selected it, cannot
# fail. And a file whose check COUNT depends on the host makes "690 passed" unverifiable - this
# way the same five run on every Mac, and each is a real claim on both branches.
fnd=$(ui_rows "$LM_TABLE_ID" | /usr/bin/awk -F'\t' -v s="$FOUNDATION" '$5 == s')
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
    "$([ -z "$fnd" ] && echo 1 || { [ "$(printf '%s' "$fnd" | /usr/bin/cut -f4)" = "system" ] && echo 1 || echo 0; })"
check "never sized in GB"     "0" "$(cad_has "$(printf '%s' "$fnd" | /usr/bin/cut -f4)" "GB")"
# Its engine is named by the same column as everyone else's rather than by a suffix on the
# name, which is what leaves the name free to say WHY the row is unusable when it is.
check "if present, marked with the Apple mark" "1" \
    "$([ -z "$fnd" ] && echo 1 || { [ "$(printf '%s' "$fnd" | /usr/bin/cut -f1)" = "apple.logo" ] && echo 1 || echo 0; })"
check "  and never tool-marked"                "1" \
    "$([ -z "$fnd" ] && echo 1 || { [ "$(printf '%s' "$fnd" | /usr/bin/cut -f3)" = "" ] && echo 1 || echo 0; })"

section "with nothing selected the pane says so and everything is disabled"
ui_reset
omc_table_cell "$LM_TABLE_ID" 5 ""
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
ui_reset
omc_table_cell "$LM_TABLE_ID" 5 "$MODELS/Tiny-Instruct-Q4_K_M.gguf"
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
ui_reset
omc_table_cell "$LM_TABLE_ID" 5 "$MODELS/mlx-tools"
omc_run aichat.select.local.model.selection.changed
check "a tool-capable model ticks it" "true" "$(ui_value "$LM_USE_TOOLS_TOGGLE_ID")"
check "  and the pane agrees"         "1" "$(cad_has "$(ui_value "$LM_INFO_TEXT_ID")" "Supported")"
ui_reset
omc_table_cell "$LM_TABLE_ID" 5 "$MODELS/mlx-plain"
omc_run aichat.select.local.model.selection.changed
check "one without tools unticks it"  "false" "$(ui_value "$LM_USE_TOOLS_TOGGLE_ID")"
check "  and the pane says so"        "1" "$(cad_has "$(ui_value "$LM_INFO_TEXT_ID")" "Not detected")"

section "a listed model that has since been deleted offers nothing to delete"
ui_reset
omc_table_cell "$LM_TABLE_ID" 5 "$MODELS/gone-since.gguf"
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
    ui_reset
    omc_table_cell "$LM_TABLE_ID" 5 "$p"
    omc_run aichat.select.local.model.selection.changed
    check "  $want" "1" "$(cad_has "$(ui_value "$LM_INFO_TEXT_ID")" "$want")"
    i=$((i + 1))
done
p="$OMCTEST_WORK/loose/m.gguf"
/bin/mkdir -p "$OMCTEST_WORK/loose"
/usr/bin/head -c 512 /dev/zero > "$p"
ui_reset
omc_table_cell "$LM_TABLE_ID" 5 "$p"
omc_run aichat.select.local.model.selection.changed
check "  anything else is a local file" "1" "$(cad_has "$(ui_value "$LM_INFO_TEXT_ID")" "Local file")"

section "the benchmark button waits for a run in flight, but not forever"
now=$(/bin/date +%s)
ui_reset
cad_pb_set "aichatv2_bench_running_$OMC_ACTIONUI_WINDOW_UUID" "$MODELS/mlx-plain|$now"
omc_table_cell "$LM_TABLE_ID" 5 "$MODELS/mlx-plain"
omc_run aichat.select.local.model.selection.changed
# The user-visible guarantee is that the button does not become CLICKABLE while a run is in
# flight - not that the handler takes any particular route to that. Two earlier forms of this
# check were both wrong in the same direction: expecting ui_enabled to be "" (its value for
# "never touched") and expecting cad_writes to be 0 each pin the applet's current silence, so
# each would turn red if someone made the handler disable the button explicitly, which is the
# obvious improvement. Asserting the state the user meets covers both routes and still fails
# for the only thing that matters - the button coming back to life mid-run.
check "a live run does not re-enable the button" "not enabled" "$(bench_btn_state)"
ui_reset
cad_pb_set "aichatv2_bench_running_$OMC_ACTIONUI_WINDOW_UUID" "$MODELS/mlx-plain|$((now - 7300))"
omc_run aichat.select.local.model.selection.changed
check "a stale stamp is not believed" "enabled" "$(bench_btn_state)"
# A killed handler can leave a stamp that never parses. Treated as dead rather than as "now",
# which would disable the button until the window is closed.
ui_reset
cad_pb_set "aichatv2_bench_running_$OMC_ACTIONUI_WINDOW_UUID" "$MODELS/mlx-plain|wedged"
omc_run aichat.select.local.model.selection.changed
check "a malformed stamp is treated as dead" "enabled" "$(bench_btn_state)"
cad_pb_set "aichatv2_bench_running_$OMC_ACTIONUI_WINDOW_UUID" ""

section "the on-device row offers nothing to reveal, delete or measure"
ui_reset
omc_table_cell "$LM_TABLE_ID" 5 "$FOUNDATION"
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

section "a model opened from outside the caches is the only thing recents are for"
# A model the user opened from their Desktop is in none of the scanned roots, so this list is
# the ONLY reason it appears in the picker at all. Lose it and the model silently drops out of
# the UI while sitting exactly where the user put it.
cad_reset
OUTSIDE="$HOME/Desktop/Elsewhere-Q4_K_M.gguf"
/bin/mkdir -p "$HOME/Desktop"
/usr/bin/head -c 4096 /dev/zero > "$OUTSIDE"
ui_reset
omc_run aichat.select.local.model.init
check "an unremembered outside model is not listed" "0" \
    "$([ -n "$(row_for "$OUTSIDE")" ] && echo 1 || echo 0)"
cad_model_call model_recents_add "$OUTSIDE"
ui_reset
omc_run aichat.select.local.model.init
check "once remembered it appears"                  "1" \
    "$([ -n "$(row_for "$OUTSIDE")" ] && echo 1 || echo 0)"
# The dedup this list needs: a recents entry naming a model the scan already found must not
# produce a second row for it.
cad_model_call model_recents_add "$MODELS/Tiny-Instruct-Q4_K_M.gguf"
ui_reset
omc_run aichat.select.local.model.init
check "a recent the scan already found is listed once" "1" \
    "$(ui_rows "$LM_TABLE_ID" | /usr/bin/awk -F'\t' -v p="$MODELS/Tiny-Instruct-Q4_K_M.gguf" '$5 == p' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"

section "the recents list is newest first, deduplicated and bounded"
cad_reset
cad_model_call model_recents_add /tmp/a.gguf
cad_model_call model_recents_add /tmp/b.gguf
check "the newest is first"        "/tmp/b.gguf
/tmp/a.gguf" "$(cad_model_call model_recents_list)"
cad_model_call model_recents_add /tmp/a.gguf
check "re-adding moves, not duplicates" "/tmp/a.gguf
/tmp/b.gguf" "$(cad_model_call model_recents_list)"
# The cap is what stops a list that only ever grows. Twelve in, ten out, and the two oldest are
# the ones gone.
cad_reset
i=1
while [ "$i" -le 12 ]; do cad_model_call model_recents_add "/tmp/m$i.gguf"; i=$((i + 1)); done
check "the list is capped"          "10" "$(cad_model_call model_recents_list | /usr/bin/grep -c .)"
check "  keeping the newest"        "/tmp/m12.gguf" "$(cad_model_call model_recents_list | /usr/bin/head -n 1)"
check "  and dropping the oldest"   "0" \
    "$(cad_model_call model_recents_list | /usr/bin/grep -c '^/tmp/m1\.gguf$')"

section "asking for the recents does not create them"
# A read path that writes is how merely opening a window ends up creating the settings file -
# and how "did this handler save anything" stops being answerable at all.
cad_reset
check "the settings file is gone"     "0" "$([ -f "$cad_settings" ] && echo 1 || echo 0)"
check "reading gives nothing"         ""  "$(cad_model_call model_recents_list)"
check "  and created no file"         "0" "$([ -f "$cad_settings" ] && echo 1 || echo 0)"

section "a path containing a newline survives being remembered"
# macOS permits newlines in filenames, and the list is read back one-per-line. A round trip
# through that text would turn one model into two bogus entries AND lose the real one, so it
# would vanish from the picker while sitting on disk. Asserted on the COUNT, because the
# textual list cannot represent the answer.
cad_reset
NL_PATH="$(printf '/tmp/two\nline.gguf')"
cad_model_call model_recents_add "$NL_PATH"
cad_model_call model_recents_add /tmp/plain.gguf
check "two models are two entries" "2" "$(cad_count /recent-models)"
# And dedup still recognizes it, which a split entry could not.
cad_model_call model_recents_add "$NL_PATH"
check "  and re-adding it does not duplicate" "2" "$(cad_count /recent-models)"

section "recents share the settings file rather than owning it"
# Three subtrees, three owners, one file. The list is rewritten whole on every add, so it is
# the one most able to take somebody else's settings with it.
cad_reset
cad_call acp_agent_store custom:1 "/bin/echo acp" >/dev/null 2>&1
cad_call mcp_prefs_write_defaults >/dev/null 2>&1
check "the MCP subtree exists first"  "dict" "$(cad_type /servers)"
check "  and the agents subtree too"  "true" "$("$cad_plister" get value "$cad_settings" /agents/external/enabled 2>/dev/null)"
cad_model_call model_recents_add /tmp/z.gguf
check "adding a recent leaves /servers" "dict" "$(cad_type /servers)"
check "  and leaves /agents"            "true" "$("$cad_plister" get value "$cad_settings" /agents/external/enabled 2>/dev/null)"
check "  while storing its own"         "/tmp/z.gguf" "$(cad_model_call model_recents_list)"

section "cumulative: no handler wrote to a view id the window does not declare"
# Cumulative across the whole file, which is what makes one check at the end meaningful.
# It was not always: ui_reset used to DELETE unknown_ids.log along with the windows, so this
# covered only what happened since the last reset - close to nothing in a file that resets per
# section, and a handler scribbling on a made-up view id went entirely unnoticed. omctest API 4
# carries the three diagnostic logs across a reset, and this lib asserts that minimum.
check "no undeclared ids" "" "$(ui_unknown_writes)"
check "no table clobbered by a bare value write" "" "$(ui_suspect_writes)"

omctest_end
