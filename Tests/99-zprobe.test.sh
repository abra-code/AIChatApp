#!/bin/sh
# TEMPORARY REVIEW PROBE - delete me.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.cadabra.sh"

eng() { cad_call_lib aichat.chat.engine.library.sh "$@"; }
WIN="$OMC_ACTIONUI_WINDOW_UUID"
HROOT="$HOME/Library/Application Support/Cadabra/History"

MDIR="$OMCTEST_WORK/mlxmodel"
/bin/mkdir -p "$MDIR"
echo '{}' > "$MDIR/config.json"
/usr/bin/head -c 16 /dev/zero > "$MDIR/model.safetensors"

/bin/rm -rf "$HROOT"
cad_pb_set "aichatv2_modelpath_$WIN" ""
cad_pb_set "aichatv2_agent_$WIN" ""
cad_pb_set "aichatv2_session_$WIN" ""

section "a conversation started after a first-model load records the model"
eng chat_engine_load "$WIN" "$MDIR" false false
check "the window's engine label" "mlxmodel" \
    "$(cad_call_lib aichat.model.library.sh chat_engine_label "$WIN")"
( export OMC_ACTIONUI_TRIGGER_CONTEXT='{"sequence":1,"type":"message","id":"m1","data":{"type":"message","message":{"role":"local","text":"hi"}}}'
  omc_run aichat.chat.entry )
sid=$(cad_pb_get "aichatv2_session_$WIN")
check "a session was minted" "1" "$(cad_has "$sid" "-")"
check "and meta.json names the model" "1" \
    "$(cad_has "$(/bin/cat "$HROOT/$sid/meta.json" 2>/dev/null)" "mlxmodel")"

omctest_end
