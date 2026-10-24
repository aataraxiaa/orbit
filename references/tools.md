# Tool access

Use the installed Orbit MCP tools. Their names are `orbit_setup`, `orbit_doctor`,
`orbit_search`, `orbit_read`, `orbit_context`, `orbit_apply`, `orbit_capture`,
`orbit_recover`, `orbit_index`, `orbit_catalog`, `orbit_relations`, `orbit_maintain`,
`orbit_integration`, `orbit_schema`, `orbit_migrate`, `orbit_list`, `orbit_rename`, and `orbit_format`. The host may prefix names with its MCP server namespace.
Discover the actual tools rather than guessing a callable name. Missing tools are
an installation/startup failure; never substitute shell execution and claim MCP works.

Each tool accepts a JSON object. Tool discovery provides explicit argument schemas.
Pass `plan` directly to `orbit_apply` and `record` directly to `orbit_integration`;
no temporary JSON files or shell quoting are needed. `orbit_read` uses `path`, `start`
and `count`. `orbit_search` uses `query`, optional `scope` and `limit`.

Every content-scoped tool accepts `orbit` or an absolute registered `vault`, never both.
Names are case-insensitive. An explicit path must match a registered path and identity.
With one entry, omission selects that Orbit; multiple entries require a selector.
Ambient vault variables do not choose an Orbit. Malformed or unsupported configuration
refuses every Orbit operation, including explicit paths.

`orbit_list` needs no selector and reports names, paths, stable IDs and availability.
Every successful Orbit operation returns `target` with `name`, `path`, `vault_id`
and `selection_source`. Check it before treating evidence or a save as belonging to
an Orbit. A registered identity is verified before each operation.

`orbit_setup` requires absolute `path` and `name`, with optional `create`.
Names contain 1 to 80 characters without surrounding whitespace or control characters.
Case collisions, name rebinding, duplicate IDs and overlapping roots refuse.
Registration is atomic and preserves initialized Orbit files and unknown config fields.
Config schema 2 stores `orbits: {name: {path, vault_id}}`; there is no global active selection.
`ORBIT_CONFIG` selects config at process launch. See [setup](setup.md) for installation.

`orbit_rename` requires the current `orbit` name and new `name`. It atomically changes
only the registry name and preserves the folder, identity and unknown config fields.
It refuses a name owned by another Orbit. Case-only changes are allowed; repeating the
current name leaves config unchanged. The old name stops resolving after a rename.
Neither registration nor rename creates a shared active selection.

A workflow hook targets its destination explicitly, for example `orbit: "Work"` on
its `orbit_apply` call and on the search/read calls used to prepare and verify it.
The hook does not depend on another conversation's choice.

The optional `scripts/orbit.py` CLI remains available for engineering and recovery.
It is not the desktop skill's execution route or evidence of a working MCP connection.

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

No automatic deletion, note-file renaming, arbitrary command execution or web fetching. Capture
only copies a user-selected file; it neither extracts nor integrates it.

## Search and read

Search inventories current Markdown on every call, including manual edits. It ranks
indexed passages with BM25 plus title/alias weighting and includes historical notes.
It does NOT compute embeddings. The skill supplies alternate wording and relationship
traversal. Do not describe results as semantic search or claim exhaustive recall.
Search results are leads: read evidence, expanding line windows as needed. Context
returns incoming and outgoing link neighbors with bounded depth, not their full text.

## Recovery

`doctor` lists pending journal ids. `orbit_recover` with `operation: ID` completes a prepared operation;
`orbit_recover` with `operation: ID, rollback: true` restores its before-state. Both refuse subsequent user edits.
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

Call `orbit_index` with `rebuild: true` to rebuild the cache. Use `orbit_catalog`
with `limit`, `offset` and optional `scope` for pagination. `orbit_relations` accepts
an optional `target`. `orbit_maintain` accepts a bounded `limit`. `orbit_integration`
without `record` lists processing records; pass the update object below to advance one.


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
text in a source note using apply. Then submit a `record` object to `orbit_integration` using the following shape.
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
and current notes. `orbit_recover` with `operation: ID, abandon: true` marks that operation abandoned without changing
any note. It preserves partial writes and records current hashes, then permits a new plan
based on fresh reads. This is explicit conflict settlement, not successful completion.

## Schemas and typed retrieval

Search and catalog accept optional `note_type` and `status` strings. Filters apply
before result limits. Example: `{"query":"rollout","note_type":"session","scope":"atlas"}`.
Results include type, observed date, schema version and current content hash.
Default catalog/search exclude schemas and vault rules; select `note_type: "schema"`
explicitly. A scoped or typed search never falls back to unfiltered results.

`orbit_schema` accepts optional `note_type`. It returns effective definitions and
findings. Definitions come from bundled templates overridden by Schemas/*.md.
`orbit_apply` returns schema warnings; strict findings refuse the entire proposed
batch. The common identity, metadata preservation and link checks remain errors.

## Versioned migration

`orbit_doctor` includes migration data_format, source_version, target_version and
pending operation IDs. A legacy marker without a release reports unknown.

`orbit_migrate` accepts `action` (plan, apply, resume, rollback), optional
`target_version`, `plan_id`, and `operation`. The installed target is 0.5.0.

- Plan is the default and writes nothing. It returns proposed moves, warnings,
  changes, source/target formats and a plan_id bound to the current inputs.
- Apply requires the preview plan_id and recomputes under the writer lock. The
  journal contains exact before-images and backup hashes before any file changes.
- Resume requires an operation ID and continues its recorded direction.
- Rollback requires an operation ID and restores before-images, including a
  previously committed migration if affected files still match recorded states.

Recovery preflights all affected files and refuses subsequent edits. The marker
is written last. Prepared migrations block normal writes and coherent graph/search
reads. Explicit note reads remain available for inspection. Source assets are never
rewritten. Affected integration receipts preserve historical paths/hashes and flag
verification as stale. Rebuild SQLite after commit or rollback. Exact backups live
in the returned migration journal path and must be protected like private notes.

See the single [migration skill](../skills/orbit-migrate/SKILL.md) for supported routes.

## Format existing notes

`orbit_format` accepts `plan: {changes: [{path, expected_sha256, metadata}]}` and
`dry_run`, which defaults to true. Select the named `orbit` on every call.
A batch contains 1 to 50 existing public Markdown notes. `metadata` accepts only
`title`, `type` and `summary`. Supply values supported by the note, only where
absent. Existing populated fields must match if supplied. Missing IDs use UUID5
from the Orbit identity and relative path; existing IDs remain stable.

The tool inserts new fields at the start of frontmatter and preserves existing
bytes, including BOM, body, unknown metadata blocks and line endings. It refuses
malformed or unclosed frontmatter, duplicate keys, unsupported required values,
unsafe paths and hash conflicts. This is a conservative parser, not general YAML
support. Formatting creates no notes, folders, moves, relationships or format upgrades.
The shared write engine may create internal lock and journal directories.

The receipt includes `formatted` entries with exact `added` values and
`before_sha256`, `after_sha256`, and `body_sha256`, alongside `changes`, `warnings`
and `target`. Existing link findings are returned with `preserved:true`; new
findings, duplicate IDs and strict schema errors block the operation. Ordinary
`orbit_apply` retains its existing validation and exposes no bypass.

Set `dry_run:false` to apply an authorized preview. Prepared interruptions use
`orbit_recover` for resume or rollback, which refuses subsequent human edits.
Developer CLI equivalent: `format PLAN.json` previews; `format PLAN.json --apply`
writes. Use installed MCP tools for desktop acceptance.
