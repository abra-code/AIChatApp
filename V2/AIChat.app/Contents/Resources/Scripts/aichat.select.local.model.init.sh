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

# Roots are scanned for BOTH engines. The HF cache and LM Studio genuinely hold each kind
# (LM Studio ships an MLX runtime), so neither can be assumed single-engine. The Ollama /
# LocalAI / Jan / GPT4All caches are GGUF-only in practice; scanning them for safetensors
# costs one find that returns nothing, which is cheaper than maintaining two root lists
# that would drift.
for root in \
	"$HOME/Library/Application Support/AIChatV2/Models" \
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
PREFS_DOMAIN="com.abracode.AIChatV2"
PREFS_KEY="recentModelPaths"
recent_paths=$(/usr/bin/defaults read "$PREFS_DOMAIN" "$PREFS_KEY" 2>/dev/null | \
	/usr/bin/grep -E '^\s+"' | \
	/usr/bin/sed 's/^[[:space:]]*"\(.*\)",\{0,1\}$/\1/')
while IFS= read -r recent_path; do
	[ -n "$recent_path" ] || continue
	add_row "$recent_path" ""
done <<< "$recent_paths"

if [ -n "$buffer" ]; then
	printf "%s" "$buffer" | "$dialog_tool" "$window_uuid" $TABLE_ID omc_table_set_rows_from_stdin
fi
