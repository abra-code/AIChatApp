#!/bin/sh

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

echo "[$(/usr/bin/basename "$0")]"

# Discover GGUF models in common local model cache locations.
# Prints one absolute path per line.
discover_local_models() {
	local hf_cache="$HOME/.cache/huggingface/hub"
	local lmstudio_cache="$HOME/.lmstudio/models"

	for cache_dir in "$hf_cache" "$lmstudio_cache"; do
		if [ -d "$cache_dir" ]; then
			find "$cache_dir" -name "*.gguf" 2>/dev/null | sort
		fi
	done
}

model_paths_raw=$(discover_local_models)

if [ -z "$model_paths_raw" ]; then
	"$alert" --level "informational" --title "$APPLET_NAME" --ok "OK" \
		"No GGUF models found in:\n• ~/.cache/huggingface/hub\n• ~/.lmstudio/models"
	exit 0
fi

# Build parallel arrays: display names and their corresponding paths.
display_names=()
model_paths=()

while IFS= read -r model_path; do
	if [ -n "$model_path" ]; then
		filename=$(/usr/bin/basename "$model_path" .gguf)
		file_size=$(/usr/bin/stat -f%z -L "$model_path" 2>/dev/null || echo 0)
		size_gb=$(printf "%.1f" "$(echo "scale=4; $file_size / (1024*1024*1024)" | /usr/bin/bc -l 2>/dev/null)")
		display_name="${filename} (${size_gb} GB)"
		display_names+=("$display_name")
		model_paths+=("$model_path")
	fi
done <<< "$model_paths_raw"

# TODO: Replace with a custom NIB dialog that contains a table/list control.
# The dialog init script should receive the model list via pasteboard or a temp file,
# populate the table, and return the selected path when the user confirms.
# For now, osascript choose-from-list is used as a stand-in.

# Build an AppleScript list literal: {"item 1", "item 2", ...}
as_list=""
for name in "${display_names[@]}"; do
	escaped="${name//\"/\\\"}"
	if [ -n "$as_list" ]; then
		as_list="$as_list, \"$escaped\""
	else
		as_list="\"$escaped\""
	fi
done

selected_name=$(osascript 2>/dev/null <<APPLEEOF
set modelList to {$as_list}
set chosen to choose from list modelList ¬
	with title "AIChat - Select Model" ¬
	with prompt "Select a local GGUF model to load:" ¬
	default items {item 1 of modelList}
if chosen is false then
	return ""
else
	return item 1 of chosen
end if
APPLEEOF
)

if [ -z "$selected_name" ]; then
	echo "User cancelled model selection"
	exit 0
fi

# Look up the full path for the chosen display name.
selected_path=""
for i in "${!display_names[@]}"; do
	if [ "${display_names[$i]}" = "$selected_name" ]; then
		selected_path="${model_paths[$i]}"
		break
	fi
done

if [ -z "$selected_path" ]; then
	echo "Could not find path for selected model: $selected_name"
	exit 1
fi

echo "Selected model path: $selected_path"

# Stop any llama-server currently using our port so the new model can bind to it.
existing_pid=$(/usr/sbin/lsof -ti tcp:$port_num 2>/dev/null | head -1)
if [ -n "$existing_pid" ]; then
	echo "Stopping existing server (pid=$existing_pid) on port $port_num"
	kill -TERM "$existing_pid"
	# Wait up to 5 seconds for it to exit.
	count=0
	while kill -0 "$existing_pid" 2>/dev/null && [ "$count" -lt 5 ]; do
		sleep 1
		count=$((count + 1))
	done
fi

# Pass the selected model path to aichat.init via pasteboard and chain to aichat.new.
"$pasteboard" "AICHAT_MODEL_PATH" put "$selected_path"
"$next_command" "$OMC_CURRENT_COMMAND_GUID" "aichat.new"
