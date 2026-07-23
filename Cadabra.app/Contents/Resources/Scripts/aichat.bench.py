# aichat.bench.py
# Benchmark engine + result store for the model picker's Benchmark section.
#
#   run    - benchmark one model (GGUF via the bundled llama-server, MLX via mlx-agent
#            bench), append the record to the JSON store, print the display text.
#   lookup - print the display text for a model from the store (no benchmarking).
#
# Records are keyed by the model's display label and stamped with machine info
# (hw.model, chip, RAM), so the store stays meaningful if it ever travels between
# Macs. Display shows this machine's latest record first, then other machines'.
#
# Invoked by aichat.select.local.model.benchmark.sh with the bundle's embedded
# python3; stdlib only. Display text goes to stdout (markdown with two-space hard
# breaks, matching the info pane); diagnostics go to stderr.
import argparse
import datetime
import json
import os
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.request

HEALTH_TIMEOUT_S = 600
COMPLETION_TIMEOUT_S = 1800


def file_tail(path, lines=3):
    try:
        with open(path) as f:
            return " | ".join(f.read().strip().splitlines()[-lines:])
    except OSError:
        return ""


def sysctl(name):
    try:
        return subprocess.check_output(["/usr/sbin/sysctl", "-n", name], text=True).strip()
    except Exception:
        return ""


def machine_info():
    ram_gb = 0
    try:
        ram_gb = int(sysctl("hw.memsize")) // (1024 ** 3)
    except ValueError:
        pass
    return {"model": sysctl("hw.model"), "chip": sysctl("machdep.cpu.brand_string"), "ram_gb": ram_gb}


def load_db(path):
    try:
        with open(path) as f:
            db = json.load(f)
        if isinstance(db, dict) and isinstance(db.get("records"), list):
            return db
    except (OSError, ValueError):
        pass
    return {"version": 1, "records": []}


def save_db(path, db):
    # mkstemp (unique name), not a fixed .tmp: two picker windows finishing concurrent
    # benchmarks must never interleave writes into the same temp file.
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".benchmarks-")
    with os.fdopen(fd, "w") as f:
        json.dump(db, f, indent=1)
    os.replace(tmp, path)


def http_json(url, payload=None, timeout=COMPLETION_TIMEOUT_S):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def bench_gguf(args):
    port = free_port()
    base = f"http://127.0.0.1:{port}"
    # Policy args go BEFORE our -c so llama-server's last-wins parsing keeps the bench
    # context small even when the policy carries its own --ctx-size (CPU-fallback path).
    cmd = [args.llama_server, "--model", args.model]
    cmd += (args.server_args or "").split()
    cmd += ["-c", str(args.prompt_tokens + args.gen_tokens + 512),
            "--host", "127.0.0.1", "--port", str(port), "--no-webui"]
    print("launching:", " ".join(cmd), file=sys.stderr)
    # Server stderr goes to a file: a PIPE fills at ~64 KB during long loads (the server
    # logs every health poll) and deadlocks the very models most worth benchmarking.
    logfd, logpath = tempfile.mkstemp(prefix="aichat_bench_srv_", suffix=".log")
    health_timeout = HEALTH_TIMEOUT_S * (2 if "--no-mmap" in cmd else 1)
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=logfd)
    os.close(logfd)
    try:
        deadline = time.time() + health_timeout
        while time.time() < deadline:
            try:
                if http_json(f"{base}/health", timeout=5).get("status") == "ok":
                    break
            except Exception:
                pass
            if proc.poll() is not None:
                raise RuntimeError("llama-server exited during startup: " + file_tail(logpath))
            time.sleep(1)
        else:
            raise RuntimeError("llama-server did not become healthy in time")

        filler = "The quick brown fox jumps over the lazy dog. " * (args.prompt_tokens // 2)
        toks = http_json(f"{base}/tokenize", {"content": filler})["tokens"]
        if len(toks) < args.prompt_tokens:
            raise RuntimeError("filler prompt too short")
        prompt_ids = toks[:args.prompt_tokens]

        def one_run(ids, n_predict):
            r = http_json(f"{base}/completion", {
                "prompt": ids, "n_predict": n_predict,
                "temperature": 0, "cache_prompt": False, "stream": False,
            })
            if "error" in r:
                raise RuntimeError(f"completion error: {r['error']}")
            t = r["timings"]
            return t["prompt_per_second"], t["predicted_per_second"], t["prompt_ms"] / 1000.0

        one_run(prompt_ids[:32], 8)  # cheap warm-up: page weights in, warm the GPU
        prefills, gens, ttfts = [], [], []
        for _ in range(args.runs):
            pf, gp, ttft = one_run(prompt_ids, args.gen_tokens)
            prefills.append(pf)
            gens.append(gp)
            ttfts.append(ttft)
        return {
            "prefill_tps": round(statistics.median(prefills), 1),
            "gen_tps": round(statistics.median(gens), 1),
            "ttft_s": round(statistics.median(ttfts), 2),
        }
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except Exception:
            proc.kill()
            proc.wait()
        try:
            os.unlink(logpath)
        except OSError:
            pass


def bench_mlx(args):
    cmd = [args.mlx_agent, "bench", "--model", args.model,
           "--prompt-tokens", str(args.prompt_tokens),
           "--gen-tokens", str(args.gen_tokens), "--runs", str(args.runs)]
    print("launching:", " ".join(cmd), file=sys.stderr)
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
    for line in proc.stdout.splitlines():
        if line.startswith("RESULT_JSON:"):
            r = json.loads(line[len("RESULT_JSON:"):])
            return {
                "prefill_tps": round(float(r["prefill_tps"]), 1),
                "gen_tps": round(float(r["gen_tps"]), 1),
                "ttft_s": round(float(r["ttft_s"]), 2),
            }
    err = (proc.stderr or "").strip().splitlines()
    raise RuntimeError("mlx-agent bench produced no RESULT_JSON: " + " | ".join(err[-3:]))


def machine_label(m):
    ram = f", {m['ram_gb']} GB" if m.get("ram_gb") else ""
    return f"{m.get('chip') or m.get('model') or 'unknown Mac'}{ram}"


def same_machine(a, b):
    # hw.model alone merges differently-specced units of the same Mac model; RAM splits them.
    return a.get("model") == b.get("model") and a.get("ram_gb") == b.get("ram_gb")


def format_records(db, label, model_path, this_machine):
    # label + path: two files with the same basename (LM Studio vs HF cache copies) must
    # not share a history. Records from other machines have foreign paths, so the path
    # match applies only to this machine's rows.
    matches = [r for r in db["records"] if r["label"] == label]
    mine = [r for r in matches if same_machine(r["machine"], this_machine)
            and (not model_path or r.get("model_path") == model_path)]
    others = [r for r in matches if not same_machine(r["machine"], this_machine)]
    if not mine and not others:
        return ""
    br = "  "
    lines = []
    for r in mine[-1:] + others[-1:]:
        note = f" · {r['note']}" if r.get("note") else ""
        lines.append(f"**{machine_label(r['machine'])}** ({r['engine'].upper()}){note}" + br)
        lines.append(f"Prefill: {r['prefill_tps']:g} tok/s · Generate: {r['gen_tps']:g} tok/s · First token: {r['ttft_s']:g} s" + br)
        lines.append(f"{r['prompt_tokens']}-token prompt, {r['gen_tokens']} generated, median of {r['runs']} · {r['date'][:10]}" + br)
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["run", "lookup"])
    ap.add_argument("--db", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--engine", choices=["gguf", "mlx"])
    ap.add_argument("--model")
    ap.add_argument("--llama-server")
    ap.add_argument("--mlx-agent")
    ap.add_argument("--server-args", default="")
    ap.add_argument("--prompt-tokens", type=int, default=2048)
    ap.add_argument("--gen-tokens", type=int, default=128)
    ap.add_argument("--runs", type=int, default=2)
    ap.add_argument("--note", default="", help="annotation stored with the record, e.g. 'GPU busy - CPU fallback'")
    args = ap.parse_args()

    this_machine = machine_info()

    if args.mode == "lookup":
        print(format_records(load_db(args.db), args.label, args.model or "", this_machine))
        return 0

    if not args.model or not args.engine:
        print("run mode needs --engine and --model", file=sys.stderr)
        return 2
    result = bench_gguf(args) if args.engine == "gguf" else bench_mlx(args)
    record = {
        "label": args.label, "engine": args.engine, "model_path": args.model,
        "machine": this_machine,
        "prompt_tokens": args.prompt_tokens, "gen_tokens": args.gen_tokens, "runs": args.runs,
        "date": datetime.datetime.now().isoformat(timespec="seconds"),
    }
    if args.note:
        record["note"] = args.note
    record.update(result)
    # Load only now: the bench ran for minutes, and another window may have persisted its
    # own record meanwhile - a read-modify-write spanning the bench would discard it.
    db = load_db(args.db)
    db["records"].append(record)
    save_db(args.db, db)
    print(format_records(db, args.label, args.model, this_machine))
    return 0


def _terminated(signum, frame):
    # Default SIGTERM handling would skip the finally: blocks and orphan the bench
    # llama-server on the GPU (app quit sends TERM). SystemExit runs them.
    raise SystemExit(143)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _terminated)
    signal.signal(signal.SIGHUP, _terminated)
    sys.exit(main())
