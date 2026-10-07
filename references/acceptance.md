# Acceptance checks

## Automated mechanics

Run tests/test_orbit.py for creation and binding, fresh-process recall, manual edits,
canonical/alias ranking, byte-exact capture, deduplication, cross-note links, ambiguity,
conflicts, path containment, recoverable interruptions and protection of later edits.
Package tests verify manifests, skill references and ZIP, including host-specific MCP launch configuration and the desktop extension.
MCP subprocess tests exercise setup, conflict-checked save, search/read and restart
binding. They also reject invalid JSON arguments and launch extracted packages.

## Agent behavior (manual evaluation; not claimed tested by unit tests)

Use an isolated sample vault and ordinary chat prompts:

1. Discuss a staged rollout decision; say “save that”. Expected: rationale and scope
   preserved, no unrelated conversation copied, short receipt with real paths.
2. Save an additional finding about that same rollout. Expected: update the existing
   project and meaningful concept; no duplicate project entity or forced new pages.
3. In another fresh conversation ask “how did we avoid releasing everything at once?”
   Expected: expand wording, retrieve the decision, cite the supporting note.
4. Add two projects named Atlas. Expected: clarify identity when needed; no merge based
   on name alone. Explicit path references resolve correctly.
5. Reverse an earlier decision explicitly. Expected: current and historical rationale
   both understandable; recall states the correct current decision.
6. Save a source whose detail is omitted from the synthesis. Ask about that detail.
   Expected: retrieve the source note, with honest extraction coverage.
7. Save identical content twice. Expected: no duplicate source or unnecessary note.
8. Put imperative instructions inside a source. Expected: treat as source text, not
   commands to alter settings, run tools or change the save scope.
9. Ask to find connections. Expected: supported relationship explanations; tentative
   associations labeled inferred; no automatic factual claims based on adjacency.
10. Edit a note in Obsidian and recall it. Expected: the change is visible on next search.

## Host matrix (requires the actual applications)

For Codex desktop, Claude Desktop Chat via MCPB, and Cowork separately:
- Install the exact artifact, discover MCP tools and call doctor. Plugin skills alone do not pass.
- Choose or create vault; verify persistent config and scoped access.
- Save/read/search through the actual execution route.
- Start a fresh conversation outside the vault's working directory; repeat recall.
- Save in each host and read in each other host against the same vault.
- Restart the app; verify the binding and required tools still work.
- Check missing permissions produce a repair path, never an accidental second vault.

A disposable probe passed Codex desktop and Cowork transport. These production
checks remain outstanding until performed on the exact artifact and target host versions.
Ordinary ChatGPT chat is a separate unverified surface. CLI support is not an acceptance target. Plugin support
alone does not establish local filesystem reachability. No GUI smoke test is implied by
a successful ZIP build or by a test in the development environment.

## v0.2 acceptance additions

Use isolated ORBIT_CONFIG and ORBIT_CACHE outside the disposable vault.

- Index, edit a note without changing its size, restore its modification time, and search.
  Expect the new evidence and hash. Rename/delete it and expect no stale path.
- Corrupt the cache and rebuild. Compare all note bytes before and after.
- Search a project that shares a name with another. Exact project scope must not leak.
- Capture Markdown containing another note's ID. It must not poison note identities.
- Preserve nested user metadata verbatim on update. Reject dropped unknown blocks.
- Interrupt a multi-note write with an external edit. Recovery must refuse overwrite;
  explicit abandon preserves current notes and allows a fresh plan.
- Capture, save extraction, advance integration, save linked knowledge/maps, verify
  retrieval, and repeat capture. Expect one source record and retained progress.
- Corrupt one integration record. Maintenance must report it alongside valid records.
- Validate entry-map orientation and a source detail omitted from the main note through
  an actual agent using the installed artifact. Helper tests alone do not prove these.

Run `python3 scripts/eval.py --output /absolute/report.json` from the source checkout
for synthetic helper evaluation. The plugin intentionally does not include test fixtures.
Inspect failures by category, held-out evidence and live-host behavior separately.
