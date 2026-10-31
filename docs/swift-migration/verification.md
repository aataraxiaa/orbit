# Verification status, 31 October 2026

The user authorized publishing 0.7.0-beta.1 for normal app/MCP testing on 31 October 2026, superseding the strict pre-cutover acceptance gate. Shipping manifests and production packages now use native Swift; Python is retained only as the development compatibility reference. This is not a fully accepted migration: native desktop-host/fresh-conversation, physical iCloud, actual model and comparative performance remain unverified.

## 0.7.0-beta.1 release checks

- MobileBuildMCP universal Release build passed; both arm64/x86_64 slices declare macOS 13 minimum. `initialize` reports `orbit` version `0.7.0-beta.1`, matching all shipping manifests.
- MobileBuildMCP Swift suite: 98 passed. Log `swift_package_test_2026-10-31T10-51-03-520Z_pid29485_6377f2a6.log`.
- Supported Python 3.12 regression/reference/native packaging suite: 192 passed. The first run used Apple Python 3.9 for one PATH-based reference test and failed that interpreter requirement; rerunning with the supported interpreter on PATH passed. This was a development test environment issue, not a native runtime dependency.
- Isolated reference smoke passed. Default native plugin/MCPB/project packaging passed, with no Python runtime files in installed artifacts.
- Official MCP SDK 2.3.0: eight grouped checks passed against the final native runtime, including all 19 tools discovered, exact writes/hashes, retries, refused unsafe writes, history, restart and cache-loss persistence. See `prerelease-sdk-results.json`.
- The app’s merged PR2 is on main at `dbfa56a`; its prerelease follow-up removes the blanket linked-provider gate while preserving actual identity/format/path/download/write validation. The app pins the published core revision; its own handoff records final tests/build and install results.
- Physical app launch succeeded on the connected iPhone on 31 October. The subsequent sandbox Xcode test was canceled after the tool timed out; it did not pass. No iCloud round trip or real model execution is claimed.

The release tag identifies the final source revision and release receipt identifies binary/resource hashes. The earlier source pins and results below are historical compatibility evidence, not the final app pin.

## Tested source and artifacts

OrbitCore package revision: `6657be92ef4012efded9104f3c348882d675c07a`, package `0.7.0-dev`, tool contract 1, disk format 3. Python reference source is `94ffc6ad9be082ceceb2daebb45296ebd53f3863`; its engine remains unchanged as a development-only reference. The app consumes this exact remote revision pin in [app PR2](https://github.com/aataraxiaa/orbit-app/pull/2), commit `e51dc0845e85ee296dacaa65b6ef7fda451c09bd`. LocalInference is pinned separately to version0.2.0. The app [handoff](https://github.com/aataraxiaa/orbit-app/blob/codex/orbit-core-adapter/HANDOFF.md) records adapter/controller ownership and the remaining acceptance gates.

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
| App simulator unit/integration and UI tests after missing-path fix | 26/26 across separate runs | 24 unit/integration in `test_sim_2026-10-30T18-31-27-471Z_pid9527_6ceac1f2.xcresult`; two UI tests in `test_sim_2026-10-30T18-29-11-796Z_pid9527_5a4667be.xcresult` |
| Signed app device build/install/launch | Passed; physical fixture UI failed | Outside-folder rejection remains unresolved; later CoreDevice4016 prevented diagnostic launch |
| Physical-shaped missing-path startup regression | Failed before fix; passed after | App commit `e51dc08`; nearest-existing-ancestor resolution, dangling symlink refusal, EACCES/ENOTDIR preservation |
| Official MCP SDK 2.3.0, relocated native candidate | 8 grouped checks passed | `mcp-sdk-results.json`; three launch manifests, 19 tools each, writes/retries/refusals/history/cache-loss/restart |
| Frozen migration, recovery, schemas, registry and opaque-metadata fixtures | Passed within Swift suite | `tests/fixtures/compatibility` |
| Relocated native Codex, Claude-plugin and MCPB launch configurations | Passed mechanically | `tests/test_swift_package.py` |
| Acceptance package ignores ambient registry even if manifest env is lost | Passed mechanically | Explicit launch argument regression |

The deterministic `orbit-fixture` executable is a development adapter for generated timestamps and UUIDs. It is never packaged. Native plugin candidates contain `orbit-mcp` and its resource bundle, without Python runtime files. Receipt JSON identifies exact executable and resource hashes. Fixture success checks include expected outcomes, not only two equal failures. Cache-path normalization independently verifies each replica's canonical-path/identity-derived cache key before comparison. Permission error normalization is restricted to the injected EACCES projection scenario.

Independent review found and reproduced defects beyond the first fixtures: Foundation JSON key ordering and BOM removal, unknown metadata normalization, stable-ID/name/schema Unicode collisions, numeric coercion, an unbounded parser stack, and nested lock identity. Focused regressions and frozen Python fixtures now cover those fixes. These finite tests support the covered contracts; they do not establish universal native-provider behavior.

## Open acceptance gates

- The user installed Codex acceptance candidate0.7.0-dev. Actual tool discovery still exposed only the shipping `orbit` server, and the callable list returned its existing registry. No native acceptance process or test write was observed. Both manifests shared the server key `orbit`; candidate0.7.0-dev.1 now uses `orbit-swift-acceptance` and an absolute system launcher for the Codex working-directory path. Reinstallation and native save/read/fresh-chat checks remain pending. See `codex-host-results.json`. The computer-use tool still refuses Codex installation controls.
- Claude is absent from the available app inventory. No Claude/Cowork/Chat extension acceptance is claimed.
- The app agent's signed simulator tests exercise the actual core store and approved writes. Physical test-runner provisioning was resolved and app launch succeeded. The actual device UI fixture failed with an outside-folder rejection. A simulator reproduction then identified inconsistent Foundation resolution of an absent device-local `config.json.lock` under an aliased ancestor. The app fixes this with nearest-existing-ancestor resolution and regressions for dangling symlinks and permission errors. All 24 unit/integration and both UI tests passed in separate runs; the signed device build also passed. The exact phone path was not captured and the phone is now disconnected, so physical confirmation remains open. See the app handoff and its committed normalized startup path inventory. Physical UI acceptance has not passed.
- Security-scoped provider bookmarks, pending ancestor downloads, revoked access, offline/reconnect, suspension and actual Mac/phone iCloud delivery remain unverified on physical hardware. Disposable filesystem transport is separate evidence.
- LocalInference is integrated through a bounded validated tool loop, but real weights/model execution and device memory/battery/latency were not exercised. Simulator inference is refused by that runtime.
- The app prerelease follow-up enables normal explicit user-selected folders under user authorization. Sample storage remains limited to demo/tests. Ordinary folder access is available for in-the-wild testing, without a claim of physical provider acceptance.

Use `transition.md` for cutover and rollback. The user authorized production runtime cutover for this beta before these gates passed. Do not claim those unverified behaviors passed; keep the source-only reference and previous release available for rollback.

The mobile chat controller deliberately exposes the shared search/read/schema/apply definitions and enforces a bounded host allowlist. Other maintenance operations remain implemented in OrbitCore and exposed by desktop MCP; mobile chat does not independently redefine them or grant the model migration/recovery authority. Actual model tool quality and usable context capacity remain unverified.

## Independent MCP client acceptance

The user authorized proceeding with an alternative client while Codex marketplace installation remains unresolved. `scripts/verify_native_mcp.py` uses the official Python MCP SDK 2.3.0 as a development client. The server remains the packaged native Swift executable, launched through each relocated Codex, Claude-plugin and MCPB configuration with only system tools on PATH. Test configuration paths are redirected into a fresh temporary directory; the packaged launcher and arguments are otherwise retained. No personal registry or Orbit is read.

Eight grouped checks passed: initialization/tool discovery/ping for each manifest, setup/save/search/read with exact bytes and SHA-256, identical-request retry with one revision, stale-write/path-escape refusal without mutation, fresh-process persistence across manifests, approved update plus two preserved revisions after cache deletion, and absence of packaged Python runtime files. The receipt records the exact binary hash. This establishes SDK interoperability and process persistence, not installed-host or fresh-conversation acceptance.

Reproduce with Python 3.10+ in a development environment containing `mcp==2.3.0`:

```sh
python scripts/verify_native_mcp.py --plugin /absolute/path/to/extracted/plugin --output /absolute/path/to/results.json
```

The client SDK is not a production dependency. Continue the native-host and physical-provider gates before cutover.
