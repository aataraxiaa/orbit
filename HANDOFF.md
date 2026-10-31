# Orbit handoff

31 October 2026: latest prerelease 0.7.0-beta.2 adds typed metadata inspection (`OrbitFileAccessMode.inspect`), preventing pending excluded assets from blocking native catalogs. Actual data reads still use `.read` and require availability. The app must consume the matching core revision and handle `.inspect` with containment but without leaf hydration. Core suite: 101 passed.

31 October 2026: the user explicitly authorized publishing a unified Swift prerelease and testing normal app/MCP flows in the wild, superseding the earlier requirement to keep Python shipping until formal native acceptance. Version `0.7.0-beta.1` ships the universal native `bin/orbit-mcp`, shared OrbitCore, all 19 tools and six skills. `scripts/package.py` now produces native-only plugin/MCPB packages. Python stays in the source checkout only as the development compatibility reference; v0.6.0 remains available for rollback. Disk format stays 3 and the default format-3 migration is a compatibility check.

The app integration PR2 was merged into app main at `dbfa56a`; a follow-up enables normal explicitly selected folders and pins the published core. Temporary provider acceptance UI is not part of the normal release flow. Existing identity, format, containment, pending-download, approval, citation and retry protections remain required.

Read [architecture](docs/swift-migration/architecture.md), [verification](docs/swift-migration/verification.md), and [transition/rollback](docs/swift-migration/transition.md). Unit, differential and SDK results are evidence only for their covered cases. Native desktop-host, physical iCloud, actual model and comparative performance remain unverified. Do not call this a fully accepted migration or a stable release.

The entries below are historical records for their named Python releases. Their Python shipping/install statements do not describe 0.7.0-beta.1.

Updated 2026-10-25. Orbit v0.6.0 testing prerelease.
Native two-Mac iCloud and cross-app acceptance remain unproven.

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

- scripts/replication.py owns immutable commits, unanchored observations, ancestry, local locks and checkout recovery for format 3.
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
For the 0.5.0 release, existing format-2 folders required only its compatibility check.
The 0.6.0 format-3 route below supersedes that target.

## 0.5.0 named Orbits release

`scripts/registry.py` owns the named schema-2 config and immutable operation targets.
Dispatch resolves once and adds the target receipt. Existing storage, per-vault locks
and path/identity cache isolation remain unchanged. There is no global active selection.
Agents and workflow hooks pass an explicit Orbit name on every scoped call.

Setup requires a name and path. Registration is atomic and preserves initialized vault
files. The user explicitly chose a clean beta configuration with a one-time local repair;
no schema-1 config upgrade, restore tool or Second Brain runtime compatibility ships.
That release retained data format 2; the 0.6.0 candidate now adds the format-3 route below.

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


## 0.6.0 revision prerelease

Fresh empty folders use format 3 and seed the initial schema notes. Existing formats
1/2 remain legacy until an explicitly authorized migration. Format 1 must first use
target_version 0.5.0 to reach 2, then a new preview targets 0.6.0 to reach 3. Format 2→3
seeds exact Markdown/integration bytes before advancing the marker. Journals support
preview, backup, resume, repeated runs and rollback; changed content or subsequent
history refuses recovery. Upgrade every participating plugin first. The marker causes
old clients to refuse only after they receive it; it cannot remotely fence offline writers.

Accepted writes are immutable self-contained files under .orbit/commits. Observed
unexplained editor content is retained under .orbit/observations without assigned ancestry.
Both are durable data and must travel with the Markdown. SQLite remains derived.
ORBIT_STATE defaults to ~/.local/state/orbit independently of the selected config and holds machine-local OS
locks/checkout recovery outside the synced folder, independently of ORBIT_CACHE.
All local app hosts sharing one physical folder must share that state base; different
ORBIT_STATE overrides would split their local locks.

orbit_sync offers status, reconcile and history with a path. It consumes already
delivered files and never uploads, starts a daemon or proves peer freshness. Read tools
also reconcile eligible revisions and retain observations; they do not create resolution
commits. Different-note writes can converge after complete delivery. Concurrent heads
and unexplained bytes block canonical recall for the affected path until an explicit
apply supplies reviewed full content, exact expected_heads and observations. Complete
request retries reuse one canonical request_id UUID; changed requests require a new ID.
Integration transitions use the same revision mechanism rather than racing mutable versions.

The preservation contract covers accepted Orbit writes and external bytes actually
observed and retained. It cannot recover editor versions overwritten before observation.
Local acceptance is distinct from successful projection, upload and remote availability.
Operation eligibility is grouped, while Markdown checkout remains atomic per file only.
No automatic merge, pruning or inference of deletion from missing downloaded files.

Current source tests cover disposable replicas, reordered delivery and migration
recovery. Consult the current run receipts for exact counts and candidate identity;
older test totals above apply to their named releases. No passing mechanical suite,
package build or prior 0.5.0 host receipt establishes native 0.6.0 iCloud or two-Mac
behavior. Required next acceptance: install the exact candidate on both Macs and
actual Codex/Claude hosts, exercise offline different/same-note writes, reconnect,
resolve explicitly and confirm fresh-conversation readback. Do not migrate personal
folders as part of development acceptance.

### Candidate verification, 2026-10-25

The final mechanical suite passes 188 tests on Python 3.14, including 21 engine,
18 replica-transport, 11 format-3 migration and 5 public MCP workflow tests.
The isolated smoke run passes. Rebuilt plugin ZIP, MCP bundle and project ZIP
are in `dist/`. Native 0.6.0 desktop and two-Mac iCloud acceptance remain untested.

Independent review found and verified fixes for aliased conflict reads, same-ID
notes at different paths, and conflicted schema definitions. Setup interruption
and cross-config local locking also have regression coverage. These are simulated
transport and fresh-process MCP results, not a release activation receipt.
