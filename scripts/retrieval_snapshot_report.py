#!/usr/bin/env python3
"""Extract validated core-only snapshot samples from MobileBuildMCP test logs."""
import argparse
import json
import math
from pathlib import Path
import statistics


def summarize(paths):
    runs = []
    for path in paths:
        reports = [json.loads(line.split("ORBIT_SNAPSHOT ", 1)[1])
                   for line in path.read_text().splitlines() if "ORBIT_SNAPSHOT " in line]
        if len(reports) != 1:
            raise ValueError(f"{path}: expected one snapshot report")
        report = reports[0]
        if report.get("schema") != 1 or report.get("failures") != 0:
            raise ValueError(f"{path}: invalid or failing run")
        if report.get("notes", 0) < 4:
            raise ValueError(f"{path}: missing generated workload")
        samples = report["samples"]
        for stage in ("direct-warm", "snapshot-warm"):
            selected = [row for row in samples if row["stage"] == stage]
            if len(selected) != 25:
                raise ValueError(f"{path}: expected 25 {stage} samples")
        for row in samples:
            if not math.isfinite(row["ms"]) or row["ms"] < 0:
                raise ValueError("invalid duration")
            if row["stage"] == "snapshot-warm" and row["source_accesses"] != 0:
                raise ValueError("snapshot query accessed source folder")
        runs.append({"log": str(path), **report})
    if len({run["notes"] for run in runs}) != 1:
        raise ValueError("workload sizes differ")
    stages = {}
    for stage in sorted({row["stage"] for run in runs for row in run["samples"]}):
        rows = [row for run in runs for row in run["samples"] if row["stage"] == stage]
        durations = sorted(row["ms"] for row in rows)
        stages[stage] = {"samples": len(rows), "p50_ms": statistics.median(durations),
                         "p95_ms": durations[math.ceil(.95 * len(durations)) - 1],
                         "min_ms": durations[0], "max_ms": durations[-1],
                         "source_reads": sorted({row["source_reads"] for row in rows}),
                         "source_inspections": sorted({row["source_inspections"] for row in rows})}
    return {"claim": "Core-only exploratory comparison with different freshness guarantees; not an end-to-end speedup",
            "runs": runs, "stages": stages,
            "quantile": "nearest-rank p95; samples within one process are not independent process runs",
            "acceptance": {"physical_device": "NOT VERIFIED", "icloud": "NOT VERIFIED",
                           "desktop_host": "NOT VERIFIED", "model": "NOT VERIFIED",
                           "two_way_replica": "NOT IMPLEMENTED"}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", type=Path, nargs="+")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = summarize(args.logs)
    except (ValueError, KeyError, TypeError) as error:
        parser.error(str(error))
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result["stages"], indent=2))


if __name__ == "__main__":
    main()
