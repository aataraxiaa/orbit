# Tool access

Resolve the installed plugin root from the skill's directory using `../..`.
Do not assume the working directory is the plugin
or vault. Use an absolute script path and quote shell arguments. Prefer writing JSON
plans with the host file editor; never interpolate source text into shell commands.

Use the host agent’s existing execution tools with Python 3.10+:

```sh
python3 /absolute/plugin/scripts/orbit.py setup /absolute/vault --create
python3 /absolute/plugin/scripts/orbit.py doctor
python3 /absolute/plugin/scripts/orbit.py search 'deployment rollback'
python3 /absolute/plugin/scripts/orbit.py read 'Knowledge/Atlas.md'
python3 /absolute/plugin/scripts/orbit.py context 'Knowledge/Atlas' --depth 1
python3 /absolute/plugin/scripts/orbit.py capture /absolute/source.pdf
python3 /absolute/plugin/scripts/orbit.py apply /absolute/plan.json --dry-run
python3 /absolute/plugin/scripts/orbit.py apply /absolute/plan.json
```

Vault precedence: `--vault PATH`, ORBIT_VAULT, persistent config at
`~/.config/orbit/config.json`. ORBIT_CONFIG overrides config location.
An explicit vault selection is never inferred from cwd. Each machine/sandbox must
bind a path it can actually access. Do not assume a GUI process inherits shell env vars.

## Save plan

```json
{
  "summary": "Preserve the approved Atlas deployment decision",
  "changes": [{
    "path": "Knowledge/Atlas.md",
    "expected_sha256": "the exact hash returned by read, or null for a new note",
    "reason": "Integrate the user's selected deployment rationale",
    "content": "complete updated Markdown including frontmatter"
  }]
}
```

Read all portions of an existing note before drafting a replacement. Preserve stable
ids, unknown metadata, unrelated prose and user annotations. Include all mutually
linked new notes in one plan; validation resolves against the proposed final state.
Dry-run is useful for catching mistakes, not a request for extra user confirmation.
The user's explicit save authorizes routine additions and updates within that scope.

Apply checks expected hashes, required metadata, duplicate ids and link targets. It
journals before replacing files and returns changed paths/reasons. Individual files
are atomic; the whole batch is recoverable, not atomic. External tools do not honor
our write lock: avoid concurrent editing during a save. Never blindly retry a conflict.

No automatic deletion, renaming, arbitrary command execution or web fetching. Capture
only copies a user-selected file; it neither extracts nor integrates it.

## Search and read

Search inventories current Markdown on every call, including manual edits. It ranks
indexed passages with BM25 plus title/alias weighting and includes historical notes.
It does NOT compute embeddings. The skill supplies alternate wording and relationship
traversal. Do not describe results as semantic search or claim exhaustive recall.
Search results are leads: read evidence, expanding line windows as needed. Context
returns incoming and outgoing link neighbors with bounded depth, not their full text.

## Recovery

`doctor` lists pending journal ids. `recover ID` completes a prepared operation;
`recover ID --rollback` restores its before-state. Both refuse subsequent user edits.
On abrupt process death, a write.lock may remain. Inspect .orbit/write.lock,
verify the owner process is no longer running and no host is writing, then remove only
that stale lock before recovery. Do not auto-expire a lock on elapsed time alone.
Committed operation journals contain before/after content: they are local history,
not a secret-free log. Treat them like the vault in backups and access control.

## Indexed search and navigation in v0.2

`search` uses an incremental SQLite FTS5 passage index. Python must provide FTS5.
The cache defaults to `cache/` beside the selected config file; ORBIT_CACHE can
select another machine-local directory. Never put caches inside the synced vault.
The cache is rebuildable. Notes and integration records are authoritative.

```sh
python3 /absolute/plugin/scripts/orbit.py index
python3 /absolute/plugin/scripts/orbit.py index --rebuild
python3 /absolute/plugin/scripts/orbit.py search 'rollback decision' --scope atlas
python3 /absolute/plugin/scripts/orbit.py catalog --limit 50 --offset 0
python3 /absolute/plugin/scripts/orbit.py catalog --scope atlas
python3 /absolute/plugin/scripts/orbit.py relations 'Knowledge/Atlas'
python3 /absolute/plugin/scripts/orbit.py maintain --limit 20
python3 /absolute/plugin/scripts/orbit.py integration
python3 /absolute/plugin/scripts/orbit.py integration /absolute/update.json
```

Search scope matches exact project metadata or a vault-relative path prefix. Catalog
scope matches project or topic metadata. Search returns the best passage and opening
context with current note hashes and line numbers. Output is limited to 12,000 serialized
characters, not a guaranteed token count. Read more when coverage reports truncation.
Original assets are excluded from ordinary indexed search; extract their useful text
into source notes. Read captured originals explicitly when needed.

Every query inventories visible Markdown, reparsing changed files. Selected evidence
is hash-checked against live files. A filesystem is not a snapshot; edits after this
check remain possible. On cache failure unscoped search falls back to live lexical
search and reports degradation. Scoped search fails visibly instead of silently returning
another project's results. No embeddings or downloads are part of this search mode.

Catalog and maintenance do not write notes. Use catalog output to orient and draft useful
maps, then save them through ordinary conflict-checked apply. Relations report recorded
claims, never independently verified causation. Maintenance flags structural faults,
changed integration evidence and absent code provenance. Verify code revisions against
the live repository before using a historical claim as current guidance.

## Advance a source integration

Capture returns a `processing` record containing source_sha256 and version. Save extracted
text in a source note using apply. Then submit an update file using the following shape.
All note hashes come from read; operation IDs come from committed apply receipts.

```json
{
  "source_sha256": "digest from capture",
  "expected_version": 1,
  "stage": "extracted",
  "coverage": {"status": "partial", "description": "Only the supplied excerpt was available"},
  "extraction": [{"path": "Sources/Planning.md", "sha256": "hash from read"}]
}
```

Next, submit `stage: integrated`, the latest expected_version, `notes` containing affected
path/hash objects and `operations` containing committed operation IDs oldest first.
The original `operation` field accepts one operation for compatibility. Supply multiple
operations for batches. Do not include an unchanged note unless a listed operation actually
wrote that version.

Finally submit `stage: verified` with `verification` entries containing `query` and expected
`paths`. Every affected note must be found across these queries. Each transition rechecks
source and evidence hashes. Keep `deferred` and `errors` as lists of explanatory strings.
Read the record after an interrupted transition and resume from its actual stage. Identical
retries converge. If later edits invalidate verified evidence, maintenance reports that
fact; revise evidence and reverify deliberately rather than ignoring the change.

If external edits make both recovery and rollback conflict, inspect the prepared journal
and current notes. `recover ID --abandon` marks that operation abandoned without changing
any note. It preserves partial writes and records current hashes, then permits a new plan
based on fresh reads. This is explicit conflict settlement, not successful completion.
