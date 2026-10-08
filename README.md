# Orbit

A plugin for saving, connecting, and recalling knowledge in your own Obsidian vault.
Say “Save that to Orbit” or “Check our deployment decisions”. The agent uses local
MCP tools; the Python engine handles storage, hashes, indexing and recovery.

Version 0.4.0 adds structured notes and recoverable migrations and remains a desktop prerelease. Markdown and preserved
sources remain authoritative. No cloud service, scheduled capture, hooks or required
Obsidian community plugin. Python 3.10+ must be installed. The launcher checks PATH and standard Homebrew
bin directories when `python3` is older; neither the plugin nor MCPB installs Python. Search uses SQLite FTS5.

## Install

Add the GitHub marketplace `aataraxiaa/orbit` in the app's plugin controls and install
Orbit. In Claude Cowork this is **Customize > Plugins > Add > Add marketplace**.
In Codex desktop use the Plugins directory's marketplace/source controls.
Repository marketplace installs receive updates from the repository.

Start a fresh conversation and say “Set up Orbit”. The agent must call Orbit's MCP
tools, bind your selected vault, save a labeled receipt and read it back. Installation
alone does not establish connection, access or persistence.

Claude Desktop Chat has a separate `orbit.mcpb` desktop extension package using the
same engine. Download it from [v0.4.0](https://github.com/aataraxiaa/orbit/releases/tag/v0.4.0)
and open it in Claude Desktop to install. Download and install a new MCPB for updates;
the GitHub marketplace does not update this separate extension. Its native acceptance and extension-directory publication are pending.
It is not the same distribution channel as the Cowork marketplace plugin. Ordinary
ChatGPT chat remains a separate, unverified surface; this release adds no remote
connector and does not upload or host the vault.

A disposable probe established transport in Codex desktop and Cowork. That is not
acceptance of this production artifact. See [installation and testing](LOCAL_TEST.md)
and [acceptance](references/acceptance.md) for the remaining native checks.

## Use the five skills

| Skill | Behavior |
|---|---|
| orbit-setup | Select a vault, bind it persistently, verify access |
| orbit-save | Integrate selected content, update affected knowledge and maps, verify recall |
| orbit-recall | Orient through maps or retrieve scoped evidence, follow relationships, cite sources |
| orbit-maintain | Inspect incomplete integration, stale evidence, links and provenance; repair requested issues |
| orbit-migrate | Preview, apply, resume, or roll back the appropriate versioned migration |

## Set up and inspect

`orbit_setup` selects a vault. `orbit_doctor` reports access and integrity.
`orbit_search` and `orbit_read` return evidence; `orbit_apply` saves a JSON change plan
with current hashes. The plugin's skills guide source interpretation and verification.
See [tool contracts](references/tools.md) for all operations.

Fresh setup creates format-2 folders and schema notes. Setup preserves existing notes; upgrading their organization is explicit. The config defaults to ~/.config/orbit/config.json.
ORBIT_CONFIG isolates a different config. ORBIT_VAULT and the explicit `vault` argument explicitly override the binding.
The helper never infers a vault from the working directory.

Existing Second Brain installations remain readable. Orbit uses an existing legacy config
when no new config or explicit override is selected, and accepts `SECOND_BRAIN_*` environment
variables when their `ORBIT_*` equivalents are unset. Existing vaults retain `.second-brain`
state and `SECOND_BRAIN.md` rules, including their UUIDs, recovery records and shared writer lock.
New vaults use `.orbit` and `ORBIT.md`. Conflicting old and new state directories or rules files
require manual resolution. Setup does not rename notes; the migration tool provides guarded note moves with link repairs and backup journals.

## Structured knowledge and sessions

Format 2 uses this organization:

```text
Projects/<project>/Overview.md
Projects/<project>/Decisions/
Projects/<project>/Sessions/
Knowledge/
People/
Sources/
Schemas/
Maps/
```

Keep each durable fact in one canonical note. Session summaries capture the objective,
outcomes, open questions, next actions, observed date, and links to current knowledge.
Saving a session is explicit; there is no automatic transcript capture.

Versioned Markdown schema notes describe the required fields and sections for each type.
Validation warns by default. Set a schema to strict when missing fields should block a
save. Use `orbit_schema` to inspect definitions and findings. The common identity and
content-preservation checks always apply. See [the data contract](references/format.md).

Use `orbit_search` or `orbit_catalog` with `note_type: "session"` to resume a project,
or `note_type: "decision"` and `status: "current"` for current decisions. Ordinary
results exclude schema notes and vault rules. SQLite indexes passages, summaries, and
metadata incrementally; Markdown remains authoritative.

## Upgrade an existing vault

Update the plugin, start a fresh conversation, and ask to migrate your Orbit vault.
There is one `orbit-migrate` skill. It selects version-specific reference instructions
using the observed data format and target release, previews changes, and calls the
migration engine with the preview's digest. Format 1 upgrades to format 2; format 2
receives a compatibility check. Unknown formats and downgrades are refused.

Legacy markers do not identify an exact originating app release. Orbit reports that
release as unknown and routes by data format. Backups retain exact affected file bytes;
interrupted runs can resume or roll back, refusing subsequent human edits. Ambiguous
project ownership and unsupported links block the plan rather than guess. Original
assets and historical receipts remain intact. Affected integration verification becomes
historical and needs re-verification. Plugin installation never migrates a vault silently.

## Retrieve evidence efficiently

Search maintains a rebuildable local passage index. It inventories files on each request and reparses changed content.
Titles, aliases, and summaries affect ranking. Type and status filters distinguish sessions, decisions, and current knowledge. Results include matching passages, opening context, line numbers, scope and content hashes.
Selected evidence is checked against live files before return. External edits after that check remain possible.

The cache lives beside the selected config, outside the vault. ORBIT_CACHE overrides its directory.
`orbit_index` with `rebuild: true` rebuilds derived data without rewriting notes. Indexed search excludes original assets under Sources/assets;
source notes must retain extracted text so it is retrievable. Originals remain available for explicit reads.

Search is lexical, not semantic. Agents expand indirect questions and follow maps and links.
QMD was evaluated as a local candidate but is not a runtime dependency. No model downloads occur during recall.
When indexing is unavailable, unfiltered search reports degradation and uses the original live lexical scan.
Scoped or typed search reports unavailable rather than returning unrelated notes. The indexed response has a 12,000-character
serialized limit, not a guaranteed token limit. Read additional windows when results are truncated.

## Maintain knowledge and navigation

The catalog provides paginated inventory without overwriting authored maps. Save and maintain skills create and update
useful entry, project, and topic maps through ordinary conflict-checked writes. Map explanations require agent judgment.
Explicit prose relationships retain type, direction, basis, source line and hash. Untyped wikilinks remain navigation.
Recorded relationships are claims, not independently verified facts.

Captured sources have durable processing records. Stages distinguish capture, extraction, integration and verified retrieval.
Extraction requires saved text evidence and declared coverage. Integration references committed note operations and current hashes.
Verification executes recall queries. Partial extraction and deferred work remain visible. This verifies mechanical evidence,
not factual truth or completeness of an LLM's interpretation. See [tool contracts](references/tools.md).

Maintenance reports unfinished integration, changed evidence, broken links, malformed records and missing code provenance.
It does not automatically reconcile facts or execute repository paths from notes. Current-code claims require live source checks.

## Preserve existing work

Apply validates stable IDs, expected hashes, required metadata and link targets, including literal headings and block anchors.
Unknown metadata blocks must remain verbatim. The skill must still preserve unrelated user prose during full-note replacement.
Changes use per-file atomic writes and recovery journals. A batch is recoverable, not filesystem-atomic.
External editors do not honor the helper lock. Checks immediately before writes narrow but cannot eliminate that race.
Recovery refuses subsequent edits. Explicit `orbit_recover` with `abandon: true` preserves current files and releases a conflicted operation
for replanning; it does not undo partial writes. Journals contain historical content and require the same protection as notes.

The parser supports common YAML scalars and lists, not arbitrary YAML interpretation. Ordinary saving cannot rename or delete notes. Explicit migrations perform guarded moves.

## Test, package and install

```sh
python3 -m unittest discover -s tests -v
python3 scripts/smoke.py
python3 scripts/eval.py --output /absolute/evaluation.json
python3 scripts/package.py
```

Tests and smoke runs use disposable vaults. The evaluation uses labeled synthetic notes and reports helper retrieval only.
Real host, fresh-chat and LLM behavior are separate acceptance checks. See [acceptance](references/acceptance.md).
Build outputs are `dist/orbit-plugin.zip`, `dist/orbit.mcpb`, and `dist/orbit-project.zip`; local marketplaces are under `dist/marketplace`.
See [local installation](LOCAL_TEST.md). Keep personal-vault adoption separate from package verification.
Release ZIPs are available from [GitHub Releases](https://github.com/aataraxiaa/orbit/releases).

## Prerelease limitations

Search uses lexical matching. The previous development evaluation retrieved all required evidence
for 50 of 60 harder synthetic questions, below the 95% target. Paraphrases and questions needing
multiple notes remain the main gaps. This is a helper retrieval measurement, not an LLM accuracy score.
A fresh Codex CLI conversation passed the earlier save/recall scenario. Claude execution and
Desktop/Cowork behavior have not passed equivalent acceptance checks. See [acceptance](references/acceptance.md).

## References

The design draws on [Obsidian Second Brain](https://github.com/eugeniughelbur/obsidian-second-brain),
[Karpathy's wiki pattern](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f),
[Basic Memory](https://github.com/basicmachines-co/basic-memory),
[Ars Contexta](https://github.com/agenticnotetaking/arscontexta), and [QMD](https://github.com/tobi/qmd).
No upstream implementation code is vendored.
