#!/usr/bin/env python3
"""A minimal ACP agent that answers the two calls Cadabra's probe makes.

WHAT IT IS FOR. Scripts/acp_probe.py runs `initialize` then `session/new` over newline-delimited
JSON-RPC on stdio - the same pair the Chat element makes at window open - and the External ACP
Agent dialog's Test button reports what came back. Testing any of that against a real agent means
depending on one being installed, on a network, and on credentials, so a green result would mean
different things on different machines and would stop meaning anything at all on a build box.

This answers both calls, immediately and identically every time, so a test can assert on the
probe's OUTPUT rather than on whether some third-party binary happens to be present.

It is a HELPER, not a test: nothing here runs on its own, and it deliberately does not live
under a *.test.sh name. Point a command line at it and it behaves like an agent that works:

    Tests/helpers/fake_acp_agent.py

WHAT IT DELIBERATELY DOES NOT DO. It never advertises authMethods, so it exercises the clean
path only. Anything checking the "agent wants you to log in first" warning needs a variant that
returns a non-empty authMethods list - add it as a sibling rather than adding a flag here, since
the value of this file is that it has no modes.

It identifies itself as FakeAgent 9.9, which is what makes it useful for the identity path:
Test records the agent's name and version against the command it measured, and that record is
the only place in the app those strings are ever observed.
"""
import json
import sys


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            # A real agent would answer with a parse error. Staying silent is closer to the
            # failure a test would want to write on purpose, and this file has no modes.
            continue

        method = message.get("method")
        if method == "initialize":
            result = {
                "protocolVersion": 1,
                "agentInfo": {"name": "FakeAgent", "version": "9.9"},
                "agentCapabilities": {},
                "authMethods": [],
            }
        elif method == "session/new":
            result = {"sessionId": "fake-session-1"}
        else:
            continue

        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": message.get("id"), "result": result}) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
