# Retrieval performance and capability boundaries

OrbitCore owns note retrieval for the mobile app and native desktop plugin.
Markdown and format-3 history remain authoritative. SQLite remains a rebuildable,
device-local index outside the synced folder. This change keeps the public command
contract, disk format and cache schema unchanged. Existing folders need no migration.

## Design choice

Two designs were compared: strict retrieval with bounded evidence, and a
request-owned retrieval snapshot that could later return one verified evidence
bundle. Strict retrieval is the implementation base. It removes repeated computation
without changing when Orbit checks current files, conflicts or provider access.

The snapshot design contributed the future direction for compact mobile evidence.
A public snapshot API is deferred because it would change freshness semantics and
require coordinated citation handling in the app. Background indexes may prewarm
work, but file events and time-based cache expiry cannot establish current evidence.

Callers keep the same interface:

```swift
let candidates = try engine.search(root, query: "rollback", limit: 8, scope: "Projects/Orbit.md")
let evidence = try engine.read(root, path: "Decisions/Rollout.md", start: 1, count: 160)
```

The inference host chooses the evidence it needs. Search excerpts do not grant
complete-read coverage or permission to write.

## Current retrieval path

`EngineOperations.swift` reconciles format-3 revisions under the local vault lock.
`Retrieval.swift` inventories eligible Markdown, updates changed index entries and
ranks matching passages. It then checks selected notes against their current bytes
before returning line-numbered excerpts. Repeatedly changing evidence still refuses.

The implementation retains that sequence and its refusal behavior. It changes the
following computations:

- `Primitives.swift` keeps up to 128 compiled regular expressions in `NSCache`.
  Cache entries depend only on pattern and options. Filesystem state is never cached.
- `Replication.swift` indexes writes by path during envelope validation and known
  content by path during unfamiliar-content checks. These local dictionaries replace
  scans across unrelated versions and writes. Byte-exact content comparisons remain.
- Commit and observation decoding consumes the bytes already checked against the
  size limit. It no longer reads each file again merely to decode JSON.
- SQL materializes BM25 matches before applying a window function. It selects the
  best passage per note, computes the exact note total and limits returned rows.
  A long note cannot consume every result slot through repeated matching passages.
- SQLite calls the existing Swift casefold behavior for exact titles and aliases.
  A Swift path collation preserves existing tie order. Exact-name promotion happens
  before the result limit, including Unicode names and escaped query strings.
- Excerpt packing adds each serialized entry's contribution to the pretty-JSON
  envelope. It preserves the Unicode-scalar character cap and line boundaries
  without repeatedly serializing every previously accepted line.

A prototype that memoized decoded history within a request was removed because it
did not show a clear benefit. The accepted design retains no parsed-history cache.
Replication identity, path containment, asset bytes, ancestry and conflicts remain
subject to their existing checks on each operation.

## Mobile and desktop capabilities

Both platforms share scope enforcement, revision eligibility, current-byte checks
and citation provenance. Additional search methods must enter before these checks;
they cannot turn an unverified candidate into evidence.

Mobile uses immediate lexical retrieval with bounded excerpts. The inference host
owns the selected model's tokenizer and the complete prompt budget, including
instructions, tool schemas, conversation history and evidence. The core's character
cap is a payload limit, not proof that a prompt fits a model's context window.

Desktop may later add local semantic candidates and combine them with lexical
matches. Such candidates must retain note identity, scope and source hash, then
pass the same evidence validation. Embeddings, vector storage and semantic ranking
are not shipped by this change. No vault restructuring is required for that option.

The initial app trace found further complete reads after an agent read and growing
tool transcripts. The app iteration separately changed library refresh to use
catalog metadata. The focused mobile changes described below were tested in an
isolated copy, then applied only after the original source hashes still matched.
Dependency pins and unrelated work remain unchanged. Simulator measurements do not
execute a local model or establish physical-phone inference, model answer quality,
iCloud latency or desktop-host acceptance.

## Mobile model evidence

The native core appends a full synchronization report after the search excerpt cap.
That report contains revision heads for every note. Passing it unchanged through
mobile tools repeatedly feeds unrelated history into subsequent model prompts.
This can consume the host's 64 KB tool-payload and 96 KB transcript guards without
adding evidence for the answer.

The app now compacts only the model-facing envelope, after validating sources and
recording model-visible line coverage. It retains note paths, hashes, requested
lines, selected-note heads, citation keys and approved complete raw content.
The summary retains exact synchronization status and diagnostic counts, with
explicit incomplete or unknown availability. It omits unrelated heads and local
cache paths. Missing diagnostics never imply ready status. Native MCP results and
full host validation remain unchanged.

Display and model reads now use one core read operation followed by a full raw-file
hash confirmation. They no longer fetch successive 500-line windows solely to
reconfirm the same bytes. The host still performs two raw reads, including the
core read. Only the requested window contributes to model-visible write coverage;
loading complete display bytes does not authorize a model rewrite.

An unavailable or incomplete zero-match search now refuses rather than becoming
the assistant's hardcoded absence response. A selected Orbit with incomplete
coverage conservatively stops a zero-match multi-Orbit request; aggregating useful
partial results is future work. Large complete `raw_content` remains subject to
the existing payload limit.

The synthetic 500-head test reduces a canonical model envelope from 50,963 bytes
to 580 bytes while retaining its read proof exactly. This measures serialized input
size, not tokens, inference throughput or answer latency.

## Repeatable measurements

The development generator creates an isolated XCTest project from checked-in tests.
It requires `xcodegen` and does not build or run Apple code itself:

```sh
python3 scripts/retrieval_benchmark_project.py --output work/retrieval-performance/checks --notes 500 --format 3
```

Use MobileBuildMCP `session_show_defaults`, then `session_set_defaults` with the
printed project path, scheme `OrbitRetrievalChecks` and configuration `Release`.
Select an available simulator through `list_sims` and set its `simulatorId`.
Run `test_sim` with `extraArgs` containing `ENABLE_TESTABILITY=YES` and
`CODE_SIGNING_ALLOWED=NO`. The first setting must also apply to the package build.

The generated scheme enables `ORBIT_BENCHMARK=1`. The test creates disposable notes
and isolated config, cache and state directories, then removes its own fixture.
It times cold search, warm search, no-match search, a single-result search,
reconciliation, inventory and refresh. Fixture setup stays outside timed regions.
`ORBIT_PERF` lines report durations and evidence digests. Assertions check totals,
returned source hashes, nonempty evidence and zero reparsing on unchanged notes.

Use `--format 2` to separate lexical/index work from format-3 reconciliation.
Use `--package-path` to measure an older checkout with the same test sources.
Alternate baseline and candidate Release runs on the same simulator and record
note count, format, host load, result failures, median and range. Inspect complete
public-search latency alongside helper costs before attributing user-visible gains.

Save each MobileBuildMCP result as an entry with `side` and `repeat` in a JSON array.
`scripts/retrieval_benchmark_report.py --runs RUNS.json --output SUMMARY.json` verifies
five alternating pairs, five warm samples per run, successful results and identical
evidence fingerprints. It keeps every timing and rejects incomplete comparisons.

## Simulator results, 1 November 2026

Release builds ran on an iPhone 18 Pro simulator, iOS 27.0, hosted by an Apple M6
Mac with 12 logical CPUs and 24 GiB memory. The baseline source is
`0e7cacecde616aab9d31da0e1c8afa436310bd69`. Each side has five alternating process
runs and 25 warm public `engine.search` calls. No samples were discarded.

| Generated workload | Baseline median, range | Candidate median, range |
| --- | --- | --- |
| 5,000 notes, 65,000 passages, format 2 | 461 ms, 410 to 563 ms | 251 ms, 219 to 272 ms |
| 500 notes, 6,500 passages, format 3, one genesis envelope | 2,340 ms, 2,128 to 3,433 ms | 1,523 ms, 1,388 to 4,775 ms |

The format-2 workload is faster across the observed ranges. Format-3 medians are
lower, but one candidate batch had large spikes. Its tail-latency improvement is
inconclusive. The Mac also ran background media analysis; alternating runs reduce
drift but do not establish a controlled physical-phone result.

Every before/after evidence fingerprint matches within its workload. Hashes cover
result order, scores, source hashes, excerpts, totals and coverage. The benchmark
also checks source hashes against the generated notes. There were no test failures.
Raw samples, batch medians, fingerprints and log names are retained in
[format-2 results](retrieval-summary-5000-format2.json) and
[format-3 results](retrieval-summary-format3.json).

Separate two-second CPU samples identified repeated metadata regex compilation and
revision validation in the baseline. After the changes, current path validation
and filesystem scanning remain prominent. Reconciliation, inventory and refresh
timings confirm that history checks dominate format-3 search, including no-match
queries. SQLite still evaluates matching passages to rank and count them; the
change bounds rows transferred into Swift, not the number of matches evaluated.

The format-3 fixture has one large genesis envelope. It does not establish behavior
for thousands of historical operations, provider-backed folders or concurrent
writers. These results exclude model loading, prompt processing, generation and
the app's duplicated reads. No end-to-end assistant speedup is claimed.

The next assistant measurement must use a disposable folder on a physical device
and time the complete request, each tool call, prompt processing and generation.
The mobile changes remove redundant native read operations and unrelated prompt
metadata, but serial model navigation remains. Desktop semantic candidates can
share the same provenance boundary after a labeled relevance evaluation
demonstrates improved recall.

The actual mobile adapter was measured separately with the same candidate core on
both sides: 51 generated format-3 notes and a note with 1,200 body lines. Five
alternating process runs provide 25 reads per side. Median complete-read latency
falls from 5,227 ms to 1,704 ms. Observed ranges are 4,969 to 8,405 ms and 1,606 to
2,096 ms. Every read returns the same exact content hash and full host coverage.
This isolates the removed repeated core operations; it is not an assistant-answer
benchmark. [All adapter samples](retrieval-summary-mobile-read.json) are retained.

The isolated app suite passes 102 tests with the local candidate core, including
the isolated adapter measurement. The main app suite passes 101 tests against its
unchanged pinned core, without that benchmark-only test. Its existing pin remains
`5a4d5835b648a369ffac127f47623c0fa312f355`, so adopting the separate core speedups
remains an integration step for the app iteration session.

## Correctness evidence

`RetrievalRankingTests` covers title and alias promotion, Unicode behavior, tied
paths, duplicate passages, filters, exact totals, payload caps, current line evidence,
external edits, deletion, corruption recovery and conflict exclusion.
`ReplicationFreshnessTests` exercises unchanged-size and unchanged-mtime mutations,
identity changes, symlink replacement, unavailable reads, cancellation and asset
changes within one local lock. Passing these mechanical checks establishes only
their covered cases. Native-host and real-model acceptance remain separate work.
