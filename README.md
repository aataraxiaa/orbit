# Orbit

A skills-first plugin for saving, connecting, and recalling knowledge in a local Obsidian vault.
Speak naturally: “Save that to Orbit”, “Check our deployment decisions”, or “What does this connect to?”

Version 0.2.1 is a prerelease for cross-host testing. Markdown and preserved sources remain authoritative.
No MCP, server, daemon, hooks, scheduled capture, cloud service, or required Obsidian community plugin.
Python 3.10+ handles storage and validation. Indexed retrieval uses the Python runtime's SQLite FTS5 support.

## Install

For Codex with native plugin support:

```sh
codex plugin marketplace add aataraxiaa/orbit
codex plugin add orbit@orbit
```

For Claude Code, run these commands inside the app:

```text
/plugin marketplace add aataraxiaa/orbit
/plugin install orbit@orbit
```

Start a fresh conversation and say "Set up Orbit". Select your vault and verify access
in each host. Installing the plugin does not grant access to your notes.
For ZIP uploads and local development, see [installation and testing](LOCAL_TEST.md).

## Use the four skills

| Skill | Behavior |
|---|---|
| orbit-setup | Select a vault, bind it persistently, verify access |
| orbit-save | Integrate selected content, update affected knowledge and maps, verify recall |
| orbit-recall | Orient through maps or retrieve scoped evidence, follow relationships, cite sources |
| orbit-maintain | Inspect incomplete integration, stale evidence, links and provenance; repair requested issues |

## Set up and inspect

```sh
python3 scripts/orbit.py setup /absolute/path/to/Vault --create
python3 scripts/orbit.py doctor
python3 scripts/orbit.py search 'deployment rollback'
python3 scripts/orbit.py search 'migration decision' --scope atlas
python3 scripts/orbit.py catalog --limit 50 --offset 0
python3 scripts/orbit.py relations 'Knowledge/Atlas'
python3 scripts/orbit.py maintain
```

Setup preserves existing conventions and notes. The config defaults to ~/.config/orbit/config.json.
ORBIT_CONFIG isolates a different config. ORBIT_VAULT and --vault explicitly override the binding.
The helper never infers a vault from the working directory.

Existing Second Brain installations remain readable. Orbit uses an existing legacy config
when no new config or explicit override is selected, and accepts `SECOND_BRAIN_*` environment
variables when their `ORBIT_*` equivalents are unset. Existing vaults retain `.second-brain`
state and `SECOND_BRAIN.md` rules, including their UUIDs, recovery records and shared writer lock.
New vaults use `.orbit` and `ORBIT.md`. Conflicting old and new state directories or rules files
require manual resolution. Orbit does not rename user-owned vault folders or rewrite their notes.

## Retrieve evidence efficiently

Search maintains a rebuildable local passage index. It inventories files on each request and reparses changed content.
Titles and aliases affect ranking. Results include matching passages, opening context, line numbers, scope and content hashes.
Selected evidence is checked against live files before return. External edits after that check remain possible.

The cache lives beside the selected config, outside the vault. ORBIT_CACHE overrides its directory.
`index --rebuild` rebuilds derived data without rewriting notes. Indexed search excludes original assets under Sources/assets;
source notes must retain extracted text so it is retrievable. Originals remain available for explicit reads.

Search is lexical, not semantic. Agents expand indirect questions and follow maps and links.
QMD was evaluated as a local candidate but is not a runtime dependency. No model downloads occur during recall.
When indexing is unavailable, unscoped search reports degradation and uses the original live lexical scan.
Scoped search reports unavailable rather than returning unrelated projects. The indexed response has a 12,000-character
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
Recovery refuses subsequent edits. Explicit `recover ID --abandon` preserves current files and releases a conflicted operation
for replanning; it does not undo partial writes. Journals contain historical content and require the same protection as notes.

The parser supports common YAML scalars and lists, not arbitrary YAML interpretation. No automatic rename or deletion operation.

## Test, package and install

```sh
python3 -m unittest discover -s tests -v
python3 scripts/smoke.py
python3 scripts/eval.py --output /absolute/evaluation.json
python3 scripts/package.py
```

Tests and smoke runs use disposable vaults. The evaluation uses labeled synthetic notes and reports helper retrieval only.
Real host, fresh-chat and LLM behavior are separate acceptance checks. See [acceptance](references/acceptance.md).
The built plugin is dist/orbit-plugin.zip; local marketplaces are under dist/marketplace.
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
