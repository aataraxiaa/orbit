#!/usr/bin/env python3
"""Generate a disposable simulator benchmark project without building Apple code.

The package can point to an older checkout for before/after measurements while
the test sources always come from this checkout. Runtime packaging excludes
scripts, so this development helper is not installed with the Orbit plugin.
"""

import argparse
import json
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]
SCHEME = "OrbitRetrievalChecks"


def positive_integer(value):
    count = int(value)
    if count < 1:
        raise argparse.ArgumentTypeError("note count must be positive")
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path,
                        default=ROOT / "work/retrieval-performance/project")
    parser.add_argument("--package-path", type=Path, default=ROOT,
                        help="OrbitCore checkout to measure; defaults to this checkout")
    parser.add_argument("--notes", type=positive_integer, default=500)
    parser.add_argument("--format", choices=("2", "3"), default="2",
                        help="generated vault format")
    args = parser.parse_args()
    package = args.package_path.expanduser().resolve()
    output = args.output.expanduser().resolve()
    if not (package / "Package.swift").is_file():
        parser.error("--package-path must contain Package.swift")
    sources = [ROOT / "tests/OrbitCoreTests" / filename for filename in (
        "RetrievalPerformanceTests.swift", "RetrievalRankingTests.swift")]
    for source in sources:
        if not source.is_file():
            parser.error("missing test source: " + str(source))
    xcodegen = shutil.which("xcodegen")
    if xcodegen is None:
        parser.error("xcodegen is required to generate the simulator project")

    source_yaml = "\n".join("      - path: " + json.dumps(str(path)) for path in sources)
    spec = f"""name: {SCHEME}
options:
  deploymentTarget:
    iOS: '18.0'
packages:
  OrbitCore:
    path: {json.dumps(str(package))}
targets:
  {SCHEME}:
    type: bundle.unit-test
    platform: iOS
    sources:
{source_yaml}
    dependencies:
      - package: OrbitCore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.orbit.RetrievalChecks
        GENERATE_INFOPLIST_FILE: YES
        CODE_SIGNING_ALLOWED: NO
        SWIFT_VERSION: '5.9'
        ENABLE_TESTABILITY: YES
schemes:
  {SCHEME}:
    build:
      targets:
        {SCHEME}: all
    test:
      config: Release
      environmentVariables:
        ORBIT_BENCHMARK: '1'
        ORBIT_BENCHMARK_NOTES: '{args.notes}'
        ORBIT_BENCHMARK_FORMAT: '{args.format}'
      targets:
        - {SCHEME}
"""
    output.mkdir(parents=True, exist_ok=True)
    spec_path = output / "project.yml"
    spec_path.write_text(spec, encoding="utf-8")
    subprocess.run([xcodegen, "generate", "--spec", str(spec_path),
                    "--project", str(output)], check=True)
    print("\nGenerated simulator benchmark project; no build or test was run.")
    print("Use MobileBuildMCP session_show_defaults, then session_set_defaults with:")
    print(json.dumps({"projectPath": str(output / (SCHEME + ".xcodeproj")),
                      "scheme": SCHEME, "configuration": "Release"}, indent=2))
    print("Select an available simulatorId through MobileBuildMCP list_sims.")
    print("Run MobileBuildMCP test_sim with extraArgs:")
    print(json.dumps(["ENABLE_TESTABILITY=YES", "CODE_SIGNING_ALLOWED=NO"]))
    print("ENABLE_TESTABILITY must be a command-line build setting so it also applies "
          "to the Release OrbitCore package used by @testable imports.")
    print(f"Scheme environment: ORBIT_BENCHMARK=1 ORBIT_BENCHMARK_NOTES={args.notes} "
          f"ORBIT_BENCHMARK_FORMAT={args.format}")


if __name__ == "__main__":
    main()
