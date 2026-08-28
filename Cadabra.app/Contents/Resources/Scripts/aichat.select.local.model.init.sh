#!/bin/bash
# aichat.select.local.model.init.sh
# Discovers local models of BOTH engines and populates the model selector table.
#
# The two engines have different shapes on disk - GGUF is a single *.gguf FILE, MLX is a
# DIRECTORY of *.safetensors shards + config.json - so discovery runs twice per root and
# both kinds land in ONE list. Which engine a row will use is not a user setting; it is
# implied by what the model IS (model_engine, in the model library), so the format column
# reports that decision rather than offering it.
#
# ── COLUMN ORDER ──────────────────────────────────────────────────────────────
# Four visible columns - format icon, Model, tools icon, Size - plus a fifth the table never
# draws, holding the model's path.
#
# The order is stated in exactly TWO places that must agree: the "columns" / "columnTypes" /
# "widths" / "minWidths" arrays in Base.lproj/aichat.select.local.model.json, and the
# set_columns call plus the emit printf in this file. Reordering or renaming a VISIBLE column
# is a change to those two and nothing else.
#
# Widths are the JSON's alone, and are worth a note: a column is drawn about 17pt wider than
# the number given (cell insets), and a table whose columns total more than the sidebar
# SCROLLS SIDEWAYS rather than compressing them. 22 + 220 + 22 + 60, plus four lots of 17,
# is what fits the 400pt sidebar without a horizontal scroller. Model is the widest, which is
# what makes it the column that absorbs the slack when the split is dragged wider.
#
# What is NOT free is changing how MANY columns there are. The path column is read back by
# five sibling scripts (ok / reveal / delete / benchmark / selection.changed) as
# OMC_ACTIONUI_TABLE_10_COLUMN_5_VALUE - an index that only moves when a column is added or
# removed, not when they are shuffled. All five, and the tests, are the sweep.
#
# Command.json is NOT that inventory, though two of the five (reveal, benchmark) do name the
# variable in ENVIRONMENT_VARIABLES. It is not needed: a multi-column table's cells are
# exported for every column of the selected row whether or not anything declared them
# (AddEnvironmentVariablesForAllControls, called unconditionally after the declared-variable
# loop), which is why the other three have always worked without a declaration. Update the two
# for tidiness, but do not read them as the list of scripts to fix.
#
# The path stays LAST because that is the only way ActionUI hides a column: a row may carry
# more values than there are columns, and the surplus is simply not drawn. (omc_hidden_column
# is the NIB tables' marker; ActionUI's Table does not implement it.)

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"

TABLE_ID=10
dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

# ── ROW ICONS ─────────────────────────────────────────────────────────────────
# SF Symbol names, drawn by the table's two Image columns (columnTypes in the dialog JSON).
#
# Monograms rather than pictograms: MLX and GGUF are new enough formats that no system image
# means either of them, so any pictogram would need a legend the window has nowhere to put,
# while a letter is read the same way the badges it replaces were. They render in ONE tint -
# a Table's foregroundStyle applies to the whole view, so per-row color would need real image
# files (swap dataInterpretation to "resourceName" and name a file in Resources).
ICON_MLX="m.square"
ICON_GGUF="g.square"
ICON_FOUNDATION="apple.logo"
# The tools marker, in its own column rather than suffixed to the name - and an SF Symbol
# rather than the U+1F528 emoji it replaces, so it sits on the text baseline at the weight of
# everything else instead of dragging a color glyph into the list.
ICON_TOOLS="hammer"
# Deliberately empty for a model that cannot drive the tool loop: an unresolvable symbol name
# renders as nothing at all (verified: zero-size, no placeholder), which is exactly what a
# marker column should show when there is nothing to mark.
ICON_NO_TOOLS=""

# Take ownership of an arm from a chat window's model bar, moving it out of the global key and
# into this selector's own scope - see model_switch_capture. A no-op when the selector was
# opened from the menu with nothing armed.
model_switch_capture "$window_uuid"

# The headers are restated here, and only the headers: the widths live in the dialog JSON
# alone. They used to be set here too, at numbers that had drifted away from the ones the JSON
# declared - and since this call is the later of the two, the JSON's were the ones nobody was
# reading. One source per fact instead.
#
# The two icon columns are headerless on purpose; a marker column with a title reads as data.
"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_set_columns "" "Model" "" "Size"
"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_remove_all_rows

# emit_model_row <path> [engine] -> the TSV row "<format icon> \t name \t <tools icon> \t
# N.N GB \t path", or nothing if the path is not a loadable model of either engine. The tools
# icon marks a model whose chat template can drive the MCP tool loop; the same helper answers
# for the info pane, so the list and the pane can never disagree.
#
# The name is the SHORT label - "Qwen3-8B-4bit", not "mlx-community/Qwen3-8B-4bit" - see
# model_short_label for why the publisher prefix is dropped here and nowhere else.
emit_model_row() {
	local path="$1"
	local engine="${2:-$(model_engine "$path")}"
	[ -n "$engine" ] || return 0
	# The on-device model has its own emitter (add_foundation_row): no size to format, and a
	# name that depends on availability. Refused here so a sentinel arriving from an unexpected
	# source - a recents entry written by an older build - cannot produce a "0.0 GB" row.
	[ "$engine" = "foundation" ] && return 0

	local name icon tools bytes size
	name="$(model_short_label "$path")"
	case "$engine" in
		gguf) icon="$ICON_GGUF" ;;
		mlx)  icon="$ICON_MLX" ;;
		*)    icon="" ;;
	esac
	if model_supports_tools "$path" "$engine"; then
		tools="$ICON_TOOLS"
	else
		tools="$ICON_NO_TOOLS"
	fi

	bytes="$(model_bytes "$path" "$engine")"
	size=$(printf "%.1f GB" "$(echo "scale=4; $bytes / (1024*1024*1024)" | /usr/bin/bc -l 2>/dev/null)")
	printf '%s\t%s\t%s\t%s\t%s\n' "$icon" "$name" "$tools" "$size" "$path"
}

# ── Apple Foundation Models ───────────────────────────────────────────────────
# Listed FIRST, and listed even when it is not usable right now.
#
# First because it is the only row that needs no download: on a Mac with nothing installed
# yet, every other row is absent and this one is the whole answer to "can I chat at all".
#
# Listed while unavailable because the two states a user can act on - Apple Intelligence
# switched off, assets still downloading - are invisible from here. Hiding the row would
# hide the feature AND the remedy, leaving nothing to discover and nothing to click. The
# row says which state it is in; picking it explains and offers the fix (see the ok handler).
# It is omitted only when this Mac is KNOWN never to support it - which is not the same as "not
# usable now": a reason this build does not recognize is listed too, because a newer macOS can
# add states and reading ignorance as "never" would retire the feature on the systems that just
# gained one.
#
# The size column reads "system" rather than a number: these weights are not ours, are not
# on our disk, and are not counted against the RAM budget that column exists to convey.
# Formatting 0 bytes as "0.0 GB" would put a measurement there that means nothing.
add_foundation_row() {
	local probe reason summary name row
	probe=$(foundation_probe)
	reason=$(printf '%s' "$probe" | /usr/bin/cut -f1)
	summary=$(printf '%s' "$probe" | /usr/bin/cut -f2)
	echo "foundation: reason=$reason ($summary)"

	# Claimed BEFORE the offerable test, not after: a machine that cannot run this engine must
	# also not list it via a stale recents entry, and recents are appended after the scan by a
	# path that only consults `seen`.
	seen="${seen}[$FOUNDATION_MODEL_ID]"

	foundation_offerable "$reason" || return 0

	# The [Apple] suffix is gone with the other two: the format column says which engine this
	# is, and it says it in the same place on every row. What stays in the name is the part no
	# icon can carry - WHY the row is not usable right now.
	name="$(model_short_label "$FOUNDATION_MODEL_ID")"
	case "$reason" in
		# No tools icon, though the engine supports them. On every other row it has come to
		# mean "tools will be on for this model" - it is what auto-ticks the toggle - and this
		# row deliberately starts with tools OFF (a very small window; see the info pane).
		# Marking it would have the list promise what the pane immediately withdraws.
		available)            ;;
		appleIntelligenceOff) name="${name} - Apple Intelligence off" ;;
		modelNotReady)        name="${name} - still downloading" ;;
		timedOut)             name="${name} - not responding" ;;
		probeFailed)          name="${name} - check failed" ;;
		*)                    name="${name} - unavailable" ;;
	esac

	row=$(printf '%s\t%s\t%s\t%s\t%s' \
		"$ICON_FOUNDATION" "$name" "$ICON_NO_TOOLS" "system" "$FOUNDATION_MODEL_ID")
	buffer="${buffer}${row}
"
}

buffer=""
seen=""

# add_row <path> [engine] - dedup by path, then append. A model reachable through two roots
# (or listed as recent AND found in a cache) must appear once.
add_row() {
	local path="$1"
	case "$seen" in *"[$path]"*) return 0 ;; esac
	seen="${seen}[$path]"
	local row
	row=$(emit_model_row "$path" "$2")
	[ -n "$row" ] && buffer="${buffer}${row}
"
}

# Before the disk scan, so it heads the list. It also claims its sentinel in `seen`, which
# keeps a stale recents entry from producing a second copy of the row.
add_foundation_row

# Roots are scanned for BOTH engines, and the list of them lives in the model library
# (model_scan_roots) rather than here: launch reads the same list to decide whether this window
# is worth opening at all, and a root only one of the two knows about is a silent disagreement
# about what "no models installed" means.
while IFS= read -r root; do
	[ -d "$root" ] || continue

	# GGUF: the file IS the model.
	while IFS= read -r gguf_path; do
		[ -n "$gguf_path" ] || continue
		add_row "$gguf_path" gguf
	done <<< "$(/usr/bin/find -L "$root" -name "*.gguf" -type f 2>/dev/null | /usr/bin/sort)"

	# MLX: the model is the directory holding config.json, and model_engine decides whether it
	# actually is one (config.json alone is not enough - a GGUF snapshot dir carries one too).
	#
	# Scan for config.json rather than for shards, so the picker and model_engine agree on
	# what a model IS. model_engine accepts shards nested one level BELOW config.json, but
	# dirname(shard) would then offer the shard's subdirectory - which model_engine rejects,
	# because config.json is not in it. The one layout the helpers went out of their way to
	# support would have been the one layout the picker could never list.
	# -maxdepth 5 covers the deepest real case: <root>/models--<org>--<name>/snapshots/<hash>/
	# config.json is 4 below the HF hub root.
	while IFS= read -r mlx_dir; do
		[ -n "$mlx_dir" ] || continue
		add_row "$mlx_dir" ""
	done <<< "$(/usr/bin/find -L "$root" -maxdepth 5 -name "config.json" -type f 2>/dev/null \
		| while IFS= read -r c; do /usr/bin/dirname "$c"; done | /usr/bin/sort -u)"
done <<< "$(model_scan_roots)"

# Append recently opened models not already discovered. Recents are paths the user opened
# from outside the standard caches, so they are the only way those models are listed at all.
# No -f/-d test here: model_engine already answers "is this still a loadable model", and it
# is the one that knows a GGUF is a file while an MLX model is a directory.
recent_paths=$(model_recents_list)
while IFS= read -r recent_path; do
	[ -n "$recent_path" ] || continue
	add_row "$recent_path" ""
done <<< "$recent_paths"

if [ -n "$buffer" ]; then
	printf "%s" "$buffer" | "$dialog_tool" "$window_uuid" $TABLE_ID omc_table_set_rows_from_stdin
fi
