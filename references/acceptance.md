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
10. Edit a note in Obsidian. In format 3, reconcile and inspect its retained observation,
    then explicitly adopt it before canonical recall. Legacy formats index the current edit.

## Host matrix (requires the actual applications)

For Codex desktop, Claude Desktop Chat via MCPB, and Cowork separately:
- Install the exact artifact, discover MCP tools and call doctor. Plugin skills alone do not pass.
- Choose or create vault; verify persistent config and scoped access.
- Save/read/search through the actual execution route.
- Start a fresh conversation outside the vault's working directory; repeat recall.
- Save in each host and read in each other host against the same vault.
- Restart the app; verify the binding and required tools still work.
- Check missing permissions produce a repair path, never an accidental second vault.

A disposable probe passed Codex desktop and Cowork transport. On 2026-10-24, installed
0.5.0 MCP tools passed registration, save/search/read and format compatibility checks
for two named folders in one Codex desktop conversation, including after their names
and physical paths changed. The physical moves and registry-path updates were a
separate authorized filesystem workflow, not a shipped relocation tool.
Fresh-conversation, restart, Claude and cross-app checks remain outstanding.
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


## 0.6.0 candidate release gates

The candidate is not published. No native two-Mac iCloud or cross-app proof is claimed.
Use separate disposable folder replicas with one shared vault identity, isolated configs,
ORBIT_CACHE and ORBIT_STATE outside the folders. Keep durable commits/observations.

| Scenario | Required evidence |
|---|---|
| Offline different-note saves | Both accepted versions survive, become readable after complete delivery, and agree across replicas. |
| Offline same-note saves | Both alternatives survive; identical conflict heads are reported; ordinary recall excludes the path. |
| Explicit resolution | History exposes alternatives and current physical hash; apply requires exact expected_heads and observations; a late branch reopens conflict. |
| Reordered/duplicate delivery | Markdown before history is retained without invented ancestry; duplicate operations have one effect. |
| Missing parents/assets or corrupted records | Pending/invalid states stay visible and block unsafe projection. |
| Crash/retry | Durable acceptance survives interrupted checkout; identical request_id retries return one logical operation; changed reuse refuses. |
| Editor change | Observed bytes are retained and explicitly adopted; no claim covers unobserved overwritten versions. |
| Path/identity conflict | Competing entities cannot overwrite one path; no deletion is inferred from absence alone. |
| Concurrent source integration | Branch evidence survives; the highest stage or latest arrival never silently wins. |
| Cache loss | SQLite rebuild preserves notes, durable revisions, observations and conflict state. |
| Migration | Exact format-2 bytes retained; seed precedes marker; preview, interruption, rerun and rollback work; later edits/history refuse recovery. |
| Old clients | Upgrade all writers first; prove refusal after the format-3 marker arrives; disclose that offline writers cannot be fenced. |

Run deterministic transport and subprocess tests before native acceptance. Then repeat
on two physical Macs using disposable iCloud folders and the actual installed Codex and
Claude processes. Exercise offline writes, reconnect, delayed availability, explicit
resolution and fresh-conversation persistence. Record exact candidate/artifact identity.
Zero silently discarded accepted revisions and agreement after complete delivery are
required; native upload latency is measured separately. A local committed receipt is
not a synchronized receipt. No daemon, automatic semantic merge or global transaction
is part of this acceptance contract.
