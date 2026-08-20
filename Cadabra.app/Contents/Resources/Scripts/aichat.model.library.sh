#!/bin/sh
# aichat.model.library.sh
# Model session helpers used by the model-loading flows: total RAM of running models,
# the RAM-pressure warning shown before loading a new model, and activating an existing
# chat window when the same model is already running. Sources the base library for
# $prefs / $dialog / $alert / format_bytes. Sourced by aichat.init and the model-open
# handlers (hf.browse.download, open.from.file.browser, select.local.model.ok).
[ -n "${__AICHAT_MODEL_LIB:-}" ] && return 0
__AICHAT_MODEL_LIB=1
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

# ── Engine detection and per-engine model facts ───────────────────────────────
# The app drives three engines from one picker, so exactly ONE place decides what a path IS;
# the picker rows, the info pane, the RAM check and chat.init's argv all dispatch on this
# rather than re-deriving it. For the two local engines the distinction is a SHAPE
# difference, not a naming convention: a GGUF model is a single FILE, an MLX model is a
# DIRECTORY holding config.json + *.safetensors shards. That is why callers cannot just stat
# the path, and why "size" and "display name" mean two different computations per engine.

# Apple's on-device system model has NO PATH: it belongs to the OS, is not downloaded by us,
# and cannot be revealed, deleted or sized. Every flow here is keyed by "the selected model
# path", so it travels as this sentinel rather than as a special case threaded through the
# picker, the pasteboard handoff and the launch queue. It cannot collide with a real model:
# every scanned path is absolute, and this one has no leading slash.
FOUNDATION_MODEL_ID="foundation:apple-on-device"

# model_engine <path> -> "foundation" | "gguf" | "mlx" | "" (unknown, or no longer on disk)
model_engine() {
	# FIRST, and not by preference: the tests below all touch the filesystem, and the
	# sentinel is not on it. Reached in that order it would fall through to "" (unknown)
	# and be reported to the user as a corrupt model.
	[ "$1" = "$FOUNDATION_MODEL_ID" ] && { echo "foundation"; return 0; }
	case "$1" in
		*.gguf) [ -f "$1" ] && { echo "gguf"; return 0; } ;;
	esac
	if [ -d "$1" ] && [ -f "$1/config.json" ]; then
		# config.json alone is not enough - HF snapshot dirs of GGUF repos carry one too.
		# The shards are what make it loadable. -maxdepth 2 because shards normally sit
		# beside config.json but some repos nest them one level down; bounded so this stays
		# cheap enough to call per picker row.
		local _st
		_st=$(/usr/bin/find -L "$1" -maxdepth 2 -name '*.safetensors' -type f 2>/dev/null | /usr/bin/head -n 1)
		[ -n "$_st" ] && { echo "mlx"; return 0; }
	fi
	echo ""
	return 1
}

# model_engine_label <engine> -> the engine's name as a PERSON should read it.
# `gguf`/`mlx`/`foundation` are internal identifiers; putting them in an alert produces
# "This conversation runs on foundation", which is not English.
model_engine_label() {
	case "$1" in
		gguf)       echo "GGUF (llama-server)" ;;
		mlx)        echo "MLX (in-process)" ;;
		foundation) echo "Foundation Models (on device)" ;;
		*)          echo "an unrecognized engine" ;;
	esac
}

# model_display_label <path> -> the name to show for a model.
# GGUF: the FILENAME carries the quantisation (...-Q5_K_S), which is exactly what the user
# is choosing between, so keep it and only drop the extension.
# MLX: the path is .../models--<org>--<name>/snapshots/<hash>/, whose leaf is a content
# hash - useless as a label - so surface "<org>/<name>" instead.
# ORDER IS LOAD-BEARING: the .gguf test must run FIRST, because a GGUF living in the HF
# cache also matches the snapshot pattern and would otherwise be relabelled to org/name,
# silently losing the quant - the one thing that distinguishes two rows of the same model.
model_display_label() {
	[ "$1" = "$FOUNDATION_MODEL_ID" ] && { echo "Apple Foundation Models"; return 0; }
	case "$1" in
		*.gguf) /usr/bin/basename "$1" .gguf; return 0 ;;
	esac
	case "$1" in
		*"/models--"*"/snapshots/"*)
			printf '%s' "$1" | /usr/bin/sed -E 's#.*/models--([^/]+)/snapshots/.*#\1#; s#--#/#g' ;;
		*) /usr/bin/basename "$1" ;;
	esac
}

# chat_engine_label <window-uuid> -> what is driving this window, or nothing
#
# An external ACP agent or a local model, never both: chat.init.sh stamps exactly one of the
# two per-window keys and blanks the other. The agent is checked first because an external
# window has no model path at all, and that asymmetry is what used to make these call sites
# fall through to a bare "New conversation" with nothing after it.
chat_engine_label() {
	local agent model_path
	agent=$(pb_get "aichatv2_agent_${1}")
	[ -n "$agent" ] && { printf '%s\n' "$agent"; return 0; }
	model_path=$(pb_get "aichatv2_modelpath_${1}")
	[ -n "$model_path" ] && model_display_label "$model_path"
}

# model_dir_bytes <dir> -> total bytes of the model's *.safetensors shards, summed RECURSIVELY
# (find, not a top-level glob) so a repo whose shards live in a subdirectory is still measured.
# Used for the MLX RAM check (weights dominate the footprint).
model_dir_bytes() {
	local total=0
	local st=""
	local sz=""
	while IFS= read -r st; do
		[ -n "$st" ] || continue
		sz=$(/usr/bin/stat -f%z -L "$st" 2>/dev/null || echo 0)
		total=$((total + sz))
	done <<EOF
$(/usr/bin/find -L "$1" -name "*.safetensors" -type f 2>/dev/null)
EOF
	echo "$total"
}

# model_supports_tools <path> [engine] -> 0 when the model can drive the agent's tool loop.
# Both engines answer the SAME question - does the chat template know how to render tool
# definitions and tool calls - but the template lives in a different container per engine:
# GGUF metadata vs tokenizer_config.json. A cheap read either way; neither loads the model.
# Pass <engine> when the caller already knows it, to skip a re-detect.
model_supports_tools() {
	local _eng="${2:-$(model_engine "$1")}"
	case "$_eng" in
		foundation)
			# Yes, and there is no template to inspect: the framework owns tool calling, and
			# mlx-agent bridges MCP tools into it.
			#
			# Not reached by the picker, which emits this row and its info pane from their own
			# code paths - kept because this helper answers a question about an ENGINE, and a
			# future caller asking it about this one deserves the true answer rather than the
			# `*)` fallthrough's "no". Note it answers "can it", not "should it": every tool
			# definition is spent from the same small window the conversation lives in.
			return 0 ;;
		gguf)
			local _py="$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3"
			local _chk="$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/gguf_check_tools.py"
			[ -x "$_py" ] && [ -f "$_chk" ] || return 1
			[ "$("$_py" "$_chk" "$1" 2>/dev/null)" = "true" ] ;;
		mlx)
			# Extract the TEMPLATE, then ask the same question the gguf branch asks of it
			# ("tool_call" in tmpl), so the two engines cannot answer differently.
			# Two traps a grep over tokenizer_config.json falls into:
			#  - FALSE POSITIVE: the file also carries added_tokens_decoder, so a model that
			#    merely has <|tool_call_start|> in its VOCABULARY matches even when its
			#    template never renders a tool. A false badge also auto-enables the tools
			#    toggle in the picker, which spawns MCP servers the user did not ask for.
			#  - FALSE NEGATIVE: newer HF exports put the template in chat_template.jinja and
			#    leave no chat_template key here at all.
			local _py="$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3"
			[ -x "$_py" ] || return 1
			"$_py" - "$1" <<'PY' 2>/dev/null
import json, os, sys
d = sys.argv[1]
parts = []
# A model may ship the template in EITHER place, and LFM2 ships it in both. Rather than
# guess which one mlx-swift-lm's tokenizer will actually pick at load time, read both and
# ask whether tools appear in either. Getting the precedence wrong would mean badging on
# the template the runtime does not use; reading both cannot.
jinja = os.path.join(d, "chat_template.jinja")
if os.path.isfile(jinja):
    with open(jinja, encoding="utf-8", errors="replace") as f:
        parts.append(f.read())
try:
    with open(os.path.join(d, "tokenizer_config.json"), encoding="utf-8", errors="replace") as f:
        v = json.load(f).get("chat_template", "")
    # Older exports allow a LIST of {name, template} variants; check them all.
    parts.append(v if isinstance(v, str) else json.dumps(v))
except Exception:
    pass
sys.exit(0 if any("tool_call" in p for p in parts) else 1)
PY
			;;
		*) return 1 ;;
	esac
}

# ── Apple Foundation Models availability ──────────────────────────────────────
# Whether to OFFER the on-device model, and what to say when it is not usable. The agent owns
# this answer (it is the process that links the framework), so ask it rather than reimplementing
# the checks here. Bare `fm-check` does not generate - it is the availability question alone,
# ~0.01-0.05s - which is what makes it affordable on a path the picker walks on every open and
# row click. `--test-prompt` would add a real generation (~0.3s) and prove nothing we need here.

# foundation_probe -> "<reason>\t<human summary>\t<context window>\t<locale ok>\t<languages>" on
# stdout; exit 0 only when
# usable. The third field is the model's real window in tokens, empty when it could not be read.
#
# Diagnostics go to STDERR. Stdout is the return value and every caller splits it with `cut`.
#
# BRANCH ON THE REASON, never on the summary: the reason is a stable code from the agent, the
# summary is prose written to be read and reworded. The codes that matter to a caller:
#   available             usable now
#   appleIntelligenceOff  the one the user can fix - offer the Settings hop
#   modelNotReady         assets still downloading; retry later
#   deviceNotEligible     this Mac never will be
#   osTooOld / notBuilt   nothing to offer
#
# `unknown` is the agent's own code for a framework reason it did not recognize, and it is also
# what this function reports when the agent printed an availability line but died before the
# machine-readable one. Two more are invented here, for cases the agent cannot report because it
# never got to speak: `timedOut` (it did not answer inside the bound) and `probeFailed` (it
# answered with nothing usable - a crash, or a binary too broken to run). All three stay
# offerable: none of them is a verdict of "never".
#
# Note that an unrecognized code is passed through VERBATIM rather than folded into `unknown` -
# see foundation_offerable, which is a denylist for exactly that reason.
foundation_probe() {
	local _bin="$OMC_APP_BUNDLE_PATH/Contents/Support/MLX/mlx-agent"
	if [ ! -x "$_bin" ]; then
		printf 'notBuilt\tthe bundled agent is missing\n'
		return 1
	fi

	local _out _err _rc _reason _summary _window _locale_ok _langs _timeout
	_err=$(/usr/bin/mktemp -t aichat_fmprobe) || _err=""

	# BOUNDED. `probe()` is a synchronous call into a system daemon, and this runs on the path
	# that builds the picker - before the disk scan - so a wedged daemon would leave the table
	# empty, with no spinner and no way out. macOS ships no timeout(1); perl is in the base
	# system. 5s is ~100x the measured 0.05s.
	#
	# It runs the agent in its OWN PROCESS GROUP and signals the group, not the process. The
	# obvious one-liner - `perl -e 'alarm 5; exec @ARGV'` - does not actually bound anything
	# here: the command substitution below reads until every writer closes the pipe, so a
	# lingering grandchild holding stdout keeps this blocked long after the timed-out process
	# is gone. Measured at the full 60s against a stub that backgrounds a sleep. Killing the
	# group closes the pipe for real.
	_timeout='my $pid = fork();
		exit 127 if !defined $pid;
		if ($pid == 0) { setpgrp(0, 0); exec @ARGV; exit 127 }
		$SIG{ALRM} = sub { kill("TERM", -$pid); sleep 1; kill("KILL", -$pid); exit 124 };
		alarm 5;
		waitpid($pid, 0);
		alarm 0;
		my $st = $?;
		exit($st & 127 ? 128 + ($st & 127) : $st >> 8);'
	if [ -n "$_err" ]; then
		_out=$(/usr/bin/perl -e "$_timeout" "$_bin" fm-check 2>"$_err")
	else
		_out=$(/usr/bin/perl -e "$_timeout" "$_bin" fm-check 2>/dev/null)
	fi
	_rc=$?

	# The reason is a bare identifier in the RESULT_JSON line, so it needs no JSON unescaping -
	# which is exactly why the human half is taken from the printed "availability:" line
	# instead of from the JSON "detail" field. Neither parse can trip over a quote.
	#
	# The reason pattern is greedy, so it takes the LAST "reason" on the line. That is the real
	# field because the agent emits sorted keys and nothing sorts after `reason` - if that ever
	# changes, a crafted `detail` could shadow it. The charset matches the agent's documented
	# "add codes, never rename" contract, which allows a digit or underscore in a future code.
	_reason=$(printf '%s\n' "$_out" | /usr/bin/sed -n 's/.*"reason":"\([A-Za-z0-9_]*\)".*/\1/p' | /usr/bin/head -n 1)
	_summary=$(printf '%s\n' "$_out" | /usr/bin/sed -n 's/^[[:space:]]*availability:[[:space:]]*//p' | /usr/bin/head -n 1)
	# The real window, rather than a number hardcoded in the info pane that would quietly
	# become a lie if Apple changed it. Empty when the agent did not get far enough to print.
	_window=$(printf '%s\n' "$_out" | /usr/bin/sed -n 's/^[[:space:]]*context size:[[:space:]]*\([0-9]*\).*/\1/p' | /usr/bin/head -n 1)

	# The language set, scraped the same way and for the same reason as the window: the agent
	# already measures it, and the alternative is a pane that stays silent about the one fact
	# most likely to make this model the wrong choice.
	#
	# It earns a row because an unsupported language fails SILENTLY. It does not raise
	# unsupportedLanguageOrLocale - measured with Polish, which raised it never. It answers in
	# English instead, or answers in the requested language with confident nonsense, or dies
	# mid-stream with guardrailViolation, which reads as a safety refusal for a benign prompt.
	# The model will also claim it speaks the language if asked. See the language section of
	# mlx-agent's docs/foundation-models.md.
	#
	# Two facts, because they answer different questions: whether THIS user is affected, and
	# which languages the model has at all (a user who works in two).
	case "$(printf '%s\n' "$_out" | /usr/bin/sed -n 's/^[[:space:]]*current locale:[[:space:]]*//p' | /usr/bin/head -n 1)" in
		supported*) _locale_ok=yes ;;
		NOT*) _locale_ok=no ;;
		*) _locale_ok="" ;;
	esac
	# The codes sit on the line AFTER the `languages:` label, unlabelled, so this takes the
	# next line rather than matching a pattern that would also match the locale count above it.
	#
	# BOTH guards are load-bearing, and they cover different failures:
	#   (getline) > 0  - a bare getline returns 0 at EOF and leaves $0 UNCHANGED, so a run that
	#                    ends at the label would fall through and print the LABEL line.
	#   the shape test - when the run ends one line later, getline SUCCEEDS and hands back the
	#                    RESULT_JSON line, which the count guard alone would happily print.
	# Either way `wc -w` downstream turns the garbage into a plausible count and the pane shows
	# it labelled as a measurement, which is the one thing this pane must never do. So the line
	# must also LOOK like a code list: lowercase ISO codes separated by single spaces, which no
	# label line and no JSON can satisfy.
	_langs=$(printf '%s\n' "$_out" | /usr/bin/awk '
		/^[[:space:]]*languages:/ {
			if ((getline) > 0 && $0 ~ /^[[:space:]]*[a-z][a-z-]*([[:space:]]+[a-z][a-z-]*)*[[:space:]]*$/) {
				gsub(/^[[:space:]]+|[[:space:]]+$/, "")
				print
			}
			exit
		}')

	# TO STDERR, not stdout: this function's stdout IS its return value, parsed by every caller
	# with cut. Logging into it turned one warning line from the agent into a two-line "reason"
	# and inverted the verdict everywhere - and it fired hardest on failures, where stderr is
	# non-empty by definition. Same idiom the MCP config generator uses one file over.
	if [ -n "$_err" ]; then
		[ -s "$_err" ] && echo "foundation_probe: $(/usr/bin/head -c 500 "$_err")" 1>&2
		/bin/rm -f "$_err"
	fi

	# A hang costs the caller the full timeout on a path walked on every picker open and every
	# row click, so say so - otherwise the only symptom is a UI that feels slow for no visible
	# reason. Logged for EVERY timeout, not just one that followed a complete answer: a hang
	# after partial output is the likelier shape, and it was the one with no trace.
	[ "$_rc" = 124 ] && echo "foundation_probe: agent hung; killed at the timeout" 1>&2

	if [ -z "$_reason" ]; then
		# A COMPLETE RESULT_JSON with no reason key is a different thing from a truncated
		# run: it is an agent built before the reason contract existed. Tested first, because
		# such an agent also prints the availability line and would otherwise be reported as
		# "unavailable for an unrecognized reason" on a machine where the model works fine.
		case "$_out" in
			*RESULT_JSON:*)
				printf 'notBuilt\tthe bundled agent is too old to report why the model is unavailable\n'
				return 1 ;;
		esac
		# An availability line but no RESULT_JSON: it died partway. That line is an accurate,
		# actionable reading, so keep it. Tested BEFORE the timeout case on purpose - an agent
		# that printed "Apple Intelligence is switched off" and then wedged has already told us
		# the useful thing, and reporting it as "not responding" would trade a fixable answer
		# with a Settings hop for a shrug. `unknown` because we never saw the code itself.
		if [ -n "$_summary" ]; then
			printf 'unknown\t%s\n' "$_summary"
			return 1
		fi
		if [ "$_rc" = 124 ]; then
			# Killed by our own alarm, with nothing usable printed. Reported distinctly and
			# kept OFFERABLE: a wedged or slow daemon is transient, and collapsing it into
			# notBuilt would delete the row and then call the situation permanent.
			printf 'timedOut\tthe on-device model did not answer in time; try again in a moment\n'
			return 1
		fi
		# Nothing usable at all, and NOT reported as notBuilt: that is a permanent verdict, and
		# this covers a one-off crash as readily as a missing feature. The agent dying on a
		# signal looks exactly like this, and until the wrapper above was fixed it did not even
		# leave a non-zero status behind. Hiding the row and calling it permanent because the
		# agent segfaulted once is the same mistake the denylist exists to prevent - so this is
		# the app saying "I could not get an answer", which stays offerable like timedOut.
		printf 'probeFailed\tthe bundled agent did not answer; try again\n'
		return 1
	fi

	# Fields 4 and 5 are APPENDED, never inserted: every caller reads this with `cut -f1..3`,
	# and the failure returns above still emit one or two fields. A caller that does not know
	# about the language fields keeps working, and one that asks for f4/f5 on a failure path
	# gets the empty string - the same contract `_window` already has.
	#
	# KEEP THE LANGUAGE LIST LAST. It is the only field whose value is not a bare identifier or
	# a number, so it is the only one that could ever carry a stray tab. Last, a stray tab
	# truncates field 5 and nothing else; with a field 6 after it the same tab would shift every
	# following field and corrupt them silently. Add new fields BEFORE it, not after.
	printf '%s\t%s\t%s\t%s\t%s\n' \
		"$_reason" "${_summary:-$_reason}" "$_window" "$_locale_ok" "$_langs"
	[ "$_reason" = "available" ]
}

# foundation_offerable <reason> -> 0 when the picker should LIST the on-device model.
# Shown when it is usable, and when it is not usable for a reason the user can act on OR that may
# resolve itself - hiding the row in those cases would leave no way to discover the feature exists
# or how to enable it. Hidden only for a verdict that will not change while this Mac and this
# build stay the same.
#
# `unknown` is LISTED deliberately: it means a reason this build does not recognize, which a newer
# macOS can introduce at any time, and treating "we do not know" as "never" would silently retire
# the feature on exactly the systems that just gained a new state. It is listed as unavailable and
# the load handler says so without claiming permanence.
foundation_offerable() {
	# A DENYLIST, and that direction is the whole point. Reasons arrive from the agent verbatim -
	# nothing maps an unrecognized one to `unknown` - so an allowlist would hide the row for any
	# code added to mlx-agent later, which its docs explicitly invite ("codes are added rather
	# than renamed"). That is the failure this function exists to prevent: reading ignorance as
	# "never" retires the feature on exactly the systems that just gained a new state.
	#
	# Named here are only the verdicts that will not change without the machine changing. Note
	# `generationFailed` is NOT one of them: the agent's own guidance is "treat as unusable,
	# `detail` says why", and this diff's language section shows it firing on a benign prompt in
	# an unsupported language - a prompt artifact, not grounds for retiring the engine. (Bare
	# `fm-check` cannot return it today, so this is about intent, not reachability.)
	case "$1" in
		deviceNotEligible|osTooOld|notBuilt) return 1 ;;
		*) return 0 ;;
	esac
}

# foundation_open_settings - open the pane that owns the Apple Intelligence switch.
#
# No fallback, because there is no way to write one that runs: `open` returns 0 as soon as
# LaunchServices accepts the SCHEME and never waits for the pane id to resolve, so a bogus pane
# and a good one are indistinguishable by exit code (measured). A `||` branch here would be dead
# code that reads like a safety net. Verified on macOS 26.6: com.apple.Siri-Settings.extension
# is SiriPreferenceExtension.appex, the "Apple Intelligence & Siri" pane.
foundation_open_settings() {
	/usr/bin/open "x-apple.systempreferences:com.apple.Siri-Settings.extension"
}

# model_bytes <path> [engine] -> on-disk size in bytes (0 if unknown).
# GGUF is one file; MLX is the SUM of its shards. find (not a top-level glob) so a repo that
# nests its shards is still measured - a 30GB model reported as 0 would silently defeat the
# RAM-pressure warning, which is the one guard standing between the user and a swap storm.
model_bytes() {
	local _eng="${2:-$(model_engine "$1")}"
	case "$_eng" in
		gguf) /usr/bin/stat -f%z -L "$1" 2>/dev/null || echo 0 ;;
		mlx)
			local _total=0 _st _sz
			while IFS= read -r _st; do
				[ -n "$_st" ] || continue
				_sz=$(/usr/bin/stat -f%z -L "$_st" 2>/dev/null || echo 0)
				_total=$((_total + _sz))
			done <<EOF
$(/usr/bin/find -L "$1" -name "*.safetensors" -type f 2>/dev/null)
EOF
			echo "$_total" ;;
		*) echo 0 ;;
	esac
}

# ── Recently opened models ────────────────────────────────────────────────────
#
# The picker lists what it finds in the standard caches. A model the user opened from anywhere
# ELSE is not in any of them, so this list is the only reason such a model appears in the
# picker at all - lose it and the model silently drops out of the UI the next time the dialog
# opens, while still sitting on disk exactly where the user put it.
#
# It lives in the app's own settings file, a THIRD subtree beside /servers and /agents. It used
# to live in the com.abracode.Cadabra preferences domain, written with PlistBuddy straight at
# the file - which is the one thing the note above $cadabra_settings says not to do, because
# cfprefsd owns that domain and rewrites it wholesale on its own schedule. Read and write also
# disagreed about where it was: `defaults read` asks cfprefsd, PlistBuddy wrote the file, so a
# path added by one launch could be missing from the very next read and reappear later. Here
# both ends are plister on one file, which is also the only spelling a test can observe: a
# domain is keyed by uid, so it is the developer's own preferences however $HOME is set.
#
# NOTHING HERE MIGRATES THE OLD LOCATION. Cadabra has not shipped, so the only people with a
# list in the preferences domain are the ones who built it - and carrying a one-time move
# inside the app would mean shipping it forever, running on every launch, for a case that
# stops existing at release. Tools/migrate_recent_models.sh does it once, from outside.

CAD_RECENT_MODELS_KEY="recent-models"
CAD_RECENT_MODELS_MAX=10

# model_recents_list -> the remembered paths, newest first, one per line.
#
# A READ PATH, so it must not create anything. Merely asking what the recents are must not be
# what creates the settings file.
#
# One per line, which is why model_recents_add does NOT round-trip through this: a path may
# contain a newline on every filesystem macOS mounts, and a line-based round trip turns one
# such model into two bogus entries and loses the real one.
model_recents_list() {
	"$plister" iterate "$cadabra_settings" "/$CAD_RECENT_MODELS_KEY" get string / 2>/dev/null
}

# model_recents_add <path> - put a path at the head of the list, deduplicated, capped.
#
# STAGED IN A SCRATCH FILE AND INSTALLED IN ONE WRITE. The obvious shape - remove the array,
# insert an empty one, append the survivors - is up to twelve whole-file read-modify-write
# cycles against a file with THREE owners (/servers, /agents, /recent-models) and no locking
# anywhere. Measured on this machine: sixty concurrent MCP setting writes against one recents
# rewrite lost twenty-five of them. This runs on the chat-window-open path, which a user
# triggers twice with two quick Cmd-N, so that is a real collision rather than a theoretical
# one. Two writes to the shared file is not zero, but it is a window of microseconds rather
# than one that spans a dozen sequential rewrites.
#
# The survivors are copied ITEM BY ITEM out of the old array rather than read back as text,
# so a path containing a newline or a tab survives intact - the whole reason plister has a
# "copy" directive.
model_recents_add() { # <path>
	[ -n "$1" ] || return 0
	cadabra_settings_init || return 1
	local _stage _count _i _p _n
	_stage="${TMPDIR:-/tmp}/cadabra-recents-$$.plist"
	/bin/rm -f "$_stage"
	"$plister" set dict "$_stage" / >/dev/null 2>&1 || return 1
	"$plister" insert "list" array "$_stage" / >/dev/null 2>&1 || { /bin/rm -f "$_stage"; return 1; }
	# The new path first: this is a most-recently-used list, and that is the whole ordering rule.
	"$plister" append string "$1" "$_stage" /list >/dev/null 2>&1
	_n=1
	_count=$("$plister" get count "$cadabra_settings" "/$CAD_RECENT_MODELS_KEY" 2>/dev/null)
	case "${_count:-}" in ''|*[!0-9]*) _count=0 ;; esac
	_i=0
	while [ "$_i" -lt "$_count" ] && [ "$_n" -lt "$CAD_RECENT_MODELS_MAX" ]; do
		_p=$("$plister" get string "$cadabra_settings" "/$CAD_RECENT_MODELS_KEY/$_i" 2>/dev/null)
		_i=$((_i + 1))
		[ -n "$_p" ] || continue
		[ "$_p" = "$1" ] && continue
		"$plister" append string "$_p" "$_stage" /list >/dev/null 2>&1
		_n=$((_n + 1))
	done
	# Verified before it is installed. Every plister call here is silenced, so without this a
	# file that exists but cannot be parsed would empty the list and still report success.
	_count=$("$plister" get count "$_stage" /list 2>/dev/null)
	if [ "${_count:-0}" != "$_n" ]; then
		/bin/rm -f "$_stage"
		return 1
	fi
	"$plister" set copy "$_stage" /list "$cadabra_settings" "/$CAD_RECENT_MODELS_KEY" >/dev/null 2>&1 \
		|| "$plister" insert "$CAD_RECENT_MODELS_KEY" copy "$_stage" /list "$cadabra_settings" / >/dev/null 2>&1
	/bin/rm -f "$_stage"
	return 0
}

# calculate_total_server_ram()
# Sums model sizes (from /server-info) for all currently live registered servers.
# Prints the total in bytes.
#
# NOTE (two engines): this counts llama-server registrations only. A loaded MLX model holds
# its weights inside mlx-agent, which registers no server, so it is invisible here and the
# advisory under-reports when an MLX chat is open. Accepted deliberately: this is a soft
# 75% warning and the agent's own 90% hard gate is what actually refuses a load.
calculate_total_server_ram() {
    local total=0
    [ ! -f "$prefs" ] && echo "0" && return 0

    local host_pids=$("$plister" get keys "$prefs" "/server-hosts" 2>/dev/null)
    local _ctr_host_pid
    while IFS= read -r _ctr_host_pid; do
        [ -z "$_ctr_host_pid" ] && continue
        /bin/ps -p "$_ctr_host_pid" > /dev/null 2>&1 || continue
        local server_pids=$("$plister" get keys "$prefs" "/server-hosts/$_ctr_host_pid" 2>/dev/null)
        local _ctr_server_pid
        while IFS= read -r _ctr_server_pid; do
            [ -z "$_ctr_server_pid" ] && continue
            kill -0 "$_ctr_server_pid" 2>/dev/null || continue
            local _ctr_size=$("$plister" get string "$prefs" "/server-info/$_ctr_server_pid/size" 2>/dev/null)
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

    local ram_bytes=$(/usr/sbin/sysctl -n hw.memsize 2>/dev/null)
    [ -n "$ram_bytes" ] && [ "$ram_bytes" -gt 0 ] 2>/dev/null || return 0

    local ram_threshold=$(( ram_bytes * 3 / 4 ))
    local current_load=$(calculate_total_server_ram)
    local new_total=$(( current_load + model_bytes ))

    [ "$new_total" -le "$ram_threshold" ] 2>/dev/null && return 0

    local ram_fmt=$(format_bytes "$ram_bytes")
    local model_fmt=$(format_bytes "$model_bytes")
    local threshold_fmt=$(format_bytes "$ram_threshold")
    local new_fmt=$(format_bytes "$new_total")

    local message
    if [ "$current_load" -gt 0 ] 2>/dev/null; then
        local current_fmt=$(format_bytes "$current_load")
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

    local host_pids=$("$plister" get keys "$prefs" "/server-hosts" 2>/dev/null)
    local _act_host_pid
    while IFS= read -r _act_host_pid; do
        [ -z "$_act_host_pid" ] && continue
        /bin/ps -p "$_act_host_pid" > /dev/null 2>&1 || continue
        local server_pids=$("$plister" get keys "$prefs" "/server-hosts/$_act_host_pid" 2>/dev/null)
        local _act_server_pid
        while IFS= read -r _act_server_pid; do
            [ -z "$_act_server_pid" ] && continue
            kill -0 "$_act_server_pid" 2>/dev/null || continue
            local _act_running_model=$("$plister" get string "$prefs" "/server-hosts/$_act_host_pid/$_act_server_pid" 2>/dev/null)
            if [ "$_act_running_model" = "$model_path" ]; then
                echo "Same model already running, activating existing chat window"
                local _act_chat_window=$("$plister" get string "$prefs" "/server-info/$_act_server_pid/dialog" 2>/dev/null)
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
