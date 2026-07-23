#!/bin/sh
# aichat.select.local.model.cancel.sh
# Closes the model selector window. Also clears any armed in-place model-switch handoff so a
# Model-button-then-cancel cannot leave a stale arm that turns a later first-launch model
# pick into an in-place switch of the wrong window (the arm is otherwise only consumed on OK).
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

pb_set "$MODEL_SWITCH_KEY" ""
# Benchmark-pane state is per-window; drop it so keys don't accumulate across lifetimes.
pb_set "aichatv2_selected_model_${OMC_ACTIONUI_WINDOW_UUID}" ""
pb_set "aichatv2_bench_running_${OMC_ACTIONUI_WINDOW_UUID}" ""
"$dialog" "$OMC_ACTIONUI_WINDOW_UUID" omc_window omc_terminate_cancel
