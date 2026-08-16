#!/usr/bin/env python3
"""Probe a local ACP agent: can it start, handshake, and open a session here?

Usage:
    acp_probe.py <cwd> <timeout_seconds> -- <agent argv...>

Runs the same two calls the Chat element makes at window open - `initialize` then
`session/new` - and reports what happened as one line of JSON on stdout. Always exits 0:
a dead or unauthenticated agent is a RESULT, not a failure of the probe, and the caller
renders it either way.

`session/new` is included because it is the second call the element makes and the first that
can fail on a real misconfiguration (a bad cwd, a refused workspace).

WHAT THIS CANNOT TELL YOU: whether prompts will actually work. Measured on opencode
1.17.13 with ZERO credentials configured, both `initialize` and `session/new` succeed and
the refusal only arrives at the first prompt. So `ok` here means "launches, handshakes, and
opens a session", not "ready to chat". The honest signal for the rest is `authMethods`:
when it is non-empty the agent has a login of its own, and ChatView does not implement
ACP's `authenticate` - it surfaces the failure and names the advertised methods
(ACPChatTransport.swift:280) - so the user must log in through the agent's own CLI. Report
that as a warning rather than pretending to have verified it.

Requests FROM the agent (fs/*, terminal/*, session/request_permission) are answered with
a JSON-RPC "method not found" rather than ignored: an agent that blocks waiting for an
answer would otherwise hang the probe until the timeout and be reported as dead.
"""
import json
import os
import signal
import subprocess
import sys
import threading

import acp_agent_env


def main():
    if "--" not in sys.argv:
        print(json.dumps({"ok": False, "error": "usage: acp_probe.py <cwd> <timeout> -- <argv...>"}))
        return 0
    split = sys.argv.index("--")
    if split < 3:
        print(json.dumps({"ok": False, "error": "usage: acp_probe.py <cwd> <timeout> -- <argv...>"}))
        return 0
    cwd, timeout_raw = sys.argv[1], sys.argv[2]
    argv = sys.argv[split + 1:]
    if not argv:
        print(json.dumps({"ok": False, "error": "no agent command given"}))
        return 0
    try:
        timeout = max(1.0, float(timeout_raw))
    except ValueError:
        timeout = 20.0
    if not os.path.isdir(cwd):
        cwd = os.path.expanduser("~")

    result = {"ok": False, "name": "", "version": "", "protocolVersion": "",
              "authMethods": [], "capabilities": {}, "error": "", "stderr": ""}

    try:
        # Own process GROUP, so the watchdog can kill the whole tree. Killing just the direct
        # child is not enough for a wrapper: `npx -y <package>` spawns node, the grandchild
        # inherits the stdout write end, and the pipe therefore never reaches EOF - readline()
        # blocks forever and the "probe" outlives the timeout it was given. Measured: a forking
        # wrapper hung past 60s against a 5s timeout. No catalog row launches through npx any
        # more, but the Custom row takes whatever the user types, so this stays load-bearing.
        #
        # env: the SAME augmented PATH the real launch gets (acp_agent_env), because a probe
        # that runs under a different environment than the thing it is vouching for is not a
        # probe. Without it an interpreter-script agent dies in exec - see acp_agent_env.py.
        proc = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, bufsize=1,
                                start_new_session=True, env=acp_agent_env.launch_env())
    except OSError as exc:
        result["error"] = "could not launch: %s" % exc
        print(json.dumps(result))
        return 0

    # Drained on a thread so a chatty agent cannot fill the pipe buffer and deadlock the
    # handshake. Kept to the tail, since a failing agent's last lines are the useful ones.
    stderr_tail = []
    stderr_dropped = [0]

    def drain():
        for line in proc.stderr:
            stderr_tail.append(line.rstrip("\n"))
            if len(stderr_tail) > 12:
                del stderr_tail[0]
                stderr_dropped[0] += 1

    drainer = threading.Thread(target=drain, daemon=True)
    drainer.start()

    def send(obj):
        proc.stdin.write(json.dumps(obj) + "\n")
        proc.stdin.flush()

    def await_response(want_id):
        """Read until the response with `want_id` arrives, answering any agent request."""
        while True:
            line = proc.stdout.readline()
            if not line:
                raise EOFError("agent closed its output before answering")
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                continue          # not JSON-RPC: some agents log to stdout, skip it
            if msg.get("id") == want_id and ("result" in msg or "error" in msg):
                return msg
            if "method" in msg and "id" in msg:
                send({"jsonrpc": "2.0", "id": msg["id"],
                      "error": {"code": -32601, "message": "probe does not implement %s" % msg["method"]}})

    def kill_tree():
        """SIGKILL the whole process group; fall back to the child if the group is gone."""
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except (OSError, ProcessLookupError):
            try:
                proc.kill()
            except OSError:
                pass

    watchdog = threading.Timer(timeout, kill_tree)
    watchdog.start()
    try:
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": {"protocolVersion": 1,
                         "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}}}})
        init = await_response(1)
        if "error" in init:
            result["error"] = "initialize failed: %s" % init["error"].get("message", init["error"])
        else:
            info = init.get("result", {})
            agent_info = info.get("agentInfo") or {}
            result["name"] = agent_info.get("name", "")
            result["version"] = agent_info.get("version", "")
            result["protocolVersion"] = str(info.get("protocolVersion", ""))
            result["authMethods"] = [m.get("id") or m.get("name", "")
                                     for m in info.get("authMethods") or []]
            result["capabilities"] = info.get("agentCapabilities") or {}

            # The half that actually decides whether a chat window will work.
            send({"jsonrpc": "2.0", "id": 2, "method": "session/new",
                  "params": {"cwd": cwd, "mcpServers": []}})
            new = await_response(2)
            if "error" in new:
                result["error"] = new["error"].get("message") or str(new["error"])
            else:
                result["ok"] = True
    except Exception as exc:
        result["error"] = result["error"] or str(exc)
    finally:
        watchdog.cancel()
        try:
            proc.stdin.close()
        except Exception:
            pass
        kill_tree()
        try:
            proc.wait(timeout=5)
        except Exception:
            pass
        # Let the drain thread finish appending before the tail is read, then close the pipes
        # ourselves - Popen.wait() does not. Bounded, because a wedged grandchild could still
        # be holding the write end and we are already on our way out.
        drainer.join(timeout=1)
        for pipe in (proc.stdout, proc.stderr):
            try:
                pipe.close()
            except Exception:
                pass

    # The byte cap can land mid-line, so drop the leading fragment rather than presenting half
    # a line as if it were a whole one. Whether anything was dropped is reported, because the
    # consumer cannot tell a tail from a complete log and should not have to guess.
    stderr_text = "\n".join(stderr_tail)
    if len(stderr_text) > 600:
        stderr_text = stderr_text[-600:]
        newline = stderr_text.find("\n")
        stderr_text = stderr_text[newline + 1:] if newline != -1 else stderr_text
        stderr_dropped[0] += 1
    result["stderr"] = stderr_text
    result["stderr_truncated"] = stderr_dropped[0] > 0
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
