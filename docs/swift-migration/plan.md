# Swift migration execution

31 October update: the user authorized a unified 0.7.0-beta.1 Swift prerelease for normal in-app testing, superseding the strict pre-cutover acceptance sequence. Native-host/iCloud/model checks remain unverified. Shipping artifacts use Swift, Python remains development-only, and the app follow-up enables explicitly selected folders with the same core validation. See HANDOFF.md and transition.md for the current release decision.

Reference: companion main 94ffc6ad9be082ceceb2daebb45296ebd53f3863 and app plan 5024146. The precise companion reference is also recorded by the fixture generator.

Completion requires equivalent results and durable bytes for every supported operation, passing regression and differential fixtures, packaged native MCP installation in desktop hosts, a pinned app integration, and disposable native folder/iCloud round trips. A build or direct executable invocation cannot satisfy host acceptance. No production cutover or Python removal precedes these gates.

Units: capture contract and baseline; port engine and revision state; port schemas, formatting and migration; port retrieval and source integration; integrate shared boundary into MCP and app; exercise parity and recovery; package and verify native hosts/devices; retire Python and document rollback. Independent modules use separate worktrees. All discrepancies remain failures until explained and tested.

The source has 19 tool actions and nine engine modules. Beyond the requested inventory, parity includes graph diagnostics, source byte deduplication, bounded catalogs/context, integration stages and verification evidence, schema-definition conflicts, unknown metadata blocks, external observations, migration journals, and immutable receipts. File format remains 3, with explicit legacy migration support. Package, contract and disk versions remain separate.

The detailed [behavior inventory](inventory.md) maps all public actions and internal preservation responsibilities to their Swift owners. Current proof and open gates are in [verification](verification.md).
