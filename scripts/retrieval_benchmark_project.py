#!/usr/bin/env python3
"""Generate a disposable retrieval test project without building Apple code.

The package can point to an older checkout for before/after measurements while
the test sources always come from this checkout. Runtime packaging excludes
scripts, so this development helper is not installed with the Orbit plugin.
"""

import argparse
import json
from pathlib import Path
import re
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
    parser.add_argument("--snapshot", action="store_true",
                        help="include the experimental snapshot suite; requires a snapshot-capable core")
    parser.add_argument("--device-team",
                        help="Apple development team for a signed physical-device test host")
    args = parser.parse_args()
    package = args.package_path.expanduser().resolve()
    output = args.output.expanduser().resolve()
    if args.device_team and not re.fullmatch(r"[A-Z0-9]{10}", args.device_team):
        parser.error("--device-team must be a 10-character Apple development team ID")
    if not (package / "Package.swift").is_file():
        parser.error("--package-path must contain Package.swift")
    filenames = ["RetrievalPerformanceTests.swift", "RetrievalRankingTests.swift"]
    if args.snapshot:
        filenames.append("RetrievalSnapshotTests.swift")
    sources = [ROOT / "tests/OrbitCoreTests" / filename for filename in filenames]
    for source in sources:
        if not source.is_file():
            parser.error("missing test source: " + str(source))
    xcodegen = shutil.which("xcodegen")
    if xcodegen is None:
        parser.error("xcodegen is required to generate the retrieval test project")

    source_yaml = "\n".join("      - path: " + json.dumps(str(path)) for path in sources)
    host = ""
    host_dependency = ""
    signing = "NO"
    team_settings = ""
    if args.device_team:
        output.mkdir(parents=True, exist_ok=True)
        host_source = output / "RetrievalHost.swift"
        host_source.write_text('''import SwiftUI

@main struct RetrievalHost: App {
    var body: some Scene {
        WindowGroup { Text("Disposable Orbit retrieval checks") }
    }
}
''', encoding="utf-8")
        signing = "YES"
        team_settings = f"""        DEVELOPMENT_TEAM: {json.dumps(args.device_team)}
        CODE_SIGN_STYLE: Automatic
"""
        host = f"""  OrbitRetrievalHost:
    type: application
    platform: iOS
    sources:
      - path: {json.dumps(str(host_source))}
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.orbit.RetrievalHost
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
{team_settings}"""
        host_dependency = "      - target: OrbitRetrievalHost\n"
    spec = f"""name: {SCHEME}
options:
  deploymentTarget:
    iOS: '18.0'
packages:
  OrbitCore:
    path: {json.dumps(str(package))}
targets:
{host}\
  {SCHEME}:
    type: bundle.unit-test
    platform: iOS
    sources:
{source_yaml}
    dependencies:
      - package: OrbitCore
{host_dependency}\
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.orbit.RetrievalChecks
        GENERATE_INFOPLIST_FILE: YES
        CODE_SIGNING_ALLOWED: {signing}
{team_settings}\
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
    print("\nGenerated retrieval test project; no build or test was run.")
    print("Use MobileBuildMCP session_show_defaults, then session_set_defaults with:")
    print(json.dumps({"projectPath": str(output / (SCHEME + ".xcodeproj")),
                      "scheme": SCHEME, "configuration": "Release"}, indent=2))
    if args.device_team:
        print("Identify the authorized physical device, then set its deviceId through MobileBuildMCP.")
        print("Run MobileBuildMCP test_device with extraArgs:")
        print(json.dumps(["ENABLE_TESTABILITY=YES", "-allowProvisioningUpdates"]))
    else:
        print("Select an available simulatorId through MobileBuildMCP list_sims.")
        print("Run MobileBuildMCP test_sim with extraArgs:")
        print(json.dumps(["ENABLE_TESTABILITY=YES", "CODE_SIGNING_ALLOWED=NO"]))
    print("ENABLE_TESTABILITY must be a command-line build setting so it also applies "
          "to the Release OrbitCore package used by @testable imports.")
    print(f"Scheme environment: ORBIT_BENCHMARK=1 ORBIT_BENCHMARK_NOTES={args.notes} "
          f"ORBIT_BENCHMARK_FORMAT={args.format}")


if __name__ == "__main__":
    main()
