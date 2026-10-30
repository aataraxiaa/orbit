# Validate and switch the native runtime

The default desktop manifests still launch Python. The separate Swift candidate contains the native executable and matching resource bundle, without Python runtime modules. No release has been published.

1. Run the frozen Python regression suite with a supported interpreter, the smoke workflow, and the existing package build.
2. Build and test OrbitCore through MobileBuildMCP. Run `scripts/swift_compatibility.py` against the built executable. Run the mixed-replica runner and all frozen migration/recovery fixtures. Investigate every discrepancy.
3. Build the intended Mac architectures through MobileBuildMCP. Stage each matching binary and resource bundle with `scripts/package_swift.py`. Record binary/resource hashes. Verify extracted launch configurations and relocation on a Mac without the development toolchain.
4. Install the exact candidate through each supported desktop host's plugin controls. Use isolated disposable config/cache/state locations and dedicated test folders. Verify tool discovery, registration, save, search, full read, exact retry, process restart and fresh-conversation persistence. Repeat across Codex and Claude/Cowork. Shell invocation does not satisfy this step.
5. Pin the app to the tested repository revision. Validate exact preview approval, cancellation and suspension retries, distinct search scope and save destination, citations and actual receipts through the production store.
6. With disposable Orbits, verify native folder bookmarks, provider downloads and missing ancestors, revoked access, offline reads/writes, concurrent edits, suspension, restart and Mac/mobile round trips. Test mixed Python/Swift replicas during overlap. Do not infer deletion from unavailable files or upload from local acceptance.
7. Only after all required acceptance receipts pass, switch the shipping manifests and package builder to native Swift. Remove superseded Python production runtime files, retaining the frozen reference only in development fixtures or an explicitly separated compatibility archive. Update installation documentation and migration compatibility instructions. Open the release PR; do not merge or publish without authorization.

## Roll back without losing accepted data

Stop every writer before switching a local installation. Preserve the complete disposable or user-authorized folder, including `.orbit/commits`, `.orbit/observations`, original assets and migration backup journals. Preserve the device-local registry and recovery state separately. Do not restore an older Markdown-only backup over accepted history.

The candidate keeps format 3 and its existing protocol. A rollback to the reference Python `94ffc6a` can consume compatible accepted Swift snapshots only after the mixed-runtime fixtures and real-folder test pass. If the old reader reports invalid, incomplete or conflicting evidence, keep both copies and stop writes. Do not prune evidence or reset heads to make rollback appear successful.

Restore the previous plugin installation through its host controls and verify its tools in a fresh conversation against the disposable copy first. Reuse the identical persisted request and UUID after ambiguous acceptance. Restore content through a new reviewed revision, not by mutating history. A format-2 to format-3 migration rollback remains the explicit journaled operation and refuses subsequent edits/history.

## Acceptance status

Mechanical fixture results are recorded separately from native-host and iCloud receipts. Native acceptance remains required. The UI automation tool currently denies access to the Codex application, and the available app inventory contains no Claude host. This blocks agent-driven installation verification through those controls; it is not a passing connection result. Physical provider and cross-device tests also require accessible signed devices and disposable provider folders.
