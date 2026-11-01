#!/usr/bin/env python3
"""Validate interleaved simulator benchmark receipts and retain every timing."""

import argparse
import json
import math
from pathlib import Path
import re
import statistics


WARM = re.compile(r"ORBIT_PERF warm-search-(\d+) ([\d.]+) ms\b")
EVIDENCE = re.compile(r"ORBIT_PERF evidence ([0-9a-f]{64})\b")
FIXTURE = re.compile(r"ORBIT_PERF fixture notes=(\d+) passages=(\d+) format=([23])\b")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def report(runs):
    require(isinstance(runs, list) and len(runs) >= 10 and len(runs) % 2 == 0,
            "expected at least five baseline/candidate pairs")
    batches = {"baseline": [], "candidate": []}
    fixtures = set()
    fingerprints = set()
    repeats = set()
    logs = set()
    for index in range(0, len(runs), 2):
        pair = runs[index:index + 2]
        repeat = pair[0].get("repeat")
        require(type(repeat) is int and repeat not in repeats,
                f"pair {index // 2}: repeat must be a unique integer")
        require(pair[0].get("side") == "baseline" and pair[1].get("side") == "candidate"
                and type(pair[1].get("repeat")) is int and pair[1]["repeat"] == repeat,
                f"pair {index // 2}: expected baseline then candidate with matching repeat")
        repeats.add(repeat)
        for receipt in pair:
            side = receipt["side"]
            label = f"{side} repeat {repeat}"
            summary = receipt["data"]["summary"]
            counts = summary["counts"]
            require(receipt.get("didError") is False and summary.get("status") == "SUCCEEDED"
                    and type(counts.get("failed")) is int and counts["failed"] == 0
                    and type(counts.get("passed")) is int and counts["passed"] > 0,
                    label + ": receipt must succeed with zero failed tests")
            path = Path(receipt["data"]["artifacts"]["buildLogPath"]).expanduser()
            resolved = path.resolve()
            require(resolved not in logs, label + ": log was already used by another run")
            logs.add(resolved)
            log = path.read_text(encoding="utf-8")
            warm = WARM.findall(log)
            hashes = EVIDENCE.findall(log)
            fixture = FIXTURE.findall(log)
            require(len(warm) == 5 and sorted(int(number) for number, _ in warm) == list(range(5)),
                    label + ": expected exactly warm-search-0 through warm-search-4")
            require(len(hashes) == 5, label + ": expected exactly five evidence hashes")
            require(len(fixture) == 1, label + ": expected one fixture description")
            times = [float(value) for _, value in sorted(warm, key=lambda item: int(item[0]))]
            require(all(math.isfinite(value) and value > 0 for value in times),
                    label + ": warm timings must be finite positive milliseconds")
            fixtures.add(tuple(int(value) for value in fixture[0]))
            fingerprints.update(hashes)
            batches[side].append({"repeat": repeat, "log": path.name,
                                  "warm_ms": times, "median_ms": statistics.median(times),
                                  "evidence_hashes": hashes, "test_counts": counts})

    require(len(fixtures) == 1, "all runs must use the same notes/passages/format fixture")
    require(len(fingerprints) == 1, "evidence hashes differ within or across baseline/candidate runs")
    notes, passages, disk_format = next(iter(fixtures))
    require(notes > 0 and passages > 0, "fixture note and passage counts must be positive")
    sides = {}
    for side, records in batches.items():
        samples = [value for batch in records for value in batch["warm_ms"]]
        medians = [batch["median_ms"] for batch in records]
        sides[side] = {"run_count": len(records), "sample_count": len(samples),
                       "raw_warm_ms": samples, "median_ms": statistics.median(samples),
                       "range_ms": [min(samples), max(samples)], "batch_medians_ms": medians,
                       "median_of_batch_medians_ms": statistics.median(medians), "batches": records}
    baseline = sides["baseline"]["median_ms"]
    candidate = sides["candidate"]["median_ms"]
    baseline_batch = sides["baseline"]["median_of_batch_medians_ms"]
    candidate_batch = sides["candidate"]["median_of_batch_medians_ms"]
    return {"fixture": {"notes": notes, "passages": passages, "format": disk_format},
            "evidence_sha256": next(iter(fingerprints)), "all_samples_retained": True,
            "excluded_samples": 0, "sides": sides,
            "comparison": {
                "median_latency_change_percent": (candidate / baseline - 1) * 100,
                "batch_median_latency_change_percent": (candidate_batch / baseline_batch - 1) * 100,
                "percent_definition": "(candidate / baseline - 1) * 100; negative means lower latency",
                "interpretation": "Descriptive medians only; no categorical verdict or outlier removal."}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=Path, required=True, help="saved MobileBuildMCP receipts JSON array")
    parser.add_argument("--output", type=Path, required=True, help="validated report JSON destination")
    args = parser.parse_args()
    try:
        result = report(json.loads(args.runs.expanduser().read_text(encoding="utf-8")))
        output = args.output.expanduser()
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        parser.error(str(error))
    print("Validated benchmark report: " + str(output))


if __name__ == "__main__":
    main()
