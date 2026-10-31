# Project instructions

Read HANDOFF.md and LOCAL_TEST.md first. This is the Orbit plugin.
The target is marketplace-plugin installation in the ChatGPT/Codex desktop app and
the Claude desktop app, including Cowork. CLI support is not an acceptance target.
The user authorized MCP-backed plugins on 2026-10-07, superseding the earlier no-MCP rule.
The user authorized a complete Swift replacement on 2026-10-30. Preserve the Markdown folder contract. On 2026-10-31 the user authorized a Swift prerelease for in-app testing before formal native acceptance. Shipping manifests and packages now use native Swift; Python remains only as a development compatibility reference and in the previous release for rollback. Native-host/iCloud/model acceptance remains unverified and must be reported honestly. Read docs/swift-migration/architecture.md and transition.md. Prove native
plugin connection, save/read across apps, and fresh-conversation persistence before
claiming desktop support. CLI and mechanical tests are separate evidence.
Publication is authorized to public aataraxiaa/orbit for this release.
Use a disposable vault and isolated ORBIT_CONFIG and ORBIT_CACHE for tests; never infer the user's
vault or code-directory location. Preserve unknown note fields and user-written content.
Run `python3 -m unittest discover -s tests -v`, `python3 scripts/smoke.py`, and rebuild
with `python3 scripts/package.py` before handing off a changed installable artifact.
Distinguish mechanical test results from untested real-host/LLM behavior.

## Release migrations

Every Orbit release must include an up-to-date migration skill for upgrading existing
Orbit data from the previous release to the new release. Cover changes to schemas,
metadata, folder layout, and persistent state. If no migration is needed, the skill
must verify compatibility and report that no changes are required.
Preserve stable note identities, links, original sources, unknown metadata, and
user-written content. Provide a dry run, a recoverable backup, and safe reruns.
Verify the migration on disposable copies of older vaults, including an interrupted
run and a repeated run, before release. Do not release a data-format change without
a tested migration path and documented supported source versions.

## Swift development

Use MobileBuildMCP for supported Apple builds, tests and UI verification. Both desktop and app use the shared OrbitCore command resources. Keep package, contract and disk versions distinct. Run differential and mixed-replica checks before cutover; passing unit tests is not native plugin acceptance. Do not release or merge without current user authorization.
