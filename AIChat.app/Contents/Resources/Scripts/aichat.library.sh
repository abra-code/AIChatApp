#!/bin/sh

alert="$OMC_OMC_SUPPORT_PATH/alert"
dialog="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
plister="$OMC_OMC_SUPPORT_PATH/plister"
filt="$OMC_OMC_SUPPORT_PATH/filt"
pasteboard="$OMC_OMC_SUPPORT_PATH/pasteboard"
next_command="$OMC_OMC_SUPPORT_PATH/omc_next_command"

# ──────────────────────────────────────────────────────────────
# Pasteboard helpers
# ──────────────────────────────────────────────────────────────

pb_set() { "$pasteboard" "$1" set "$2"; }
pb_get() { "$pasteboard" "$1" get; }

# ──────────────────────────────────────────────────────────────
# Formatting helpers
# ──────────────────────────────────────────────────────────────

# format_bytes <bytes>  →  human-readable string (KB / MB / GB)
format_bytes() {
    local bytes="$1"
    if [ "$bytes" -ge 1073741824 ] 2>/dev/null; then
        printf "%.1f GB" "$(echo "scale=4; $bytes/1073741824" | /usr/bin/bc -l 2>/dev/null)"
    elif [ "$bytes" -ge 1048576 ] 2>/dev/null; then
        printf "%.0f MB" "$(echo "scale=0; $bytes/1048576" | /usr/bin/bc -l 2>/dev/null)"
    else
        printf "%d KB" "$(echo "scale=0; $bytes/1024" | /usr/bin/bc -l 2>/dev/null)"
    fi
}

# ──────────────────────────────────────────────────────────────
# Server management
# ──────────────────────────────────────────────────────────────

# find_free_port()
# Returns the first unused port in the range 8088–8097, or empty string if all taken.
find_free_port() {
    local port=8088
    while [ "$port" -le 8097 ]; do
        if ! /usr/sbin/lsof -ti tcp:"$port" > /dev/null 2>&1; then
            echo "$port"
            return 0
        fi
        port=$((port + 1))
    done
    echo ""
    return 1
}

# calculate_total_server_ram()
# Sums model sizes (from /server-info) for all currently live registered servers.
# Prints the total in bytes.
calculate_total_server_ram() {
    local total=0
    [ ! -f "$prefs" ] && echo "0" && return 0

    local host_pids
    host_pids=$("$plister" get keys "$prefs" "/server-hosts" 2>/dev/null)
    while IFS= read -r _ctr_host_pid; do
        [ -z "$_ctr_host_pid" ] && continue
        /bin/ps -p "$_ctr_host_pid" > /dev/null 2>&1 || continue
        local server_pids
        server_pids=$("$plister" get keys "$prefs" "/server-hosts/$_ctr_host_pid" 2>/dev/null)
        while IFS= read -r _ctr_server_pid; do
            [ -z "$_ctr_server_pid" ] && continue
            kill -0 "$_ctr_server_pid" 2>/dev/null || continue
            local _ctr_size
            _ctr_size=$("$plister" get string "$prefs" "/server-info/$_ctr_server_pid/size" 2>/dev/null)
            [ -n "$_ctr_size" ] && [ "$_ctr_size" -gt 0 ] 2>/dev/null && total=$((total + _ctr_size))
        done <<< "$server_pids"
    done <<< "$host_pids"
    echo "$total"
}

# warn_ram_pressure_for_new_model <model_bytes> <model_label>
# Warns if adding this model would push total server RAM past 75% of unified memory.
# When other models are already running, the combined load is shown.
# Returns 0 to proceed, 1 if the user chose Cancel.
warn_ram_pressure_for_new_model() {
    local model_bytes="$1"
    local model_label="$2"

    [ -n "$model_bytes" ] && [ "$model_bytes" -gt 0 ] 2>/dev/null || return 0

    local ram_bytes
    ram_bytes=$(/usr/sbin/sysctl -n hw.memsize 2>/dev/null)
    [ -n "$ram_bytes" ] && [ "$ram_bytes" -gt 0 ] 2>/dev/null || return 0

    local ram_threshold=$(( ram_bytes * 3 / 4 ))
    local current_load
    current_load=$(calculate_total_server_ram)
    local new_total=$(( current_load + model_bytes ))

    [ "$new_total" -le "$ram_threshold" ] 2>/dev/null && return 0

    local ram_fmt model_fmt threshold_fmt new_fmt
    ram_fmt=$(format_bytes "$ram_bytes")
    model_fmt=$(format_bytes "$model_bytes")
    threshold_fmt=$(format_bytes "$ram_threshold")
    new_fmt=$(format_bytes "$new_total")

    local message
    if [ "$current_load" -gt 0 ] 2>/dev/null; then
        local current_fmt
        current_fmt=$(format_bytes "$current_load")
        message="Loading \"${model_label}\" (${model_fmt}) will likely cause high memory pressure.

Running models:  ${current_fmt}
New model:       ${model_fmt}
Combined total:  ${new_fmt}
75% of RAM:      ${threshold_fmt}
Unified memory:  ${ram_fmt}

This may cause slowdowns or instability. Consider closing another model session first."
    else
        message="\"${model_label}\" (${model_fmt}) likely exceeds what your Mac can load.

Unified memory:  ${ram_fmt}
Recommended max: ${threshold_fmt}

Models larger than 75% of unified memory may fail to load or cause severe memory pressure. A smaller quantization is recommended."
    fi

    "$alert" \
        --level caution \
        --title "High Memory Usage" \
        --ok "Load Anyway" \
        --cancel "Cancel" \
        "$message"

    [ $? -eq 0 ] && return 0 || return 1
}

# activate_if_model_running <model_path> [selector_window_uuid]
# Searches all live registered servers for model_path.
# If found: closes the optional selector window and activates the existing chat window.
# Returns 0 if the model was already running (caller should exit), 1 otherwise.
activate_if_model_running() {
    local model_path="$1"
    local selector_uuid="$2"

    [ ! -f "$prefs" ] && return 1

    local host_pids
    host_pids=$("$plister" get keys "$prefs" "/server-hosts" 2>/dev/null)
    while IFS= read -r _act_host_pid; do
        [ -z "$_act_host_pid" ] && continue
        /bin/ps -p "$_act_host_pid" > /dev/null 2>&1 || continue
        local server_pids
        server_pids=$("$plister" get keys "$prefs" "/server-hosts/$_act_host_pid" 2>/dev/null)
        while IFS= read -r _act_server_pid; do
            [ -z "$_act_server_pid" ] && continue
            kill -0 "$_act_server_pid" 2>/dev/null || continue
            local _act_running_model
            _act_running_model=$("$plister" get string "$prefs" "/server-hosts/$_act_host_pid/$_act_server_pid" 2>/dev/null)
            if [ "$_act_running_model" = "$model_path" ]; then
                echo "Same model already running, activating existing chat window"
                local _act_chat_window
                _act_chat_window=$("$plister" get string "$prefs" "/server-info/$_act_server_pid/dialog" 2>/dev/null)
                if [ -n "$selector_uuid" ]; then
                    "$dialog" "$selector_uuid" omc_window omc_terminate_ok
                fi
                if [ -n "$_act_chat_window" ]; then
                    "$dialog" "$_act_chat_window" omc_window omc_select
                fi
                return 0
            fi
        done <<< "$server_pids"
    done <<< "$host_pids"
    return 1
}

APPLET_NAME="AIChat"

# when no model is bundled with the app:
AICHAT_MODEL_PATH=""

# when a model is bundled with the app:
# AICHAT_MODEL_PATH="$OMC_APP_BUNDLE_PATH/Contents/Resources/LFM2-1.2B-F16.gguf"

prefs="/Users/$USER/Library/Preferences/com.abracode.AIChat-servers.plist"
# base port; aichat.init.sh picks a free port starting here
port_num="8088"
