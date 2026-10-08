# Orbit handoff

Updated 2026-10-07. Orbit v0.4.0 prerelease, not yet accepted in all desktop surfaces.

## Scope

The user superseded the no-MCP constraint on 2026-10-07. The target is an MCP-backed
marketplace plugin for the ChatGPT/Codex and Claude desktop apps, including Cowork.
CLI support is not an acceptance target. Preserve the Python engine and Markdown
vault contract. A disposable probe established Codex desktop and Cowork transport. Production-artifact
save/read, cross-app and fresh-conversation acceptance remain separate gates. Do not
publish another desktop-support claim based on CLI or helper tests alone.
The user authorized the Orbit rename and publication to public aataraxiaa/orbit.
Personal-vault migration remains separate from development and disposable-vault acceptance.
The public source repository is https://github.com/aataraxiaa/orbit.

## Modules

- scripts/mcp_server.py exposes validated MCP schemas and delegates to the existing engine.
- scripts/orbit.py owns setup, config, safe paths, authoritative writes, read and recovery.
- scripts/retrieval.py owns a machine-local incremental FTS5 passage index, scoped ranking and current evidence checks.
- scripts/knowledge.py owns catalogs, explicit relationships, durable integration stages and maintenance diagnostics.
- scripts/eval.py evaluates labeled synthetic helper retrieval from tests/fixtures/retrieval.
- Five skills own source interpretation, useful map curation, knowledge integration and evidence-based answers.

The derived cache stays outside the synced vault, keyed to vault identity and canonical path.
Source integration records stay in .orbit/integrations for new vaults, or the existing legacy state directory. They survive cache loss.
Metadata fields and note prose remain user-owned. Unknown metadata blocks must remain verbatim.
Sources/assets originals cannot participate as canonical identities or ordinary indexed search results.

## Verification and limitations

The v0.2.1 patch supports Python 3.10. Startup previously rejected it, and cache
recovery depended on SQLite error attributes introduced in Python 3.11. The fallback
recognizes exact corruption messages and preserves locked or unknown-error caches.
The v0.3.0 suite has 71 passing tests on Python 3.10.20 and 3.14.6 on macOS.
The isolated smoke workflow passes on both. Native Codex plugin installation and
resolved-server setup/save/search/read/fresh-process read pass. The launcher discovers
an installed supported Python when the app resolves python3 to Apple Python 3.9.
Production MCP vault setup in Cowork remains unverified in the real app. The probe
used a native Mac MCP process, separate from the shell sandbox.

Read current test/evaluation and host receipts in the project artifact directory printed by
~/.agents/bin/agent-task-dir, under review-artifacts/v2/. The plan is review-artifacts/v2-plan.md.
Do not infer successful LLM or GUI behavior from passing helper tests.
QMD 2.8.3 was installed only in task artifacts for comparison. Embedding/model-context initialization
failed on this host. QMD is not a plugin dependency; lexical search remains the validated built-in mode.
Do not claim semantic matching, arbitrary YAML support, whole-vault transactions, or universal host acceptance.

Run python3 -m unittest discover -s tests -v, python3 scripts/smoke.py and python3 scripts/package.py
before handing off a changed artifact. Use disposable vaults with isolated ORBIT_CONFIG and ORBIT_CACHE.

## Desktop distribution

MCP is the skills' primary route. Codex and Claude have distinct launch manifests; the
Claude variable is not expanded by Codex. The MCPB is a separate Claude Chat extension
artifact. None of these artifacts installs Python; the desktop runtime needs Python
3.10+ on PATH or in a standard Homebrew bin directory. Ordinary ChatGPT chat remains unverified and no remote
server or vault upload is included. Publication and host receipts must identify the
exact candidate and distinguish production behavior from the disposable probe.

## Format-2 release

Version 0.4.0 adds standard project/decision/session organization, seven optional
versioned Markdown schemas, and type/status-aware SQLite search and catalog.
`structure.py` owns schemas, `migration.py` owns format routes and recoverable
backup journals. One orbit-migrate skill selects version-specific reference files.
The supported routes are legacy format 1 to 2 and format-2 compatibility checks.
Missing legacy release metadata remains unknown. Source assets and historical
receipts remain preserved; changed integration evidence is flagged for review.
The existing suite results above describe v0.3.0, not this candidate. Current
release test receipts are in review-artifacts/structure-release/. No personal
vault migration or native desktop acceptance is inferred from those checks.
