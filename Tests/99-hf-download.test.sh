#!/bin/sh
# Tests/99-hf-download.test.sh - the model downloader, and the one property everything here is
# really about: a file the app is in the middle of writing must never look like a model.
#
# The bug this file was written for shipped for months. curl wrote straight to
# Fixture-Q4_K_M.gguf, so any death the handler could not clean up after - a force quit, a
# panic, a power cut - left a truncated file at exactly the name the model picker scans for.
# The picker listed it, put a plausible size beside it, and handed it to a loader that could
# only fail. Nothing anywhere said why, and the user's only clue was a model that did not work.
#
# Every transfer now lands in "<final>.part" and is renamed into place only once it is whole
# AND the right size, so the assertions below are mostly of the form "after the interruption,
# what does the picker see". That question is asked through the applet's own model_engine and
# model_any_installed rather than by looking for files, because those two are what the picker
# and the launch branch actually ask.
#
# THE NETWORK IS A FAKE (helpers/fake_curl.sh, reached through the CADABRA_CURL seam). It is
# not there to simulate Hugging Face; it is there because every case worth testing is an
# interruption, and interruptions are what a working server never gives you.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.cadabra.sh"

cad_import_ids aichat.hf.browse.download.sh DL_

section "the ids and the seam this file drives"
check "the download pane's controls resolved" "211 230 231 222" \
    "$DL_INFO_TEXT_ID $DL_PROGRESS_ID $DL_PROGRESS_LABEL_ID $DL_DOWNLOAD_BTN_ID"

# The seam itself. Without it every assertion below would be about the real Hugging Face, which
# is to say about nothing. Checked as a fact rather than assumed, because a rename in the applet
# would leave this file quietly testing curl against a network the sandbox cannot reach.
check "the applet names its downloader through a seam" '${CADABRA_CURL:-/usr/bin/curl}' \
    "$(/usr/bin/sed -n 's/^hf_curl="\(.*\)"$/\1/p' \
        "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh")"

FAKE_CURL_DIR="$OMCTEST_WORK/fakecurl"
/bin/mkdir -p "$FAKE_CURL_DIR"
omctest_setvar CADABRA_CURL "$OMCTEST_TESTS/helpers/fake_curl.sh"
omctest_setvar FAKE_CURL_DIR "$FAKE_CURL_DIR"

# The second seam, and it is not a convenience. The downloader refuses to start unless the disk
# has 15 GB free ABOVE the download, which a test cannot arrange and cannot undo - so with the
# number hardcoded, every section below would pass or fail on how full this machine happens to
# be, and on one under the bar the whole file would go green while dispatching a handler that
# quit at its first check. (Measured: it did exactly that on the machine this was written on.)
# Zero here, and one section that puts it back up to assert the refusal itself.
omctest_setvar CADABRA_DISK_HEADROOM_GB 0

WIN="$OMC_ACTIONUI_WINDOW_UUID"
HUB="$HOME/.cache/huggingface/hub"

# ── GGUF fixture ──────────────────────────────────────────────────────────────
GGUF_REPO="fixture-org/Fixture-GGUF"
GGUF_FILE="Fixture-Q4_K_M.gguf"
GGUF_DIR="$HUB/models--fixture-org--Fixture-GGUF/snapshots/main"
GGUF_DEST="$GGUF_DIR/$GGUF_FILE"
GGUF_PART="$GGUF_DEST.part"
GGUF_SIZE=512

# fake_reset - a fresh network with nothing staged. Per-file keys are wiped too: they outlive a
# section otherwise, and a leftover "deliver 200" turns a later section's clean download into a
# truncated one that its assertions would then be describing.
fake_reset() {
    /bin/rm -f "$FAKE_CURL_DIR/size" "$FAKE_CURL_DIR/deliver" "$FAKE_CURL_DIR/exit" \
        "$FAKE_CURL_DIR/log"
    /bin/rm -f "$FAKE_CURL_DIR"/f_*
    : > "$FAKE_CURL_DIR/log"
}

# fake_calls <pattern> - how many curl invocations matched. The transfer/probe distinction is
# what proves a staging file was COMMITTED rather than re-fetched.
# -e, not --. Written as `grep -c -- "$1"` first, which ends grep's options and then hands it
# "--" as the PATTERN - and every transfer line matched it, through the "models--org--name" the
# cache path is built from. Three of these checks passed while counting the wrong thing.
fake_calls() {
    /usr/bin/grep -c -e "$1" "$FAKE_CURL_DIR/log" 2>/dev/null | /usr/bin/tr -d ' '
}

# run_gguf_download - the handler, dispatched the way the Download button dispatches it.
run_gguf_download() {
    omc_table_cell 202 3 "$GGUF_REPO"
    omc_table_cell 213 3 "$GGUF_FILE"
    cad_pb_set "hf_model_format_${WIN}" gguf
    omc_run aichat.hf.browse.download
}

# size_of <path> - bytes, or "absent". Never a bare stat, so a missing file reads as a word in
# the failure output rather than as an empty string that could mean anything.
size_of() {
    if [ ! -f "$1" ]; then
        echo absent
        return 0
    fi
    /usr/bin/stat -f%z -L "$1" 2>/dev/null
}

# The bytes the fake serves for the GGUF fixture, fetched once, so a resumed file can be
# compared against what an uninterrupted download would have produced. Position-dependent by
# construction (see the helper), which is what makes the comparison worth making: a resume that
# restarts at the wrong offset lands on the right SIZE and the wrong contents.
fake_reset
printf '%s' "$GGUF_SIZE" > "$FAKE_CURL_DIR/size"
REFERENCE="$OMCTEST_WORK/reference.bin"
"$OMCTEST_TESTS/helpers/fake_curl.sh" -fsSL -o "$REFERENCE" "https://x/$GGUF_FILE"

section "an uninterrupted download ends at the model's real name, with nothing left over"
fake_reset
/bin/rm -rf "$GGUF_DIR"
printf '%s' "$GGUF_SIZE" > "$FAKE_CURL_DIR/size"
ui_reset
run_gguf_download
check_status "the handler succeeds" 0
check "the model is at its real name" "$GGUF_SIZE" "$(size_of "$GGUF_DEST")"
check "and its bytes are the ones served" "0" \
    "$(/usr/bin/cmp -s "$GGUF_DEST" "$REFERENCE"; echo $?)"
check "no staging file survives"          "absent" "$(size_of "$GGUF_PART")"
check "the picker would list it"          "gguf"   "$(cad_model_call model_engine "$GGUF_DEST")"
check "and launch would find a model"     "0"      "$(cad_model_call model_any_installed; echo $?)"

section "a transfer that dies halfway leaves NOTHING the picker will offer"
# The whole point. curl exits 18 (partial file) having written 200 of 512 bytes - the shape of
# a dropped connection, and of a force quit as far as what is left on disk is concerned.
fake_reset
/bin/rm -rf "$GGUF_DIR"
printf '%s' "$GGUF_SIZE" > "$FAKE_CURL_DIR/size"
printf '200' > "$FAKE_CURL_DIR/deliver"
printf '18'  > "$FAKE_CURL_DIR/exit"
ui_reset
run_gguf_download
check "nothing is at the model's real name" "absent" "$(size_of "$GGUF_DEST")"
check "the picker sees no model there"      ""       "$(cad_model_call model_engine "$GGUF_DEST")"
check "and launch sees none on this Mac"    "1"      "$(cad_model_call model_any_installed; echo $?)"
# The bytes are not thrown away, they are parked where no reader looks. The old code deleted
# them and sent the user back to zero.
check "what arrived is kept for a resume"   "200"    "$(size_of "$GGUF_PART")"
check "and the pane says so"                "1"      \
    "$(cad_has "$(ui_value "$DL_INFO_TEXT_ID")" 'select Download again to resume')"

section "the next attempt resumes rather than restarting"
fake_reset
printf '%s' "$GGUF_SIZE" > "$FAKE_CURL_DIR/size"
ui_reset
run_gguf_download
check_status "the handler succeeds" 0
check "it asked for a range"                  "1" "$(fake_calls '-C -')"
check "the model is whole at its real name"   "$GGUF_SIZE" "$(size_of "$GGUF_DEST")"
# The assertion the size check alone cannot make. A resume that started at offset 0 would also
# end at 512 bytes; only the contents say whether the two halves line up.
check "and its bytes match an uninterrupted fetch" "0" \
    "$(/usr/bin/cmp -s "$GGUF_DEST" "$REFERENCE"; echo $?)"
check "the staging file is gone"              "absent" "$(size_of "$GGUF_PART")"

section "a transfer that finished but never got renamed is committed, not re-fetched"
# The narrowest window there is: everything arrived, and the app died between the last byte and
# the rename. Re-downloading it would be correct but wasteful, and on a 20 GB model the waste is
# the whole story.
fake_reset
/bin/rm -rf "$GGUF_DIR"
/bin/mkdir -p "$GGUF_DIR"
/bin/cp "$REFERENCE" "$GGUF_PART"
# With its sidecar, which is what says WHICH revision those bytes are. Staging a file without one
# is not this case - it is an unidentifiable leftover, and the applet starts over on those.
printf 'staged-rev' > "$FAKE_CURL_DIR/etag"
printf 'staged-rev' > "$GGUF_PART.id"
printf '%s' "$GGUF_SIZE" > "$FAKE_CURL_DIR/size"
ui_reset
run_gguf_download
check_status "the handler succeeds" 0
check "the model is at its real name" "$GGUF_SIZE" "$(size_of "$GGUF_DEST")"
check "no transfer was needed"        "0" "$(fake_calls '-o ')"
check "only the size was asked for"   "1" "$(fake_calls '-fsSIL')"
check "and the sidecar went with it"  "absent" "$(size_of "$GGUF_PART.id")"

section "a transfer that reports success and is the wrong size is refused"
# curl exiting 0 is not proof the file is whole: a proxy can close a stream cleanly mid-body.
# Publishing that would put a corrupt model at a real name with a clean bill of health, which is
# the failure this check exists to make impossible.
fake_reset
/bin/rm -rf "$GGUF_DIR"
printf '%s' "$GGUF_SIZE" > "$FAKE_CURL_DIR/size"
printf '300' > "$FAKE_CURL_DIR/deliver"
ui_reset
run_gguf_download
check "nothing is at the model's real name" "absent" "$(size_of "$GGUF_DEST")"
# Removed rather than kept: a short body reported as a success is not a partial transfer, it is
# a wrong one, and resuming from it would append the tail of the file onto the wrong prefix.
check "and the wrong-sized staging file is dropped" "absent" "$(size_of "$GGUF_PART")"
check "the pane names the reason" "1" \
    "$(cad_has "$(ui_value "$DL_INFO_TEXT_ID")" 'did not match the size')"

section "a leftover that is bigger than the file cannot be resumed from"
fake_reset
/bin/rm -rf "$GGUF_DIR"
/bin/mkdir -p "$GGUF_DIR"
/usr/bin/head -c 900 /dev/zero > "$GGUF_PART"
printf '%s' "$GGUF_SIZE" > "$FAKE_CURL_DIR/size"
ui_reset
run_gguf_download
check_status "the handler succeeds" 0
check "it started from the top"            "0" "$(fake_calls '-C -')"
check "the model is whole at its real name" "$GGUF_SIZE" "$(size_of "$GGUF_DEST")"
check "and holds the served bytes, not the leftover" "0" \
    "$(/usr/bin/cmp -s "$GGUF_DEST" "$REFERENCE"; echo $?)"

# ── MLX: the same property, one directory instead of one file ─────────────────
MLX_REPO="fixture-org/Fixture-MLX"
MLX_DIR="$HUB/models--fixture-org--Fixture-MLX/snapshots/main"
SHARD1="model-00001-of-00002.safetensors"
SHARD2="model-00002-of-00002.safetensors"

# The repo's file list, served to the tree API, and the two files whose CONTENT the applet
# reads rather than just counts: config.json, and the index whose shard names are what
# mlx_shards_complete checks against.
# mlx_stage [with-sizeless] - the repo's file list and the two files whose CONTENT the applet
# reads. With the argument, the listing also carries an entry the HF API would never emit: a file
# with no size. That is the shape the "nothing missing" test has to survive, because a size of
# zero is what an absent size normalizes to.
mlx_stage() {
    printf '%s' '{}' > "$FAKE_CURL_DIR/f_config.json.body"
    printf '%s' "{\"weight_map\": {\"a\": \"$SHARD1\", \"b\": \"$SHARD2\"}}" \
        > "$FAKE_CURL_DIR/f_model.safetensors.index.json.body"
    printf '%s' '200' > "$FAKE_CURL_DIR/f_${SHARD1}.size"
    printf '%s' '200' > "$FAKE_CURL_DIR/f_${SHARD2}.size"
    printf '%s' '0' > "$FAKE_CURL_DIR/f_extra.txt.size"
    /usr/bin/python3 - "$FAKE_CURL_DIR/f_tree.body" "$SHARD1" "$SHARD2" "${1:-}" <<'PY'
import json, sys, os
out, s1, s2, sizeless = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
cfg = os.path.join(os.path.dirname(out), "f_config.json.body")
idx = os.path.join(os.path.dirname(out), "f_model.safetensors.index.json.body")
tree = [
    {"type": "file", "path": "config.json", "size": os.path.getsize(cfg), "oid": "oid-config"},
    {"type": "file", "path": "model.safetensors.index.json",
     "size": os.path.getsize(idx), "oid": "oid-index"},
    {"type": "file", "path": s1, "size": 200, "oid": "oid-shard1"},
    {"type": "file", "path": s2, "size": 200, "oid": "oid-shard2"},
]
if sizeless:
    tree.append({"type": "file", "path": "extra.txt", "size": 0, "oid": "oid-extra"})
with open(out, "w") as fh:
    json.dump(tree, fh)
PY
}

run_mlx_download() {
    omc_table_cell 202 3 "$MLX_REPO"
    cad_pb_set "hf_model_format_${WIN}" mlx
    omc_run aichat.hf.browse.download
}

section "an MLX tree missing a shard is not a model, however complete it looks"
# The MLX half of the same bug, and the harder half: a directory holding config.json and SOME
# of its shards is indistinguishable from a whole model to anything that just asks "is there a
# safetensors in here" - which is exactly what the picker used to ask.
fake_reset
/bin/rm -rf "$MLX_DIR"
# The GGUF fixture goes too: the question below is whether an incomplete MLX tree counts as an
# installed model, and a leftover from an earlier section answers it for the wrong reason.
/bin/rm -rf "$GGUF_DIR"
mlx_stage
printf '40' > "$FAKE_CURL_DIR/f_${SHARD2}.deliver"
printf '18' > "$FAKE_CURL_DIR/f_${SHARD2}.exit"
ui_reset
run_mlx_download
check "the first shard is whole"          "200" "$(size_of "$MLX_DIR/$SHARD1")"
check "the second is only ever staged"    "absent" "$(size_of "$MLX_DIR/$SHARD2")"
check "  and what arrived of it is kept"  "40"  "$(size_of "$MLX_DIR/$SHARD2.part")"
check "the picker sees no model there"    ""    "$(cad_model_call model_engine "$MLX_DIR")"
check "and launch sees none on this Mac"  "1"   "$(cad_model_call model_any_installed; echo $?)"

section "and finishing the missing shard is what makes it one"
# The positive control for the section above. Without it "not a model" could be passing because
# the download never happened at all.
fake_reset
mlx_stage
ui_reset
run_mlx_download
check_status "the handler succeeds" 0
check "the second shard resumed"        "1"   "$(fake_calls '-C -')"
check "both shards are whole"           "200 200" \
    "$(size_of "$MLX_DIR/$SHARD1") $(size_of "$MLX_DIR/$SHARD2")"
check "no staging file survives"        "absent" "$(size_of "$MLX_DIR/$SHARD2.part")"
check "the picker lists it now"         "mlx" "$(cad_model_call model_engine "$MLX_DIR")"
check "and launch finds a model"        "0"   "$(cad_model_call model_any_installed; echo $?)"

section "a dropped connection during a RESUME keeps what it had"
# The distinction the first cut of this got wrong, and it made resume useless on exactly the
# links that need it. A resumed transfer can fail because the far end will not do byte ranges -
# in which case the leftover is worthless and must go - or because the connection died again, in
# which case it is worth more than it was a minute ago. Deleting on the second reading means a
# 20 GB model over a link that drops hourly can never get past one hour's worth: every attempt
# throws away the last one's progress and starts at zero.
fake_reset
/bin/rm -rf "$GGUF_DIR"
printf '%s' "$GGUF_SIZE" > "$FAKE_CURL_DIR/size"
printf '150' > "$FAKE_CURL_DIR/deliver"
printf '56'  > "$FAKE_CURL_DIR/exit"
ui_reset
run_gguf_download
check "the first attempt keeps what it got" "150" "$(size_of "$GGUF_PART")"
# Second attempt: resumes, and the connection drops again part way.
printf '100' > "$FAKE_CURL_DIR/deliver"
ui_reset
run_gguf_download
check "the second resumes rather than restarting" "1" "$(fake_calls '-C -')"
check "and the partial GREW"                      "250" "$(size_of "$GGUF_PART")"
# Third: the link holds.
/bin/rm -f "$FAKE_CURL_DIR/deliver" "$FAKE_CURL_DIR/exit"
ui_reset
run_gguf_download
check_status "the third attempt succeeds" 0
check "three drops later the model is whole" "$GGUF_SIZE" "$(size_of "$GGUF_DEST")"
check "and its bytes are still the right ones" "0" \
    "$(/usr/bin/cmp -s "$GGUF_DEST" "$REFERENCE"; echo $?)"

section "a server that refuses byte ranges is the one case worth starting over for"
fake_reset
/bin/rm -rf "$GGUF_DIR"
printf '%s' "$GGUF_SIZE" > "$FAKE_CURL_DIR/size"
printf '200' > "$FAKE_CURL_DIR/deliver"
printf '18'  > "$FAKE_CURL_DIR/exit"
ui_reset
run_gguf_download
check "there is a partial to resume from" "200" "$(size_of "$GGUF_PART")"
# Now the far end will not honor a range (curl 33). The applet gets one shot at the resume, then
# drops the leftover and fetches the whole thing.
fake_reset
printf '%s' "$GGUF_SIZE" > "$FAKE_CURL_DIR/size"
printf '1' > "$FAKE_CURL_DIR/refuse_resume"
ui_reset
run_gguf_download
check "it tried the range once"        "1" "$(fake_calls '-C -')"
check "then fetched the whole file"    "1" "$(fake_calls '-fsSL -o ')"
check_status "and succeeded"           0
check "the model is whole"             "$GGUF_SIZE" "$(size_of "$GGUF_DEST")"
check "and holds the served bytes"     "0" \
    "$(/usr/bin/cmp -s "$GGUF_DEST" "$REFERENCE"; echo $?)"

section "a partial is never resumed against a file that has changed underneath it"
# Size alone cannot see this one. If the quant is re-uploaded between attempts, a resume splices
# the head of the old revision onto the tail of the new one - and because the tail IS the length
# the server now declares, the result passes every size check and gets published as a model.
fake_reset
/bin/rm -rf "$GGUF_DIR"
printf '%s' "$GGUF_SIZE" > "$FAKE_CURL_DIR/size"
printf '200' > "$FAKE_CURL_DIR/deliver"
printf '18'  > "$FAKE_CURL_DIR/exit"
ui_reset
run_gguf_download
check "there is a partial to resume from" "200" "$(size_of "$GGUF_PART")"
# Same name, same length, different file.
fake_reset
printf '%s' "$GGUF_SIZE" > "$FAKE_CURL_DIR/size"
printf 'a-different-revision' > "$FAKE_CURL_DIR/etag"
ui_reset
run_gguf_download
check_status "the handler succeeds" 0
check "it did NOT resume onto the old bytes" "0" "$(fake_calls '-C -')"
check "the model is whole"                   "$GGUF_SIZE" "$(size_of "$GGUF_DEST")"
check "and is one revision end to end"       "0" \
    "$(/usr/bin/cmp -s "$GGUF_DEST" "$REFERENCE"; echo $?)"

section "a truncated file left at a model's real name by an older build is repaired"
# The corruption already on disks in the wild. The old fast path asked only whether a file with
# that name existed, so it reported the wreckage as already downloaded and clicking Download
# could not fix it - the one repair the user would think to try was the one that did nothing.
fake_reset
/bin/rm -rf "$GGUF_DIR"
/bin/mkdir -p "$GGUF_DIR"
/usr/bin/head -c 137 "$REFERENCE" > "$GGUF_DEST"
printf '%s' "$GGUF_SIZE" > "$FAKE_CURL_DIR/size"
ui_reset
run_gguf_download
check_status "the handler succeeds" 0
check "the short file was fetched again" "1" "$(fake_calls '-fsSL -o ')"
check "and is whole now"                 "$GGUF_SIZE" "$(size_of "$GGUF_DEST")"
check "with the right bytes"             "0" \
    "$(/usr/bin/cmp -s "$GGUF_DEST" "$REFERENCE"; echo $?)"
# The positive control: a file that IS the declared size is left alone, and costs no transfer.
fake_reset
printf '%s' "$GGUF_SIZE" > "$FAKE_CURL_DIR/size"
ui_reset
run_gguf_download
check "a file already the right size is not refetched" "0" "$(fake_calls '-fsSL -o ')"
check "  and the pane says it is already here"         "1" \
    "$(cad_has "$(ui_value "$DL_INFO_TEXT_ID")" 'Already downloaded')"

section "with no declared length there is nothing to verify against, and nothing to resume"
# The honest floor. A server that sends no Content-Length leaves the applet no way to tell a
# whole file from a truncated one, so it commits what curl gave it - as it always did.
fake_reset
/bin/rm -rf "$GGUF_DIR"
printf '0' > "$FAKE_CURL_DIR/size"
ui_reset
run_gguf_download
check_status "the handler succeeds" 0
check "what arrived is published" "1" \
    "$([ -f "$GGUF_DEST" ] && echo 1 || echo 0)"
check "and no staging file is left" "absent" "$(size_of "$GGUF_PART")"

# The other half, and it was claimed here before it was tested: a leftover that arrives with no
# length to judge it by is DROPPED rather than continued. There is nothing to resume against -
# not the size, since none was declared - so appending would produce a file of some length and
# unknown contents, which is the one outcome worse than fetching it again.
fake_reset
/bin/rm -rf "$GGUF_DIR"
/bin/mkdir -p "$GGUF_DIR"
/usr/bin/head -c 200 "$REFERENCE" > "$GGUF_PART"
printf 'staged-rev' > "$GGUF_PART.id"
printf 'staged-rev' > "$FAKE_CURL_DIR/etag"
printf '0' > "$FAKE_CURL_DIR/size"
ui_reset
run_gguf_download
check_status "the handler succeeds" 0
check "an unmeasurable leftover is not resumed onto" "0" "$(fake_calls '-C -')"
check "  it was fetched from the top instead"        "1" "$(fake_calls '-fsSL -o ')"
check "  and its sidecar went with it"               "absent" "$(size_of "$GGUF_PART.id")"

section "a file the listing gives no size for still has to be there"
# The guard on the "nothing missing" shortcut. Completeness is decided by comparing sizes, and a
# listing entry with no size normalizes to zero - so on sizes alone a file that is not on disk at
# all scores as costing nothing, and a model with one file that never arrived would be reported
# as already downloaded. Absence is therefore counted on its own, not inferred from bytes.
#
# Runs on the MLX tree an earlier section left complete - the GGUF sections in between touch a
# different directory - so everything EXCEPT the sizeless file is already there: if absence were
# free, this would take the shortcut and fetch nothing.
fake_reset
mlx_stage with-sizeless
ui_reset
run_mlx_download
check_status "the handler succeeds" 0
check "it did not call the model complete" "0" \
    "$(cad_has "$(ui_value "$DL_INFO_TEXT_ID")" 'Already downloaded')"
check "the missing file was fetched"       "1" \
    "$([ -f "$MLX_DIR/extra.txt" ] && echo 1 || echo 0)"
# The positive control: with it there, the shortcut is right and nothing is transferred.
fake_reset
mlx_stage with-sizeless
ui_reset
run_mlx_download
check "a second run takes the shortcut" "1" \
    "$(cad_has "$(ui_value "$DL_INFO_TEXT_ID")" 'Already downloaded')"
check "  and transfers nothing"         "0" "$(fake_calls '-fsSL -o ')"

section "a download that would fill the disk is refused before it starts"
# The check that was in the way of every section above, asserted rather than merely disabled.
# macOS needs free space for swap and system caches, so a model pull that takes the last of it
# leaves a Mac that does not work rather than one that is merely full.
fake_reset
/bin/rm -rf "$GGUF_DIR"
printf '%s' "$GGUF_SIZE" > "$FAKE_CURL_DIR/size"
omctest_setvar CADABRA_DISK_HEADROOM_GB 100000
ui_reset
alerts_reset
run_gguf_download
check "no transfer was attempted"   "0" "$(fake_calls '-o ')"
check "nothing was written"         "absent" "$(size_of "$GGUF_DEST")"
check "and the user was told why"   "1" "$(alerts_mention 'Not enough disk space')"
omctest_setvar CADABRA_DISK_HEADROOM_GB 0

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids" "" "$(ui_unknown_writes)"
check "no table clobbered by a bare value write" "" "$(ui_suspect_writes)"

omctest_end
