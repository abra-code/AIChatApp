#!/usr/bin/env python3
# update-mcp-servers.py
# Installs Python MCP packages into the app bundle.
# Run once to set up MCP; re-run to add or upgrade packages.
#
# Usage: python3 update-mcp-servers.py [--identity=CERT]

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

# ── MCP Python packages ───────────────────────────────────────────────────────
# Add / uncomment one package at a time, then re-run this script to test.
# mcp-proxy was dropped 2026-07: Cadabra talks to MCP servers directly over stdio
# (mlx-agent), so the WebUI-era HTTP proxy is dead weight here. The V1 AIChat.app
# WebUI still needs it, but this script no longer targets that bundle.
MCP_PACKAGES = [
    "mcp-server-time",
    # "mcp-server-fetch",
    "duckduckgo-mcp-server",
]
# ─────────────────────────────────────────────────────────────────────────────

RED   = "\033[91m"
GREEN = "\033[92m"
RESET = "\033[0m"


def die(msg: str) -> None:
    print(f"{RED}{msg}{RESET}", file=sys.stderr)
    sys.exit(1)


def find_app_bundle(script_dir: Path) -> Path:
    # Pinned to Cadabra.app: the repo root also holds the V1 AIChat.app, so a *.app
    # glob would grab the wrong bundle (sorted() puts AIChat.app first).
    candidate = script_dir / "Cadabra.app"
    if candidate.is_dir():
        return candidate
    die(f"No Cadabra.app found in {script_dir}")


def prepare(packages_dir: Path, python3: Path) -> None:
    print()
    print("==== Preparing MCP packages update ====")
    print()
    packages_dir.mkdir(parents=True, exist_ok=True)
    if not python3.exists():
        die(f"Bundled Python not found: {python3}")
    print(f"  Packages dir : {packages_dir}")
    print(f"  Python3      : {python3}")
    print(f"  Packages     : {' '.join(MCP_PACKAGES)}")
    print()


def install_packages(python3: Path, packages_dir: Path) -> None:
    print("==== Installing Python MCP packages ====")
    print()
    version = subprocess.check_output([str(python3), "--version"], text=True).strip()
    print(f"  Python   : {version}")
    print(f"  Target   : {packages_dir}")
    print(f"  Packages : {' '.join(MCP_PACKAGES)}")
    print()

    result = subprocess.run([
        str(python3), "-m", "pip", "install",
        "--target", str(packages_dir),
        "--no-compile",
        "--upgrade",
        *MCP_PACKAGES,
    ])
    if result.returncode != 0:
        die("pip install failed")
    print()

    print("  Stripping __pycache__, RECORD, and test dirs...")
    for d in list(packages_dir.rglob("__pycache__")):
        if d.is_dir():
            shutil.rmtree(d, ignore_errors=True)
    for f in packages_dir.rglob("*.dist-info/RECORD"):
        f.unlink(missing_ok=True)
    for name in ("tests", "test"):
        for d in list(packages_dir.rglob(name)):
            if d.is_dir():
                shutil.rmtree(d, ignore_errors=True)
    print("  Done.")
    print()


def codesign(script_dir: Path, app_bundle: Path, identity: str) -> None:
    print("==== Codesigning app bundle ====")
    print()
    script = script_dir / "codesign_applet.sh"
    if not script.exists():
        die(f"codesign_applet.sh not found: {script}")
    result = subprocess.run([str(script), str(app_bundle), identity])
    if result.returncode != 0:
        die("Codesigning failed")
    print()


def verify(python3: Path, packages_dir: Path) -> None:
    print("==== Verifying installation ====")
    print()
    env = {**os.environ, "PYTHONPATH": str(packages_dir)}
    failed = []
    for module in ["mcp_server_time", "duckduckgo_mcp_server"]:
        r = subprocess.run(
            [str(python3), "-c", f"import {module}"],
            env=env, capture_output=True,
        )
        if r.returncode == 0:
            print(f"  {module}: OK")
        else:
            print(f"  {module}: FAILED", file=sys.stderr)
            failed.append(module)
    if failed:
        die(f"Verification failed: {', '.join(failed)}")
    print()


def print_summary(python3: Path, packages_dir: Path) -> None:
    print("==== Update complete ====")
    print()
    env = {**os.environ, "PYTHONPATH": str(packages_dir)}
    for pkg in MCP_PACKAGES:
        r = subprocess.run(
            [str(python3), "-m", "pip", "show", pkg],
            env=env, capture_output=True, text=True,
        )
        for line in r.stdout.splitlines():
            if line.startswith("Version:"):
                ver = line.split(":", 1)[1].strip()
                print(f"  {GREEN}{pkg} {ver}{RESET} → {packages_dir}")
                break
    print()
    print("  Next: launch Cadabra.app — MCP servers are spawned on demand per session.")
    print()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Install Python MCP packages into the app bundle.",
    )
    parser.add_argument(
        "--identity", default="-",
        metavar="CERT",
        help="Signing identity for codesign (default: - for ad-hoc)",
    )
    args = parser.parse_args()

    script_dir   = Path(__file__).resolve().parent
    app_bundle   = find_app_bundle(script_dir)
    packages_dir = app_bundle / "Contents" / "Library" / "Packages"
    python3      = app_bundle / "Contents" / "Library" / "Python" / "bin" / "python3"

    prepare(packages_dir, python3)
    install_packages(python3, packages_dir)
    codesign(script_dir, app_bundle, args.identity)
    verify(python3, packages_dir)
    print_summary(python3, packages_dir)


if __name__ == "__main__":
    main()
