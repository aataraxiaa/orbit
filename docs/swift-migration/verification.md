# Verification status, 30 October 2026

The migration is not complete. Native desktop-host installation/fresh-conversation acceptance, physical folder/iCloud round trips, and actual on-device model execution remain open. Python remains the shipping desktop runtime. No release or merge is authorized by this report.

## Tested source and artifacts

OrbitCore package revision: `6657be92ef4012efded9104f3c348882d675c07a`, package `0.7.0-dev`, tool contract 1, disk format 3. Python reference source is `94ffc6ad9be082ceceb2daebb45296ebd53f3863`; its engine remains unchanged. The app consumes an exact remote revision pin, coordinated through its integration PR.

MobileBuildMCP built a universal arm64/x86_64 Release executable. Both slices record macOS13 minimum deployment. Execution checks ran on the current Apple Silicon Mac. Intel hardware and a separate Mac without a development toolchain were not available. The relocated checks remove developer/Python tools from PATH, and linked dependencies are system libraries/frameworks.

## Mechanical results

| Check | Result | Evidence |
|---|---:|---|
| Swift package tests through MobileBuildMCP | 98 passed | Tests under `tests/OrbitCoreTests`; build log `swift_package_test_2026-10-30T16-57-18-702Z_pid45877_d9e7e676.log` |
| Python reference regression plus native packaging tests | 191 passed | 188 original tests and three `test_swift_package.py` checks |
| Isolated reference smoke | Passed | `scripts/smoke.py` |
| Reference plugin/MCPB/project archive rebuild | Passed | `scripts/package.py` |
| All 19 tools through equivalent deterministic MCP requests | 38/38 | `all-tools-results.json` |
| Original synthetic retrieval corpus, 100 notes and 120 requests | 120/120 | `retrieval-results.json` |
| Mixed Python/Swift transport, faults, retries and local process locks | 157/157 | `mixed-replica-results.json` |
| Mixed concurrent source integration with controlled clocks/UUIDs | 53/53 | `mixed-integration-results.json` |
| Historical byte-distinct Unicode identities through production executables | 55/55 | `mixed-unicode-results.json` |
| Frozen migration, recovery, schemas, registry and opaque-metadata fixtures | Passed within Swift suite | `tests/fixtures/compatibility` |
| Relocated native Codex, Claude-plugin and MCPB launch configurations | Passed mechanically | `tests/test_swift_package.py` |
| Acceptance package ignores ambient registry even if manifest env is lost | Passed mechanically | Explicit launch argument regression |

The deterministic `orbit-fixture` executable is a development adapter for generated timestamps and UUIDs. It is never packaged. Native plugin candidates contain `orbit-mcp` and its resource bundle, without Python runtime files. Receipt JSON identifies exact executable and resource hashes. Fixture success checks include expected outcomes, not only two equal failures. Cache-path normalization independently verifies each replica's canonical-path/identity-derived cache key before comparison. Permission error normalization is restricted to the injected EACCES projection scenario.

Independent review found and reproduced defects beyond the first fixtures: Foundation JSON key ordering and BOM removal, unknown metadata normalization, stable-ID/name/schema Unicode collisions, numeric coercion, an unbounded parser stack, and nested lock identity. Focused regressions and frozen Python fixtures now cover those fixes. These finite tests support the covered contracts; they do not establish universal native-provider behavior.

## Open acceptance gates

- Codex's computer-use tool refuses access to the application, so agent-driven installation controls and fresh-conversation checks could not run. A separately named acceptance candidate and isolated paths are prepared for manual installation.
- Claude is absent from the available app inventory. No Claude/Cowork/Chat extension acceptance is claimed.
- The app agent's signed simulator tests exercise the actual core store and approved writes. Physical test-runner provisioning and a locked Mac/iPhone blocked the intended device tests. A signed app build alone is not device acceptance.
- Security-scoped provider bookmarks, pending ancestor downloads, revoked access, offline/reconnect, suspension and actual Mac/phone iCloud delivery remain unverified on physical hardware. Disposable filesystem transport is separate evidence.
- LocalInference is integrated through a bounded validated tool loop, but real weights/model execution and device memory/battery/latency were not exercised. Simulator inference is refused by that runtime.
- The linked-provider gate stays enforced until native acceptance. Sample storage is limited to explicit demo/tests; this does not make the still-gated linked-folder experience production-accepted.

Use `transition.md` for cutover and rollback. Do not remove the Python production runtime or claim the required final state before these gates pass.
