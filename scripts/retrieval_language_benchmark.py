#!/usr/bin/env python3
"""Compare evidence-matched persistent Python and Release Swift MCP implementations.

All folders, registries, caches and state are disposable. This compares current
implementations, including their algorithm differences, not isolated language cost.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time

from swift_compatibility import ROOT, Server
import replication


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def timeout(_signal, _frame):
    raise TimeoutError("MCP call exceeded 60 seconds")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--warm-samples", type=int, default=5)
    parser.add_argument("--notes", type=int, default=500)
    parser.add_argument("--profile", choices=("swift", "python"), help="diagnostic run; excluded from speed claims")
    args = parser.parse_args()
    if min(args.rounds, args.warm_samples, args.notes) < 1:
        parser.error("counts must be positive")
    signal.signal(signal.SIGALRM, timeout)
    report = {"schema": 1, "claim": "Same-Mac implementation comparison, not isolated language cost or app latency",
              "swift_binary_sha256": hashlib.sha256(args.swift.read_bytes()).hexdigest(),
              "python_version": sys.version, "notes": args.notes + 1, "rounds": args.rounds,
              "diagnostic_profile": args.profile, "samples": [], "failures": []}
    with tempfile.TemporaryDirectory(prefix="orbit-language-") as temporary:
        base = Path(temporary).resolve()
        seed = base / "seed"
        files = {"Knowledge/Speaking.md": "---\nid: speaking\ntitle: Public speaking\n---\n# Public speaking\n\n## Practical tips\nPractice your opening aloud. Pause between ideas.\n"}
        for index in range(args.notes):
            files[f"Generated/Note{index}.md"] = f"# Generated {index}\n\n" + "".join(
                f"## Section {section}\n\nProject planning covers milestone {section} for note {index}.\n\n"
                for section in range(12))
        for name, content in files.items():
            destination = seed / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(content.encode())
        identity = "98a97a71-4620-4bcd-a1ed-73f54bb66de4"
        (seed / ".orbit").mkdir()
        (seed / ".orbit/vault.json").write_text(json.dumps({"schema": 1, "id": identity,
                                                         "data_format": 3, "orbit_version": "0.6.0"}))
        previous = dict(os.environ)
        try:
            os.environ.update(ORBIT_CONFIG=str(base / "seed-config.json"),
                              ORBIT_CACHE=str(base / "seed-cache"), ORBIT_STATE=str(base / "seed-state"))
            replication.seed(seed, files)
        finally:
            os.environ.clear()
            os.environ.update(previous)
        original = {str(p.relative_to(seed)): hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in seed.rglob("*") if p.is_file()}
        expected = {}
        for round_index in range(args.rounds):
            order = ["swift", "python"] if round_index % 2 == 0 else ["python", "swift"]
            for side in order:
                prefix = base / f"round-{round_index}" / side
                shutil.copytree(seed, prefix / "folder")
                (prefix / "config.json").write_text(json.dumps({"schema": 2, "orbits": {
                    "Bench": {"path": str(prefix / "folder"), "vault_id": identity}}}))
                command = [str(args.swift.resolve())] if side == "swift" else [sys.executable, str(ROOT / "scripts/mcp_server.py")]
                def start():
                    began = time.perf_counter()
                    server = Server(command, prefix)
                    server.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 0, "method": "initialize",
                        "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                                   "clientInfo": {"name": "orbit-language-check", "version": "1"}}}) + "\n")
                    server.process.stdin.flush()
                    signal.alarm(60)
                    try:
                        initialized = json.loads(server.process.stdout.readline())
                        assert "result" in initialized, initialized
                    finally:
                        signal.alarm(0)
                    report["samples"].append({"side": side, "round": round_index, "stage": "startup-initialize",
                                              "ms": (time.perf_counter() - began) * 1000})
                    return server
                server = start()
                profiler = None
                def call(stage, action="search", **arguments):
                    began = time.perf_counter()
                    signal.alarm(60)
                    try:
                        response = server.call(action, {"orbit": "Bench", **arguments})
                    finally:
                        signal.alarm(0)
                    elapsed = (time.perf_counter() - began) * 1000
                    assert not response.get("error") and not response["result"].get("isError"), response
                    payload = response["result"]["content"][0]["text"]
                    assert payload["sync"]["status"] == "ready", payload
                    if action == "search":
                        assert payload["coverage"]["state"] == "complete", payload
                        if stage != "no-hit":
                            assert payload["total"] == 1, payload
                            evidence = payload["results"][0]
                            assert evidence["path"] == "Knowledge/Speaking.md", evidence
                            assert evidence["sha256"] == hashlib.sha256(files[evidence["path"]].encode()).hexdigest()
                            assert any("Pause between ideas" in line["text"] for line in evidence["snippets"])
                        else:
                            assert payload["total"] == 0 and not payload["results"], payload
                        if stage in ("warm", "existing-index-restart"):
                            assert payload["freshness"]["reparsed"] == 0, payload
                    token = (round_index, stage)
                    digest = fingerprint(response)
                    if token in expected:
                        assert expected[token] == digest, f"Evidence differs for {side} {stage}"
                    else:
                        expected[token] = digest
                    report["samples"].append({"side": side, "round": round_index, "stage": stage,
                                              "ms": elapsed, "evidence_sha256": digest})
                try:
                    call("first-index", query="practice public speaking", limit=3)
                    if args.profile == side:
                        profile_path = args.output.with_suffix(f".{side}.{round_index}.sample.txt")
                        profiler = subprocess.Popen(["/usr/bin/sample", str(server.process.pid), "2", "-file", str(profile_path)],
                                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    for _ in range(args.warm_samples):
                        call("warm", query="practice public speaking", limit=3)
                    call("no-hit", query="absentuniqueterm", limit=3)
                    call("read", "read", path="Knowledge/Speaking.md", start=1, count=100)
                    rss = int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(server.process.pid)]).strip())
                    report["samples"].append({"side": side, "round": round_index, "stage": "rss", "rss_kib": rss})
                    if profiler is not None:
                        profiler.wait(timeout=15)
                    server.close()
                    server = start()
                    call("existing-index-restart", query="practice public speaking", limit=3)
                    after = {str(p.relative_to(prefix / "folder")): hashlib.sha256(p.read_bytes()).hexdigest()
                             for p in (prefix / "folder").rglob("*") if p.is_file()}
                    assert after == original, "Benchmark changed authoritative folder bytes"
                    print(f"PASS round={round_index} side={side}", flush=True)
                except Exception as error:
                    report["failures"].append({"side": side, "round": round_index, "error": str(error)})
                    raise
                finally:
                    server.close()
    report["stages"] = {}
    for side in ("swift", "python"):
        for stage in ("startup-initialize", "first-index", "warm", "no-hit", "read", "existing-index-restart"):
            values = sorted(row["ms"] for row in report["samples"] if row["side"] == side and row["stage"] == stage)
            report["stages"][f"{side}:{stage}"] = {"samples": len(values), "p50_ms": statistics.median(values),
                "p95_ms": values[math.ceil(.95 * len(values)) - 1], "min_ms": min(values), "max_ms": max(values)}
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["stages"], indent=2))


if __name__ == "__main__":
    main()
