# aichat.acp.agents.library.sh
#
# Finding and describing LOCAL ACP agents that are not the bundled mlx-agent - opencode,
# the Claude Code ACP adapter, Gemini CLI, or anything the user points us at. Sourced by the
# external-agent dialog scripts and by aichat.chat.init.sh.
#
# Why a catalog at all, when the transport only needs an argv: because "type the command
# line for an ACP agent" is a question almost nobody can answer from memory. The catalog
# turns the common cases into one click and leaves the argv editable for everything else.
#
# WHAT IS AND IS NOT VERIFIED HERE. Three invocations were confirmed by running them on this
# machine: `opencode acp` answers `initialize` with protocolVersion 1 and agentInfo
# OpenCode/1.17.13, `kilo acp` answers as Kilo/7.1.23, and `grok agent stdio` answers with
# protocolVersion 1 but no agentInfo at all. The other catalog rows carry the
# invocations those projects document, as EDITABLE DEFAULTS rather than facts - an agent that
# changed its flags would leave a row that looks authoritative and is wrong. The dialog
# therefore probes whatever argv it is about to store, and the probe's answer is what gets
# believed. Treat a catalog row as a starting point for the argv field, never as a promise.
#
# The search covers PATH plus the places these tools install themselves when PATH is not
# what a GUI app inherits. That matters here more than usual: a launchd-launched .app gets
# a minimal PATH with none of ~/.local/bin, ~/.opencode/bin, /opt/homebrew/bin or ~/.bun/bin
# on it, so an agent the user runs happily in Terminal is invisible to us unless we look.

# Sourced HERE rather than left to every caller. The stored-selection helpers below keep their
# own accessors and no longer touch mcp_prefs_*, but they still need $plister, which the MCP
# library pulls in from aichat.library.sh - and the dialog scripts that source this one rely on
# the MCP helpers being in scope too.
#
# A caller that forgets a dependency here does not get an error - it gets `command not found`
# on stderr and a silently unwritten setting. That is exactly how acp_agent_disable became a
# no-op in aichat.select.local.model.ok.sh, which sources the model library but not this one's
# dependency: the external agent stayed enabled and hijacked the model the user had just
# picked. The MCP library is include-guarded, so sourcing it twice is free.
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.mcp.servers.library.sh"

# The built-in agent list is DATA, not code: Resources/acp-agents.json, read through
# acp_catalog.py. See acp_agent_catalog below for why it moved out of this file.
acp_python="$OMC_APP_BUNDLE_PATH/Contents/Library/Python/bin/python3"
acp_catalog_py="$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/acp_catalog.py"

# acp_md_paragraphs
# Reads markdown on stdin and rewrites it into the only multi-line form this dialog's text
# renderer actually shows.
#
# The panes render markdown into a single SwiftUI Text (AttributedString .full), which is a
# FLATTENED render: block structure is parsed and then thrown away. A blank line is a real
# paragraph break, so the parser consumes it and the two paragraphs are concatenated with
# nothing between them - ".../bin/opencode acp" + "Select a row to change it" came out as
# ".../bin/opencode acpSelect a row to change it" in the shipping dialog.
#
# The idiom that works, already used by the model-info and Hugging Face panes: end every line
# with a two-space markdown hard break, and replace each empty line with a U+2800 Braille
# blank. The Braille blank is not whitespace, so the line stays inside the paragraph and
# survives as a visible gap. Block syntax (fences, lists, headings) still will not render as
# blocks, so callers should stick to inline markup.
#
# A WHITESPACE-ONLY line counts as blank here. To the markdown parser a run of spaces is just
# as much a blank line as an empty one, so testing only for "" would leave it as a line whose
# hard break gets dropped, gluing its neighbors together - the very bug this exists to avoid.
acp_md_paragraphs() {
    /usr/bin/awk -v gap="$(printf '\342\240\200')" '{ if ($0 ~ /^[ \t]*$/) print gap "  "; else print $0 "  " }'
}

# Directories searched in addition to PATH, in priority order. A GUI app's PATH is
# typically /usr/bin:/bin:/usr/sbin:/sbin, so everything a developer actually installs
# lands outside it.
#
# The per-tool directories are DISCOVERED rather than listed. Each of these tools digs its own
# hole in the home directory and drops a bin/ in it - ~/.opencode/bin, ~/.grok/bin,
# ~/.bun/bin, ~/.cargo/bin - and that list has no end, so an enumerated one is out of date the
# moment someone installs the next agent. This is what let `grok agent stdio` work perfectly
# when typed by hand while the catalog could not find grok at all.
#
# ~/.[!.]*/bin, not ~/.*/bin: the latter also matches "." and "..", which expand to ~/bin and
# /Users/bin. The -d guard would catch them, but only by luck of them not existing.
#
# Keep in step with acp_agent_env.py, which answers the neighboring question ("what PATH does
# an agent need to LAUNCH") with the same discovery.
acp_agent_search_dirs() {
    local d
    printf '%s\n' \
        /opt/homebrew/bin \
        /opt/homebrew/sbin \
        /usr/local/bin \
        "$HOME/.local/bin" \
        "$HOME/go/bin" \
        /usr/bin
    # ~/.local/bin is listed above AND matched by the glob below. The duplicate is deliberate:
    # it is a canonical user bin dir rather than one tool's private hole, so it keeps its place
    # ahead of /usr/bin. Dropping the fixed entry would silently demote it below the system
    # dirs. First match wins in acp_agent_which, so the repeat costs one -x probe.
    for d in "$HOME"/.[!.]*/bin; do
        [ -d "$d" ] && printf '%s\n' "$d"
    done
}

# acp_command_first_word <command-line>  ->  the executable word, quotes honored
#
# A QUOTED first argument is one word however many spaces it holds. Splitting
# `"/My Tools/agent" acp` on the first space would call the executable "/My, which then fails
# to resolve and reports a perfectly good agent as missing - and names it "My" in the window
# title. Quote-aware here rather than shelling out to shlex, because this runs on the window
# title path and must not depend on the bundled interpreter being present.
#
# This is the FIRST WORD, not a basename: callers that want a display name apply ${x##*/}
# themselves, and the ones resolving an executable need the path intact.
acp_command_first_word() {
    local cmd="$1" first
    case "$cmd" in
        \"*) first=${cmd#\"}; first=${first%%\"*} ;;
        \'*) first=${cmd#\'}; first=${first%%\'*} ;;
        *)   first=${cmd%% *} ;;
    esac
    printf '%s\n' "$first"
}

# acp_agent_which <executable-name>  ->  absolute path on stdout, or nothing (rc 1)
#
# PATH first so a user who deliberately shadows a tool wins, then the well-known dirs.
acp_agent_which() {
    local name="$1" dir found
    [ -n "$name" ] || return 1
    case "$name" in
        /*) [ -x "$name" ] && { printf '%s\n' "$name"; return 0; }; return 1 ;;
    esac
    found=$(command -v "$name" 2>/dev/null)
    if [ -n "$found" ] && [ -x "$found" ]; then
        printf '%s\n' "$found"
        return 0
    fi
    while IFS= read -r dir; do
        [ -x "$dir/$name" ] && { printf '%s\n' "$dir/$name"; return 0; }
    done <<EOF
$(acp_agent_search_dirs)
EOF
    return 1
}

# acp_agent_catalog  ->  TSV rows: id \t label \t command \t args \t url \t summary \t note
#
# The rows live in Resources/acp-agents.json and arrive here through acp_catalog.py. They used
# to be a heredoc in this function. Moving them out is what lets a row carry a URL and a
# one-line summary for the info pane, and lets "this agent takes no arguments" be an empty
# LIST rather than a single space smuggled through a tab-separated field - the hack that
# existed only because an empty field collapses under IFS whitespace and shifts every later
# field left, sliding prose into the argv column.
#
# acp_catalog.py owns that invariant now: it never emits an empty field, and "-" means absent.
# A human editing JSON therefore cannot reintroduce the bug, which a hand-maintained TSV
# invited every time it was touched.
#
# An unreadable catalog emits NOTHING, and says why on stderr rather than silently: the dialog
# then shows an empty list, which is an obvious failure, instead of a plausible partial one.
# The window title degrades on its own - acp_agent_stored_label already falls back to the
# command's basename when an id is not in the catalog.
acp_agent_catalog() {
    "$acp_python" "$acp_catalog_py" rows
}

# acp_agent_custom_template  ->  TSV: label \t url \t summary \t note
#
# The prose the dialog shows while editing an agent the user saved themselves, and the default
# name a new one gets. It is catalog data rather than a string in this file for the same reason
# the rows are: it is user-facing text plus a URL, and URLs move - three of the catalog's did.
#
# It lives OUTSIDE the agents list in acp-agents.json, behind its own subcommand, so it can
# never be picked up as an agent by something iterating the catalog. It used to be exactly
# that: a "Custom" row in the list, which meant a catalog entry describing a product that does
# not exist, and a special case in the link builder to stop it advertising "More about Custom".
acp_agent_custom_template() {
    "$acp_python" "$acp_catalog_py" custom
}

# acp_agent_scan  ->  TSV rows: id \t label \t status \t resolved-argv \t url \t summary \t note
#
# status is "found", "missing", "empty" or "custom". For a found row the argv is ready to
# store; for a missing one the argv column carries the un-resolved executable name so the
# dialog can still show what it would run; "empty" is a saved agent with no command typed into
# it yet, and the catalog's own custom row has no argv either - both carry "-".
#
# Two sources, in one format: the built-in catalog first, then the agents the user saved. They
# differ in what the argv column means, which is why the merge happens here rather than in
# acp_catalog.py. A catalog row names an EXECUTABLE that this function resolves to a path; a
# saved row already holds the whole command line the user typed, so it passes through
# unchanged and only its first word is looked up, to answer the Status column. Resolving a
# saved command would rewrite what the user typed underneath them.
#
# NEVER EMIT AN EMPTY FIELD HERE, for the same reason acp_catalog.py does not: tab is IFS
# *whitespace*, so a reader doing `IFS=<tab> read -r a b c ...` collapses two adjacent tabs
# into one separator and every field after the empty one shifts left - the note lands in the
# argv column and the caller runs it. Everything arriving from acp_catalog.py is already
# non-empty; the fields built HERE have to hold the line themselves.
acp_agent_scan() {
    local id label exe args url summary note path argv_tail cmd
    while IFS='	' read -r id label exe args url summary note; do
        [ -n "$id" ] || continue
        if [ "$id" = "custom" ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$label" "custom" "-" "$url" "$summary" "$note"
            continue
        fi
        # "-" is how the catalog spells "no arguments" (an empty JSON list). Anything else is
        # a real argv tail and gets a separating space; without this the stored command picks
        # up a trailing space and the field whose whole job is showing exactly what will run
        # shows something slightly different.
        case "$args" in
            "-"|"") argv_tail="" ;;
            *)      argv_tail=" $args" ;;
        esac
        if path=$(acp_agent_which "$exe"); then
            # Quote a resolved path that contains a space: this column is a COMMAND LINE that
            # shlex will re-split, so an unquoted "/Users/my name/.opencode/bin/opencode acp"
            # would become three argv entries and fail to launch.
            case "$path" in *\ *) path="\"$path\"" ;; esac
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$label" "found" "$path$argv_tail" "$url" "$summary" "$note"
        else
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$label" "missing" "$exe$argv_tail" "$url" "$summary" "$note"
        fi
    done <<EOF
$(acp_agent_catalog)
EOF
    # The user's own agents come last, in the order they were added, which is where the + button
    # appends them. They carry no url, summary or note - there is no vendor behind them to link
    # to and nothing for Cadabra to know about a command it was handed.
    while IFS='	' read -r id label cmd; do
        [ -n "$id" ] || continue
        if [ "$cmd" = "-" ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$label" "empty" "-" "-" "-" "-"
        elif acp_agent_which "$(acp_command_first_word "$cmd")" >/dev/null 2>&1; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$label" "found" "$cmd" "-" "-" "-"
        else
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$label" "missing" "$cmd" "-" "-" "-"
        fi
    done <<EOF
$(acp_custom_list)
EOF
}

# acp_agent_fill_table <table-id> [<id-to-select>]  ->  the row index of that id, or -1
#
# Repaints the agent list from scratch and reports where the interesting row landed. Every
# handler that changes the set of rows - init, +, -, and a rename - needs exactly this, and
# they need it to agree; three copies of the row format is how a hidden column ends up shifted
# in one of them.
#
# THE ROW FORMAT IS FOUR VALUES AGAINST TWO HEADERS. Columns 3 (the command) and 4 (the id) are
# HIDDEN, and the sibling handlers read them back as OMC_ACTIONUI_TABLE_10_COLUMN_3_VALUE and
# _4_VALUE. Adding a visible column shifts both indices here and in every one of those readers.
#
# It does NOT select the row: the caller decides that, because selecting programmatically does
# NOT fire the selection-changed action, so whoever selects also owns repainting the panes.
acp_agent_fill_table() {
    local table_id="$1" want_id="$2"
    local buffer="" row=-1 index=0
    local id label state argv url summary note shown stored_id stored_command
    stored_id=$(acp_agent_stored_id)
    stored_command=$(acp_agent_stored_command)
    [ -n "$want_id" ] || want_id="$stored_id"
    while IFS='	' read -r id label state argv url summary note; do
        [ -n "$id" ] || continue
        case "$state" in
            found)   shown="Ready" ;;
            missing) shown="Not found" ;;
            # A saved agent with no command typed into it yet. "Not found" would be a lie about
            # the machine when the truth is about the record: there is nothing to look for.
            empty)   shown="Not set" ;;
            *)       shown="Custom" ;;
        esac
        # A remembered command wins over the catalog default for its own row, so reopening the
        # dialog shows what is actually configured rather than silently reverting to the
        # default. A saved agent already carries its own command and needs no such override.
        if [ -n "$stored_command" ] && [ "$id" = "$stored_id" ]; then
            argv="$stored_command"
        fi
        [ "$id" = "$want_id" ] && row=$index
        index=$((index + 1))
        buffer="${buffer}${label}	${shown}	${argv}	${id}
"
    done <<EOF
$(acp_agent_scan)
EOF
    # set_rows and NOT remove_all_rows first. They are not equivalent: clearing unconditionally
    # drops the selection, while setElementRows keeps it whenever a NEW row still carries the
    # selected row's first column - so a repaint that does not disturb the selected agent leaves
    # the highlight where the user put it. A caller that wants the selection gone says so, with
    # omc_deselect, rather than getting it as a side effect of repainting.
    #
    # stdout discarded, and that is not tidiness: this function RETURNS the row index on stdout,
    # so every caller runs it inside $( ). Anything the dialog tool ever printed would be
    # captured along with the index, and the callers' `[ "$row" -ge 0 ]` would then fail with an
    # arithmetic error rather than a wrong answer.
    printf "%s" "$buffer" | "$dialog" "$OMC_ACTIONUI_WINDOW_UUID" "$table_id" omc_table_set_rows_from_stdin >/dev/null 2>&1
    printf '%s\n' "$row"
}

# acp_path_writable <dir> - could we write <dir>, or create it under the nearest parent that
# already exists? Plain `test -w` is false for a path that does not exist YET, which would
# report a perfectly good prefix as unwritable merely because npm has not created
# lib/node_modules inside it.
#
# TERMINATION IS THE WHOLE TRICK HERE. `${d%/*}` is a documented NO-OP once there is no "/"
# left in the string, so the obvious `while ...; do d=${d%/*}; done` spins forever on any
# relative, slash-less, non-existent component - and this runs on the UI thread's script, so
# that is a hung dialog, not a slow one. Every path out of the loop is therefore explicit: a
# component that exists returns, a slash-less one returns, and the parent is compared against
# the child so a step that fails to shorten cannot repeat.
acp_path_writable() {
    local d="$1" parent
    [ -n "$d" ] || return 1
    while :; do
        # A dangling or looping symlink is not "missing": -e is false for it, but creating a
        # directory at that path still fails, so it must not fall through to the walk-up and
        # inherit its parent's answer.
        [ -L "$d" ] && [ ! -e "$d" ] && return 1
        # -d as well as -w. A regular file sitting where a directory belongs is not writable in
        # the sense this asks about - mkdir under it fails with ENOTDIR - and -w alone would
        # cheerfully call it writable.
        [ -e "$d" ] && { [ -d "$d" ] && [ -w "$d" ]; return $?; }
        case "$d" in
            */*) parent=${d%/*}; [ -n "$parent" ] || parent="/" ;;
            *)   return 1 ;;
        esac
        [ "$parent" = "$d" ] && return 1
        d="$parent"
    done
}

# acp_agent_install_hint <catalog-id>  ->  install instructions for a missing row, or nothing
#
# Deliberately NOT part of the catalog note, because the right instructions depend on what is
# actually on this Mac. The npm-distributed row is what forced this out of the note: telling
# someone to run `npm install -g` when they have no npm at all sends them into an error
# message instead of an install. So npm is looked up FIRST, and through acp_agent_which -
# which searches the dirs a GUI-launched app cannot see - rather than trusting the PATH this
# script happens to have.
#
# Homebrew gets the same treatment for the same reason, one level down. `brew install node`
# is the shortest route to npm FOR SOMEONE WHO ALREADY HAS BREW, and useless noise for anyone
# else - Cadabra is not a developer tool and brew is not on a stock Mac. So the no-npm branch
# splits again: brew present says `brew install node`, brew absent points at the nodejs.org
# installer, which is the route that works for someone who has installed nothing. Checked
# through acp_agent_which, which covers /opt/homebrew/bin and /usr/local/bin and so answers
# correctly on both Apple Silicon and Intel.
#
# And a third time for the global prefix, which is the one that actually bit. `npm install -g`
# writes to <prefix>/lib/node_modules, and on a Mac where Node came from the nodejs.org
# installer that is /usr/local/lib/node_modules, owned by root - so the plain command dies with
# EACCES. We do NOT answer that with sudo. Running npm as root is what leaves root-owned files
# in ~/.npm/_cacache, which then breaks every later npm command for that user; it is a bug we
# hit from the other end during development, and telling a consumer to sudo their way past a
# permissions error is how they get there. The unwritable branch installs into the user's own
# home instead, which needs no password and cannot poison the cache.
#
# ~/.npm-global is not an arbitrary choice: its bin directory matches the ~/.[!.]*/bin pattern
# that acp_agent_search_dirs and acp_agent_env.py already discover, so an agent installed there
# is found and launchable with no PATH edit by the user. Verified end to end - installed, the
# row flips from "Not found" to "Ready" with the absolute path, and the probe answers.
#
# The prefix comes from `npm config get prefix` rather than being derived from npm's own path,
# because a user who has already pointed npm at a writable prefix should get the plain command.
# Measured at ~75ms, and only on selecting this one row.
#
# Only a row that installs through a package manager has a hint. Every other id returns
# nothing, and the caller then shows the catalog note by itself.
#
# Inline code spans, not a fenced block: this text goes through acp_md_paragraphs, which
# appends a hard break to every line including the fence delimiters. A one-line command has
# no need of a block anyway.
acp_agent_install_hint() {
    local pkg npm_bin prefix moddir
    case "$1" in
        claude-code-acp) pkg="@agentclientprotocol/claude-agent-acp" ;;
        *) return 0 ;;
    esac
    npm_bin=$(acp_agent_which npm 2>/dev/null)
    if [ -n "$npm_bin" ]; then
        # First line only, and it has to be an absolute path. npm normally prints just the
        # value, but a config warning or a stray line would otherwise be pasted into a
        # sentence as though it were a directory. Anything else means "we do not know".
        prefix=$("$npm_bin" config get prefix 2>/dev/null | /usr/bin/head -n 1)
        case "$prefix" in
            /*) ;;
            *) prefix="" ;;
        esac
        moddir="$prefix/lib/node_modules"
        if [ -n "$prefix" ] && acp_path_writable "$moddir"; then
            printf 'Install it with `npm install -g %s`, then press Test.\n' "$pkg"
        elif [ -n "$prefix" ]; then
            printf 'Install it for yourself with `npm install -g --prefix ~/.npm-global %s`, then press Test. The plain `npm install -g` would have to write to %s, which belongs to root on this Mac; installing into your home folder instead needs no password, and Cadabra looks there.\n' "$pkg" "$moddir"
        else
            # Prefix unknown, so say nothing about WHY. The user-scoped command is correct
            # either way; inventing a reason - naming a directory we never established - would
            # be a confident-sounding lie in the one place the user is trying to follow along.
            printf 'Install it for yourself with `npm install -g --prefix ~/.npm-global %s`, then press Test. That keeps it in your home folder, so it needs no password, and Cadabra looks there.\n' "$pkg"
        fi
    elif acp_agent_which brew >/dev/null 2>&1; then
        printf 'This one installs through npm, which comes with Node.js and is not on this Mac. Install Node first with `brew install node`, then run `npm install -g %s` and press Test.\n' "$pkg"
    else
        printf 'This one installs through npm, which comes with Node.js and is not on this Mac. Download the macOS installer from nodejs.org and run it, then in Terminal run `npm install -g --prefix ~/.npm-global %s` and press Test. That installer puts Node under /usr/local, which belongs to root, so the --prefix keeps the agent in your home folder and avoids needing a password.\n' "$pkg"
    fi
}

# --- Stored selection -------------------------------------------------------------------
#
# WHERE THIS LIVES: ~/Library/Application Support/Cadabra/settings.plist.
#
# This is application data the user configured, not a macOS preference, so it belongs in
# Application Support next to History/ and the rest of Cadabra's own state - not in a
# preferences domain, and not in a new plist per feature.
#
# It is emphatically NOT in com.abracode.Cadabra.plist. That domain is written by the system
# on the app's behalf - window frames, recent items, the autosaved dialog frame this project
# already fights with - through cfprefsd, which caches the whole domain in memory and rewrites
# it wholesale on its own schedule. A script writing that same file behind cfprefsd's back
# either loses its write or clobbers the system's, and the visible result is a preferences
# file that looks corrupted.
#
# The MCP server settings now live in this same file, under /servers and /allow-network,
# which is what leaving these keys at /agents/... was for. TWO SUBTREES, TWO OWNERS, ONE FILE:
# neither library may assume it owns the file. See cadabra_settings in aichat.library.sh.
#
#   /agents/external/enabled : bool    - use the external agent instead of bundled mlx-agent
#   /agents/external/id      : string  - catalog id, so the dialog can re-select the row
#   /agents/external/command : string  - the command line AS TYPED, split with shlex at launch
#   /agents/external/verifiedCommand : string - the command Test last actually spoke to
#   /agents/external/verifiedName    : string - what the agent called itself that time
#   /agents/external/verifiedVersion : string - and the version it reported
#
# The command is stored as one string rather than an argv array on purpose: it is what the
# user typed and what the dialog shows back, so there is no place for a round trip through
# two representations to lose a quote. Splitting happens once, in acp_transport_json.py.
#
# The agent's working directory is deliberately NOT stored here - it reuses
# /servers/local/project, the workspace the user already chose for the local MCP server, so
# "the folder Cadabra is working in" stays one concept with one setting.

# $mcp_app_support is the base library's one definition of ~/Library/Application Support/
# Cadabra - the same root history_root, Sessions/ and inspect/ hang off. Reused rather than
# rebuilt from $HOME so there is a single place to change if it ever moves. Its name predates
# it being general; it is the app support root, not an MCP thing.
#
# NOTE THE SPACE in "Application Support": every expansion of this must stay quoted.
acp_prefs="$cadabra_settings"

# acp_prefs_init_if_missing - create the directory and an empty root dict, once
#
# `plister insert` cannot create the file it inserts into; only `set dict <file> /` can. Without
# this every write below no-ops AND RETURNS SUCCESS, which is exactly how the selection used to
# vanish silently on a profile that had never opened the Tools dialogs.
acp_prefs_init_if_missing() {
    cadabra_settings_init
}

# The four accessors. Every read and write goes through one of these, so the file path and
# the "create it before writing" rule each have exactly one home.
acp_prefs_get_value() {
    "$plister" get value "$acp_prefs" "/$1" 2>/dev/null
}

acp_prefs_get_string() {
    "$plister" get string "$acp_prefs" "/$1" 2>/dev/null
}

acp_prefs_set_bool() {
    acp_prefs_init_if_missing || return 1
    "$plister" set bool "$2" "$acp_prefs" "/$1" 2>/dev/null
}

acp_prefs_set_string() {
    acp_prefs_init_if_missing || return 1
    "$plister" set string "$2" "$acp_prefs" "/$1" 2>/dev/null
}

# acp_agent_enabled  ->  "true" | "false"  (default false: the bundled agent stays the default)
acp_agent_enabled() {
    local val
    val=$(acp_prefs_get_value agents/external/enabled)
    case "$val" in true) echo true ;; *) echo false ;; esac
}

# acp_agent_stored_command  ->  the stored command line, or nothing
acp_agent_stored_command() {
    acp_prefs_get_string agents/external/command
}

# acp_agent_stored_id  ->  the stored catalog id, or nothing
acp_agent_stored_id() {
    acp_prefs_get_string agents/external/id
}

# acp_agent_stored_label  ->  a short name for the window title and status line
#
# Three sources, in order: the name the user gave a saved custom agent, the catalog's label
# for a built-in one, and otherwise the command's own basename - which is the right answer for
# an unsaved ad-hoc command, where the binary's name IS what the user calls it. Never empty: a
# blank window title reads as a broken window.
acp_agent_stored_label() {
    local id cmd first saved cat_id cat_label rest
    id=$(acp_agent_stored_id)
    cmd=$(acp_agent_stored_command)
    case "$id" in
        "")       ;;
        custom)   ;;    # the bare id is an ad-hoc command with no record and no name
        custom:*) saved=$(acp_custom_get "$id" label)
                  [ -n "$saved" ] && { printf '%s\n' "$saved"; return 0; } ;;
        *)        while IFS='	' read -r cat_id cat_label rest; do
                      [ "$cat_id" = "$id" ] && { printf '%s\n' "$cat_label"; return 0; }
                  done <<EOF
$(acp_agent_catalog)
EOF
                  ;;
    esac
    first=$(acp_command_first_word "$cmd")
    first=${first##*/}
    [ -n "$first" ] && printf '%s\n' "$first" || printf 'External agent\n'
}

# acp_agents_ensure_root - the file, and /agents inside it, created only when actually missing
#
# `plister insert <key> dict` on a key that ALREADY exists replaces it with a fresh empty
# dictionary, silently discarding whatever was stored under it. Measured: calling the
# unguarded version from acp_agent_disable wiped the remembered command every time the user
# switched back to a local model. So test first with `get type`, which exits non-zero for a
# missing path, and insert only then.
#
# /agents now has two children with different owners - external (the live selection) and
# custom (the user's saved agents) - so the shared step is factored out here. An unguarded
# insert of /agents from either one would take the other's subtree with it.
acp_agents_ensure_root() {
    # The FILE first - see acp_prefs_init_if_missing for why an insert alone is not enough.
    acp_prefs_init_if_missing || return 1
    "$plister" get type "$acp_prefs" /agents >/dev/null 2>&1 \
        || "$plister" insert agents dict "$acp_prefs" / >/dev/null 2>&1
}

# acp_agent_ensure_tree - create /agents/external only when it is actually missing
acp_agent_ensure_tree() {
    acp_agents_ensure_root || return 1
    "$plister" get type "$acp_prefs" /agents/external >/dev/null 2>&1 \
        || "$plister" insert external dict "$acp_prefs" /agents >/dev/null 2>&1
}

# acp_agent_store <id> <command-line>  - remember a choice and switch to it
acp_agent_store() {
    acp_agent_ensure_tree
    "$plister" get type "$acp_prefs" /agents/external/enabled >/dev/null 2>&1 \
        || "$plister" insert enabled bool true "$acp_prefs" /agents/external >/dev/null 2>&1
    "$plister" get type "$acp_prefs" /agents/external/id >/dev/null 2>&1 \
        || "$plister" insert id string "$1" "$acp_prefs" /agents/external >/dev/null 2>&1
    "$plister" get type "$acp_prefs" /agents/external/command >/dev/null 2>&1 \
        || "$plister" insert command string "$2" "$acp_prefs" /agents/external >/dev/null 2>&1
    acp_prefs_set_bool agents/external/enabled true
    acp_prefs_set_string agents/external/id "$1"
    acp_prefs_set_string agents/external/command "$2"
}

# acp_agent_record_verified <command-line> <name> <version>
#
# Remembers what the agent CALLED ITSELF the last time Test actually spoke to it. This is the
# only identity Cadabra can show without a live bridge from the chat element: the transport
# knows the agent's real name, version and pid, but nothing carries them back out to a script.
#
# Stored against the command it was measured with, and read back only when that still matches
# what is configured, so editing the field to a different agent cannot leave the old agent's
# version on screen. Flat keys rather than a nested dict: one more level would need one more
# guarded insert for the same information.
acp_agent_record_verified() {
    acp_agent_ensure_tree
    local key
    for key in verifiedCommand verifiedName verifiedVersion; do
        "$plister" get type "$acp_prefs" "/agents/external/$key" >/dev/null 2>&1 \
            || "$plister" insert "$key" string "" "$acp_prefs" /agents/external >/dev/null 2>&1
    done
    acp_prefs_set_string agents/external/verifiedCommand "$1"
    acp_prefs_set_string agents/external/verifiedName "$2"
    acp_prefs_set_string agents/external/verifiedVersion "$3"
}

# acp_agent_display_label  ->  the label plus whatever the agent called itself, when known
#
# "opencode 1.17.13" once Test has run against the configured command, "opencode" before that
# or after the command is edited. Never empty, for the same reason acp_agent_stored_label is
# not: this feeds a window's info line and a blank one reads as a bug.
acp_agent_display_label() {
    local label verified_cmd name version suffix
    label=$(acp_agent_stored_label)
    verified_cmd=$(acp_prefs_get_string agents/external/verifiedCommand)
    [ -n "$verified_cmd" ] && [ "$verified_cmd" = "$(acp_agent_stored_command)" ] || {
        printf '%s\n' "$label"
        return 0
    }
    name=$(acp_prefs_get_string agents/external/verifiedName)
    version=$(acp_prefs_get_string agents/external/verifiedVersion)
    # An agent distributed on npm may answer with its full package specifier rather than a
    # friendly name: the Claude adapter reports "@agentclientprotocol/claude-agent-acp".
    # A scope-qualified path is never what a user calls the tool and is far too long for a
    # window title, so keep only the last segment. Bare names contain no "/" and are
    # untouched. Normalizing HERE rather than in acp_agent_record_verified keeps what the
    # agent actually said intact in the plist, so this stays a presentation choice.
    name=${name##*/}
    # The agent's own name only earns a place when the label does not ALREADY CONTAIN it, case
    # insensitively. Equality is not enough in either direction: the catalog says "opencode"
    # and the agent answers "OpenCode", so a literal test gives "opencode (OpenCode) 1.17.13";
    # and the catalog label "Claude Code (ACP adapter)" already contains the agent's "Claude
    # Code", which is what that adapter answered with before it was renamed, so a merely
    # case-folded test gives "Claude Code (ACP adapter) (Claude Code) 1.0.4"
    # - the same nonsense one row over. grok reports no name at all, so this collapses to the
    # catalog label alone, which is the honest answer rather than an invented one.
    local lc_name lc_label
    lc_name=$(printf '%s' "$name" | /usr/bin/tr '[:upper:]' '[:lower:]')
    lc_label=$(printf '%s' "$label" | /usr/bin/tr '[:upper:]' '[:lower:]')
    suffix=""
    # The quoted "$lc_name" inside the expansion keeps a name containing * or ? from being
    # treated as a pattern; unquoted, an agent called "*" would match every label.
    [ -n "$name" ] && [ "${lc_label#*"$lc_name"}" = "$lc_label" ] && suffix=" ($name)"
    [ -n "$version" ] && suffix="${suffix} ${version}"
    printf '%s\n' "${label}${suffix}"
}

# acp_agent_disable - fall back to the bundled mlx-agent, keeping the remembered command
#
# Called when the user picks a local model, so the two choices cannot both be live. The
# command and id survive, so re-enabling does not mean retyping.
acp_agent_disable() {
    acp_agent_ensure_tree
    "$plister" get type "$acp_prefs" /agents/external/enabled >/dev/null 2>&1 \
        || "$plister" insert enabled bool false "$acp_prefs" /agents/external >/dev/null 2>&1
    acp_prefs_set_bool agents/external/enabled false
}

# --- Custom agents the user saved -------------------------------------------------------
#
#   /agents/custom       : array of { id, label, command }
#   /agents/customNextId : integer - the next id to mint
#
# WHY AN ARRAY AND NOT A DICTIONARY KEYED BY ID. The order of these is the order they appear
# in the list, and the order the user put them in; a dictionary has no order, so the list
# would reshuffle itself on every read. plister can search an array by a sub-item value
# (`find string <id> <file> /agents/custom /id` answers with the index), so keying by id costs
# one lookup rather than a data structure.
#
# IDS ARE MINTED AND NEVER REUSED, which is the whole reason customNextId exists rather than
# deriving an id from the array length or the label. The live selection stores an id in
# /agents/external/id, so a reused id would silently re-point it: remove the agent that
# selection names, add a different one, and the window would come back configured as something
# the user never chose.
#
# The counter alone is not enough to guarantee that, and acp_custom_add explains why - it is
# treated as a hint and reconciled against the ids actually in use.
#
# An id is "custom:<n>". The bare "custom" is a different thing and still valid: an ad-hoc
# command typed over a built-in row and committed without ever being saved as an agent. It has
# no record, so it has no name.
#
# EVERY READ KEEPS ITS 2>/dev/null, and not only to be quiet. plister cannot render an EMPTY
# string and prints "Plister error: problem converting UTF-16 string to UTF-8" - on stderr,
# with exit status 0. Redirected, an empty value reads back as empty and all is well; merge
# the streams and that sentence becomes the agent's command.

# acp_custom_ensure_tree - the array and the counter, created only when actually missing
acp_custom_ensure_tree() {
    acp_agents_ensure_root || return 1
    "$plister" get type "$acp_prefs" /agents/custom >/dev/null 2>&1 \
        || "$plister" insert custom array "$acp_prefs" /agents >/dev/null 2>&1
    "$plister" get type "$acp_prefs" /agents/customNextId >/dev/null 2>&1 \
        || "$plister" insert customNextId integer 1 "$acp_prefs" /agents >/dev/null 2>&1
}

# acp_clean_one_line <text>  ->  one line, no tabs, no leading or trailing spaces
#
# Labels and commands reach the dialog as TSV, through a table whose columns are split on tab.
# One tab pasted into a name would shift every later column, which in this table means the
# command sliding out of the column the OK handler reads - the same class of bug the catalog
# moved to JSON to escape. Cleaning on the WAY IN means it cannot be stored, so no reader has
# to defend against it.
#
# INTERIOR RUNS ARE LEFT ALONE, and that is not fussiness. This also cleans COMMAND LINES, and
# a command line's spacing is significant inside quotes: `--system "Be  concise"` is a
# different argument from `--system "Be concise"`, and `"/My  Tools/agent"` is a path that
# either exists or does not. Squeezing them - which `awk '{ $1=$1; print }'` does as a side
# effect of re-splitting the record - silently rewrote what the user typed.
#
# LC_ALL=C on the tr, because under a UTF-8 locale it ABORTS on a byte that is not valid UTF-8
# ("tr: Illegal byte sequence") and emits only the prefix, so a name would be silently
# truncated at the first bad byte. In the C locale tr is byte-oriented and passes it through.
acp_clean_one_line() {
    printf '%s' "$1" | LC_ALL=C /usr/bin/tr '\t\r\n' '   ' | LC_ALL=C /usr/bin/sed -e 's/^ *//' -e 's/ *$//'
}

# acp_custom_count  ->  how many are saved, 0 when none ever were
#
# `get count` on a path that does not exist exits non-zero with no output, so a profile that
# has never saved one answers 0 rather than an empty string that would break the loop test.
acp_custom_count() {
    local n
    n=$("$plister" get count "$acp_prefs" /agents/custom 2>/dev/null)
    case "$n" in
        ""|*[!0-9]*) echo 0 ;;
        *)           echo "$n" ;;
    esac
}

# acp_custom_index <id>  ->  its array index, rc 1 when there is no such agent
#
# Callers resolve an id through here rather than passing an index around, because `plister
# remove` on an out-of-range index is a SILENT no-op (rc 0, nothing removed) and every index
# after a removal shifts down by one. An id survives that; an index does not.
acp_custom_index() {
    local idx
    [ -n "$1" ] || return 1
    idx=$("$plister" find string "$1" "$acp_prefs" /agents/custom /id 2>/dev/null)
    case "$idx" in
        ""|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$idx"
}

# acp_custom_field <index> <id|label|command>  ->  the value, or nothing
#
# Both arguments are pasted into a plist pseudopath, so both are checked - the index must be
# digits and the key must be one we own. The callers in this file all pass literals and a loop
# counter, but the function is in scope for every dialog script that sources this library, and
# "../../external/command" is a legal-looking field name.
acp_custom_field() {
    case "$1" in
        ""|*[!0-9]*) return 1 ;;
    esac
    case "$2" in
        id|label|command) ;;
        *)                return 1 ;;
    esac
    "$plister" get string "$acp_prefs" "/agents/custom/$1/$2" 2>/dev/null
}

# acp_custom_list  ->  TSV rows: id \t label \t command
#
# NEVER EMITS AN EMPTY FIELD, for the reason spelled out over acp_agent_scan: tab is IFS
# *whitespace*, so an empty one collapses into its neighbor and shifts the rest left. A record
# with no command yet - which is exactly what the + button creates - emits "-" for it, and an
# unnamed one falls back to the command's basename and then to its own id.
acp_custom_list() {
    local n i id label cmd
    n=$(acp_custom_count)
    i=0
    while [ "$i" -lt "$n" ]; do
        id=$(acp_custom_field "$i" id)
        label=$(acp_custom_field "$i" label)
        cmd=$(acp_custom_field "$i" command)
        i=$((i + 1))
        [ -n "$id" ] || continue
        if [ -z "$label" ]; then
            label=$(acp_command_first_word "$cmd")
            label=${label##*/}
        fi
        [ -n "$label" ] || label="$id"
        [ -n "$cmd" ] || cmd="-"
        printf '%s\t%s\t%s\n' "$id" "$label" "$cmd"
    done
}

# acp_custom_highest_id  ->  the largest <n> among the saved custom:<n> ids, or 0
acp_custom_highest_id() {
    acp_custom_list | /usr/bin/awk -F'\t' '
        $1 ~ /^custom:[0-9]+$/ { n = substr($1, 8) + 0; if (n > max) max = n }
        END { print max + 0 }'
}

# acp_custom_add <label> [<command>]  ->  the new id on stdout, or nothing (rc 1)
#
# THE COUNTER IS A HINT, NOT THE AUTHORITY. It is read, then written, then the record is
# appended, then three keys are inserted - five separate read-modify-write cycles on one file,
# with no lock. plister replaces the document wholesale, so a second writer between any two of
# them is a lost update: bump the counter, lose the write, and the NEXT add hands out an id
# that is already taken. That is the one failure this whole scheme exists to prevent, because
# the live selection stores an id - a duplicate silently re-points it at somebody else's
# record. And the same hole opens with no concurrency at all if the counter is ever lost or
# rewritten as a string, since both fall back to 1.
#
# So the id is max(counter, highest id in use + 1). The counter still does the real work -
# it is what makes a REMOVED id stay retired, which the records alone cannot know - while the
# records themselves make a duplicate impossible.
#
# The bump happens BEFORE the append, so a failed append burns an id, which is the harmless
# direction. And the record is read back before the id is returned: every write below can fail
# silently (plister exits 0 having written nothing when the file is not writable), and
# returning an id for a record that is not there hands the caller a row it can select, store as
# the live agent, and never find again.
acp_custom_add() {
    local label cmd next highest idx
    acp_custom_ensure_tree || return 1
    label=$(acp_clean_one_line "${1:-}")
    cmd=$(acp_clean_one_line "${2:-}")
    next=$("$plister" get value "$acp_prefs" /agents/customNextId 2>/dev/null)
    case "$next" in
        ""|*[!0-9]*) next=0 ;;
    esac
    highest=$(acp_custom_highest_id)
    [ "$highest" -ge "$next" ] && next=$((highest + 1))
    [ "$next" -ge 1 ] || next=1
    "$plister" set integer "$((next + 1))" "$acp_prefs" /agents/customNextId >/dev/null 2>&1
    "$plister" append dict "$acp_prefs" /agents/custom >/dev/null 2>&1
    idx=$(($(acp_custom_count) - 1))
    [ "$idx" -ge 0 ] || return 1
    "$plister" insert id string "custom:$next" "$acp_prefs" "/agents/custom/$idx" >/dev/null 2>&1
    "$plister" insert label string "$label" "$acp_prefs" "/agents/custom/$idx" >/dev/null 2>&1
    "$plister" insert command string "$cmd" "$acp_prefs" "/agents/custom/$idx" >/dev/null 2>&1
    [ "$(acp_custom_field "$idx" id)" = "custom:$next" ] || return 1
    printf 'custom:%s\n' "$next"
}

# acp_custom_remove <id>
acp_custom_remove() {
    local idx
    idx=$(acp_custom_index "$1") || return 1
    "$plister" remove "$acp_prefs" "/agents/custom/$idx" >/dev/null 2>&1
}

# acp_custom_set <id> <label|command> <value>
#
# The field name is checked against a list rather than pasted into the path: it arrives from a
# caller, and "../../external/command" would otherwise be a legal thing to write through.
acp_custom_set() {
    local idx key value
    case "$2" in
        label|command) key="$2" ;;
        *)             return 1 ;;
    esac
    idx=$(acp_custom_index "$1") || return 1
    value=$(acp_clean_one_line "$3")
    # `set` on a key that is not there is a silent no-op - rc 0, nothing written - so a missing
    # one has to be inserted first. Same trap acp_agent_store guards against, one level down.
    "$plister" get type "$acp_prefs" "/agents/custom/$idx/$key" >/dev/null 2>&1 \
        || "$plister" insert "$key" string "$value" "$acp_prefs" "/agents/custom/$idx" >/dev/null 2>&1
    "$plister" set string "$value" "$acp_prefs" "/agents/custom/$idx/$key" >/dev/null 2>&1
}

# acp_custom_unique_label <base>  ->  <base>, or "<base> 2", "<base> 3" ... if it is taken
#
# The Finder's convention for "untitled folder 2", and for the same reason: pressing + twice
# should not produce two rows the user cannot tell apart. Names are not identity here - the id
# is - so a duplicate would be legal and merely confusing, which is the worst kind of legal.
acp_custom_unique_label() {
    local base candidate n=1
    base=$(acp_clean_one_line "$1")
    [ -n "$base" ] || base="New Agent"
    candidate="$base"
    while [ -n "$(acp_custom_list | /usr/bin/awk -F'\t' -v want="$candidate" '$2 == want { print "y"; exit }')" ]; do
        n=$((n + 1))
        candidate="$base $n"
        # n rises every pass and the labels are finite, so this terminates on its own. The bound
        # is here because it does not COST anything and this runs on the UI thread's script,
        # where a loop that fails to end is a hung window rather than a slow one.
        [ "$n" -gt 999 ] && break
    done
    printf '%s\n' "$candidate"
}

# acp_custom_get <id> <label|command>  ->  the value, or nothing (rc 1 for an unknown id)
acp_custom_get() {
    local idx
    case "$2" in
        label|command) ;;
        *)             return 1 ;;
    esac
    idx=$(acp_custom_index "$1") || return 1
    acp_custom_field "$idx" "$2"
}

# NO acp_agent_probe() HELPER HERE, DELIBERATELY. There was one, and nothing ever called it:
# aichat.select.external.agent.test.sh runs acp_probe.py itself, from inside a Python heredoc,
# because it needs shlex to split the typed command the same way the transport builder does
# and an OUTER subprocess timeout so an OMC subcommand can never fail to return. A shell
# wrapper cannot provide either, so the two copies would only drift - and the unused one was
# already the more careful of the pair, which is exactly how a stale helper misleads.
