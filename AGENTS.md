# Project instructions

Read HANDOFF.md and LOCAL_TEST.md first. This is the Orbit plugin.
The target is marketplace-plugin installation in the ChatGPT/Codex desktop app and
the Claude desktop app, including Cowork. CLI support is not an acceptance target.
The user authorized MCP-backed plugins on 2026-10-07, superseding the earlier no-MCP rule.
Preserve the existing Python storage engine and Markdown vault contract. Prove native
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
