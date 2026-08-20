#!/bin/bash
# aichat.select.local.model.init.sh
# Discovers local models of BOTH engines and populates the model selector table.
#
# The two engines have different shapes on disk - GGUF is a single *.gguf FILE, MLX is a
# DIRECTORY of *.safetensors shards + config.json - so discovery runs twice per root and
# both kinds land in ONE list. Which engine a row will use is not a user setting; it is
# implied by what the model IS (model_engine, in the model library), so the badge reports
# that decision rather than offering it.
#
# Badges live in the Model name rather than in their own columns on purpose: the table's
# hidden path is column 3, and four sibling scripts read it as
# OMC_ACTIONUI_TABLE_10_COLUMN_3_VALUE (ok / reveal / delete / selection.changed). Adding a
# visible column would shift that index in all of them plus the dialog JSON, for a purely
# cosmetic gain. The tools badge already sets the precedent of a name suffix.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.model.library.sh"

TABLE_ID=10
dialog_tool="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"

# Take ownership of an arm from a chat window's model bar, moving it out of the global key and
# into this selector's own scope - see model_switch_capture. A no-op when the selector was
# opened from the menu with nothing armed.
model_switch_capture "$window_uuid"

# Column 3 (path) is hidden - rows carry 3 tab-separated values but only 2 headers exist.
"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_set_columns "Model" "Size"
"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_set_column_widths 390 70
"$dialog_tool" "$window_uuid" $TABLE_ID omc_table_remove_all_rows

# emit_model_row <path> [engine] -> TSV "name [ENGINE] 🔨 \t N.N GB \t path", or nothing if
# the path is not a loadable model of either engine. The hammer marks a model whose chat
# template can drive the MCP tool loop; the same helper answers for the info pane, so the
# list and the pane can never disagree.
emit_model_row() {
	local path="$1"
	local engine="${2:-$(model_engine "$path")}"
	[ -n "$engine" ] || return 0
	# The on-device model has its own emitter (add_foundation_row): no size to format, and a
	# name that depends on availability. Refused here so a sentinel arriving from an unexpected
	# source - a recents entry written by an older build - cannot produce a "0.0 GB" row.
	[ "$engine" = "foundation" ] && return 0

	local name bytes size
	name="$(model_display_label "$path")"
	case "$engine" in
		gguf) name="${name} [GGUF]" ;;
		mlx)  name="${name} [MLX]" ;;
	esac
	model_supports_tools "$path" "$engine" && name="${name} 🔨"

	bytes="$(model_bytes "$path" "$engine")"
	size=$(printf "%.1f GB" "$(echo "scale=4; $bytes / (1024*1024*1024)" | /usr/bin/bc -l 2>/dev/null)")
	printf '%s\t%s\t%s\n' "$name" "$size" "$path"
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

	name="$(model_display_label "$FOUNDATION_MODEL_ID") [Apple]"
	case "$reason" in
		# No tools badge, though the engine supports them. On every other row the hammer has
		# come to mean "tools will be on for this model" - it is what auto-ticks the toggle -
		# and this row deliberately starts with tools OFF (a very small window; see the info
		# pane). Badging it would have the list promise what the pane immediately withdraws.
		available)            ;;
		appleIntelligenceOff) name="${name} - Apple Intelligence off" ;;
		modelNotReady)        name="${name} - still downloading" ;;
		timedOut)             name="${name} - not responding" ;;
		probeFailed)          name="${name} - check failed" ;;
		*)                    name="${name} - unavailable" ;;
	esac

	row=$(printf '%s\t%s\t%s' "$name" "system" "$FOUNDATION_MODEL_ID")
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

# Roots are scanned for BOTH engines. The HF cache and LM Studio genuinely hold each kind
# (LM Studio ships an MLX runtime), so neither can be assumed single-engine. The Ollama /
# LocalAI / Jan / GPT4All caches are GGUF-only in practice; scanning them for safetensors
# costs one find that returns nothing, which is cheaper than maintaining two root lists
# that would drift.
for root in \
	"$HOME/Library/Application Support/Cadabra/Models" \
	"$HOME/.cache/huggingface/hub" \
	"$HOME/.lmstudio/models" \
	"$HOME/.ollama/models" \
	"$HOME/.localai/models" \
	"$HOME/Library/Application Support/Jan/data/models" \
	"$HOME/Library/Application Support/nomic.ai/GPT4All"; do
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
done

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
