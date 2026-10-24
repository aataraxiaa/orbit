# Orbit handoff

Updated 2026-10-24. Orbit v0.5.0 beta release. Native acceptance remains incomplete.

## Scope

The user superseded the no-MCP constraint on 2026-10-07. The target is an MCP-backed
marketplace plugin for the ChatGPT/Codex and Claude desktop apps, including Cowork.
CLI support is not an acceptance target. Preserve the Python engine and Markdown
vault contract. A disposable probe established Codex desktop and Cowork transport. Installed
0.5.0 save/search/read passed in one Codex desktop conversation; cross-app and fresh-conversation acceptance remain separate gates. Do not
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
- Six skills own source interpretation, useful map curation, knowledge integration and evidence-based answers.

The derived cache stays outside the synced vault, keyed to vault identity and canonical path.
Source integration records stay in .orbit/integrations. They survive cache loss.
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

## 0.4.1 migration patch

The 0.4.0 migration project lookup omitted a project note's own project field.
A decision could use the same project field as the sole project note yet fail
when that note had a different display title. The patch accepts explicit unique
project-field identities while preserving collision refusal. Data format stays 2;
existing format-2 vaults require only the migration skill's compatibility check.

## 0.5.0 named Orbits release

`scripts/registry.py` owns the named schema-2 config and immutable operation targets.
Dispatch resolves once and adds the target receipt. Existing storage, per-vault locks
and path/identity cache isolation remain unchanged. There is no global active selection.
Agents and workflow hooks pass an explicit Orbit name on every scoped call.

Setup requires a name and path. Registration is atomic and preserves initialized vault
files. The user explicitly chose a clean beta configuration with a one-time local repair;
no schema-1 config upgrade, restore tool or Second Brain runtime compatibility ships.
Vault data format remains 2; existing data-format migration routes remain available.

Current mechanical verification belongs in review-artifacts/orbit-only under the project
artifact directory. Native desktop, cross-app, fresh-chat and LLM selection acceptance
are separate. Building the candidate does not install or publish it.

The 0.5.0 prerelease is published and its MCP tools are installed in Codex desktop.
The former local single-folder binding was repaired to the named registry with a backup.
This local configuration repair is not a shipped migration route.

## Setup and routing follow-up

`orbit_rename` changes a registry name under the same config lock as setup. It preserves
folder paths, stable identities, content and unknown config fields. Old names refuse;
there are no aliases or global active selections. Setup can link any existing ordinary
folder. User-facing language is Orbit and folder; Obsidian remains optional.
Agent guidance prioritizes the current request's explicit destination, then conversation
selection, then the sole entry, otherwise asks. Confirmations require target receipts
and content readback. Mechanical evidence is under review-artifacts/setup-routing.
The broader native routing matrix remains unverified. The bounded Codex checks below passed.

## 2026-10-24 native verification

Installed 0.5.0 MCP tools passed named-folder registration, save/search/read, registration
rename and format compatibility checks for two folders in one Codex desktop conversation.
Fresh-conversation, concurrent-chat, restart, Claude and cross-app acceptance remain separate.
Personal content organization and physical folder renames were authorized one-time local
operations. They added no plugin code or general relocation tool. Keep private notes,
paths and migration backups out of the repository and release packages.

The built-in format-1 migrator can refuse collisions in an already-organized nested
collection because it computes destinations by note type and filename. A custom full
organization is not equivalent to orbit-format, and must not be advertised as such.

## Format existing notes

`formatting.py` and the `orbit-format` skill add absent metadata in place through
`orbit_format`, with a preview by default. Body bytes, existing fields, custom
metadata blocks, paths, assets and format markers remain unchanged. The parser
conservatively refuses unsupported required values and ambiguous headers.
Formatting uses the existing lock, atomic writes, journals and recovery. Existing
link findings become warnings for this operation only; new graph problems,
duplicate IDs and strict schema errors still block writes. There is no data-format
change or additional migration route. Mechanical receipts belong in
review-artifacts/format-notes. Native host and LLM behavior remain separate gates.
