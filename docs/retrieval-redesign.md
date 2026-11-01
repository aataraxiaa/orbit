# Agent-first retrieval experiment

This is a shared OrbitCore experiment, not a production storage cutover. It tests
whether retained, verified evidence can answer queries without source-folder I/O.
The app and MCP adapter do not call the new API. No phone, host, cloud or model
acceptance is established by these results. The shipping runtime and app pin are
unchanged.

## Proposed latency budget

Useful warm excerpts should normally arrive within 300 ms, with p95 within one
second, on the supported physical device and a realistic corpus. These are
provisional targets, not approved SLOs. Cold launch with an existing index,
first-ever import, model loading, explanation and cloud delivery need separate
measurements. Empty errors and irrelevant or stale evidence cannot satisfy the
target by arriving sooner.

## Current work before an excerpt

The app's `ModelTools.execute` calls `readySession`, `prepareForAccess` and
`LinkedFolderAccess.hydrate` before each search or read. Hydration enumerates
Markdown and revision JSON again. `LinkedFolderAccess.perform` executes the
synchronous engine on one actor shared by all linked Orbits. Background refresh
can therefore queue ahead of work for a different selected Orbit.

In core, `search` enters `coherent`, which reconciles revisions. Reconciliation
folds history twice. Retrieval inventory calls inspection, which folds it again.
The index refresh walks source paths, and winning sources undergo hash reads.
The native adapter adds containment checks, availability checks and coordination.
The source and fixture counters establish repeated work. They do not attribute
the reported physical-phone delay between iCloud waiting and local computation.

Apple documents that metadata can arrive before file content, and coordinated
reads can block while content downloads. Folder access and directory visibility
therefore do not establish resident bytes. See Apple's
[iCloud document guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html).

## Candidate and evidence contract

`captureRetrievalSnapshot` explicitly performs expensive source work. It retains
exact Markdown bytes, stable note IDs, source hashes, revision heads and a captured
inventory. A final inventory and revision check refuses changed evidence. For
format 3, every included source hash must match its immutable revision content.
Conflicted sources are excluded, with partial coverage and excluded paths retained.
Unavailable bytes fail capture rather than becoming deletion. Format 2 has hashes
without invented revision heads.

`OrbitRetrievalSnapshot.retrieve` operates on an immutable in-memory passage index.
The result identifies the Orbit, snapshot and capture time, and explicitly reports
`snapshot-not-current-provider`. Reopening validates the expected Orbit identity
and retained byte hashes. A failed capture leaves the previously published archive
usable. This does not prove upload, current peer coverage or write authority.

Note titles and aliases discover candidates. Passage ranking uses substantive body
and section terms. Heading-only sections cannot displace actual advice. Common
question verbs do not become relevance signals. Returned evidence includes exact
line numbers and a passage-completeness flag. The serialized UTF-8 byte budget is
separate from model-token limits. A host still needs its real tokenizer before
requesting a local explanation.

The archive is a bounded experimental projection, with at most 64 MiB of source
bytes. It rebuilds its in-memory index on reopen. It is not an incremental index,
a two-way replica, an authenticated archive, or a durable save queue. Both capture
cost and index memory need broader workloads before adoption. No database belongs
inside the synced folder as a substitute for a sync protocol.

## Matched local-folder experiment

The Release suite ran through MobileBuildMCP on an iPhone 18 Pro simulator with
iOS 27.0. The Mac had 12 logical CPUs and load averages near 2.8 before the run.
The corpus has 503 generated format-3 notes and one genesis envelope. Each of five
process runs alternates 25 direct queries with 25 snapshot queries. Both paths must
return the expected practical advice, source hash and lines. No samples failed.
The query is `practice public speaking`. These are core operations with different
freshness guarantees, not equivalent end-to-end assistant requests.

| Stage | Samples | p50 | p95 | Range |
| --- | ---: | ---: | ---: | ---: |
| Direct warm search | 125 | 1,274.83 ms | 1,359.71 ms | 1,189.18–1,710.71 ms |
| Snapshot warm evidence | 125 | 0.094 ms | 0.142 ms | 0.064–1.126 ms |
| Snapshot capture | 5 | 2,102.08 ms | 2,275.83 ms | 2,025.45–2,275.83 ms |
| Snapshot reopen and index construction | 5 | 147.12 ms | 169.24 ms | 145.93–169.24 ms |

Every direct warm query makes 3,035 source reads and 26,841 source inspections.
Snapshot queries make zero source accesses. This proves the candidate removes
source work from query admission. It does not prove an equivalent-freshness speedup
or select a storage architecture. The archive is about 634 KB. Peak RSS in the raw
report covers the whole test process, including fixture creation and direct search;
it cannot establish the snapshot's memory cost.

The raw `direct-cold` stage means first indexing in a fresh fixture, not cold app
launch with an existing index. Quantiles use nearest-rank p95. Repeated samples
inside a process are not independent process runs. The synthetic queries do not
establish general paraphrase recall. See the [complete samples](retrieval-snapshot-results.json).

## Architecture comparison and decision gate

| Candidate | Query and save behavior | Unresolved work |
| --- | --- | --- |
| Direct Drive plus persistent passage index and snapshots | Retained snapshots can serve evidence offline; current provider writes keep their existing limits | Incremental freshness, per-Orbit scheduling, provider-eviction matrix and source availability |
| App-managed local replica with Drive delivery | Resident queries and locally durable saves can be independent of cloud delivery | Durable outbox, dependency delivery, external observations, concurrent edits, tombstones, restart and suspension |
| Local database plus CloudKit records | Local transactions can precede background record delivery | Signed MCP access, entitlements, container provisioning, Markdown bridge and migration |
| Revised immutable history with checkpoints and materialized Markdown | Can reduce history-fold cost while retaining note interchange | Checkpoint validation, missing dependencies, conflict retention and rollback |

The local-replica option deserves the next prototype because it directly addresses
provider-dependent admission. The present experiment does not choose it. The
[Core Data and CloudKit approach](https://developer.apple.com/documentation/coredata/syncing-a-core-data-store-with-cloudkit)
is distinct from Drive document synchronization. Its signed native integration
and external Markdown behavior remain unevaluated here.

A replica must accept the exact approved operation into durable local history and
a recoverable outbox before reporting local acceptance. Delivery must preserve
dependencies and retries. Cloud delivery and verified peer visibility remain
separate states. An unavailable cloud file cannot create a tombstone. External
Markdown edits become observations with their original bytes, not inferred
ancestry. Concurrent accepted histories retain both branches until reviewed.
Queries read a published immutable snapshot while background work builds its
replacement. Synchronization uses one writer per Orbit; unrelated Orbits do not
share a blocking operation queue.

Before selecting a design, repeat identical workloads on a plain local folder,
resident Drive files, pending or evicted Drive files, and an offline local replica.
Include existing-index cold launch, first import, deep history, multiple Orbits,
background refresh, external edits, delayed dependencies, conflicts, restart and
suspension. Trace actor queue wait, hydration, availability, coordinator wait,
byte I/O, reconciliation, indexing, ranking, evidence delivery and real model
processing under one request ID. Matched Swift and Python runs need the same bytes,
format and guarantees. Language causation remains unproved.

## Compatibility and acceptance

This change does not modify disk format 3, the public MCP contract, registry,
canonical Markdown or revision protocol. No Orbit-data migration is necessary.
The existing migration skill and frozen interruption, rerun and rollback fixtures
remain the compatibility gate. The experimental archive has its own schema 1;
it can be discarded and rebuilt without restoring or deleting accepted history.
No real Orbit was migrated.

MobileBuildMCP passes 131 Swift tests, with two opt-in measurements skipped in the
normal suite. The Release simulator passes all 10 snapshot tests, including the
measurement. Tests cover advice passages, aliases, section headings, fenced text,
long notes, ambiguity, scope, pinned reads, no hits, exact lines, conflicts, source
changes, identity, restart, failed refresh and corruption. All 193 reference tests,
the isolated smoke workflow, 24 differential cases, 157 mixed-replica steps and
package rebuild pass. Packaging consumes the
existing committed runtime; it does not install this experiment into either host.

Production integration, incremental updates, durable offline saves, two-way
replication, actual provider states, physical test-device behavior and grounded
model explanations remain open. The personal iPhone is excluded from automated
testing. No release, merge, app-pin change or desktop-support claim is part of this
experiment.
