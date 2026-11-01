import Foundation
import XCTest

@testable import OrbitCore

final class RetrievalSnapshotTests: XCTestCase {
  private var base: URL!
  private var root: URL!
  private var engine: OrbitEngine!
  private var access: CountingSnapshotAccess!

  override func setUpWithError() throws {
    base = realURL(FileManager.default.temporaryDirectory).appendingPathComponent("orbit-snapshot-" + UUID().uuidString)
    root = base.appendingPathComponent("vault")
    access = CountingSnapshotAccess(root: root)
    engine = OrbitEngine(configURL: base.appendingPathComponent("config.json"),
      cacheURL: base.appendingPathComponent("cache"), stateURL: base.appendingPathComponent("state"),
      fileAccess: access)
    try atomic(root.appendingPathComponent(".orbit/vault.json"), encode([
      "schema": 1, "id": UUID().uuidString.lowercased(), "data_format": 3, "orbit_version": "0.6.0",
    ]))
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }

  private func seed(includeGenesis: Bool = true) throws -> [String: String] {
    let files = [
      "Knowledge/Speaking.md": "---\nid: speaking\ntitle: Public speaking\nproject: Work\ncustom:\n  retain: verbatim\n---\n# Public speaking\n\n## Practical tips\nPractice your opening aloud. Pause between ideas.\n\n## Confidence\nConfidence grows with experience.\n",
      "Knowledge/Decoy.md": "# Canning\n\nYou can can can can can can can can.\n",
      "Personal/Garden.md": "# Gardening\n\nPlant rosemary in a sunny border.\n",
    ]
    for (path, text) in files { try atomic(root.appendingPathComponent(path), Data(text.utf8)) }
    if includeGenesis { _ = try engine.replicationSeed(root, files: files) }
    return files
  }
  private func verify(_ result: OrbitRetrievalSnapshot.Result, files: [String: String]) throws {
    XCTAssertEqual(result.freshness, "snapshot-not-current-provider")
    for evidence in result.evidence {
      let text = try XCTUnwrap(files[evidence.path])
      XCTAssertEqual(evidence.sha256, digest(Data(text.utf8)))
      XCTAssertFalse(evidence.heads.isEmpty)
      for line in evidence.lines { XCTAssertEqual(line.text, eLines(text)[line.number - 1]) }
    }
  }

  func testQuestionReturnsPracticalPassageWithoutProviderAccess() throws {
    let files = try seed()
    let snapshot = try engine.captureRetrievalSnapshot(root)
    access.reset()
    access.deny = true
    let result = try snapshot.retrieve(query: "How can I practice public speaking?")
    XCTAssertEqual(result.evidence.first?.path, "Knowledge/Speaking.md")
    XCTAssertTrue(result.evidence.first?.lines.contains { $0.text.contains("Pause between ideas") } == true)
    XCTAssertEqual(result.capturedCoverage, "complete")
    XCTAssertEqual(access.calls, 0)
    try verify(result, files: files)
  }

  func testPersistedSnapshotSurvivesUnavailableSourceRestartAndFailedRefresh() throws {
    let files = try seed()
    let snapshot = try engine.captureRetrievalSnapshot(root)
    let url = base.appendingPathComponent("snapshot.json")
    try snapshot.write(to: url)
    let original = try Data(contentsOf: url)
    access.deny = true
    XCTAssertThrowsError(try engine.captureRetrievalSnapshot(root))
    XCTAssertEqual(try Data(contentsOf: url), original)
    try FileManager.default.removeItem(at: root)
    access.reset()
    let reopened = try OrbitRetrievalSnapshot(contentsOf: url, expectedOrbitID: snapshot.orbitID)
    let result = try reopened.retrieve(query: "rosemary")
    XCTAssertEqual(result.evidence.first?.path, "Personal/Garden.md")
    XCTAssertEqual(access.calls, 0)
    XCTAssertEqual(reopened.snapshotID, snapshot.snapshotID)
    try verify(result, files: files)
    XCTAssertThrowsError(try OrbitRetrievalSnapshot(contentsOf: url, expectedOrbitID: UUID().uuidString))
    var archive = try JSONDecoder().decode(OrbitRetrievalSnapshot.Archive.self, from: original)
    let corrupted = OrbitRetrievalSnapshot.Document(path: archive.documents[0].path,
      bytes: Data("tampered".utf8), sha256: archive.documents[0].sha256, heads: archive.documents[0].heads)
    var documents = archive.documents
    documents[0] = corrupted
    archive = .init(schema: archive.schema, orbitID: archive.orbitID, snapshotID: archive.snapshotID,
      capturedAt: archive.capturedAt, coverage: archive.coverage, excludedPaths: [], documents: documents)
    XCTAssertThrowsError(try OrbitRetrievalSnapshot(archive: archive))
  }

  func testScopePinnedNoHitAndByteBound() throws {
    _ = try seed()
    let snapshot = try engine.captureRetrievalSnapshot(root)
    XCTAssertTrue(try snapshot.retrieve(query: "rosemary", scope: "Work").evidence.isEmpty)
    XCTAssertEqual(try snapshot.retrieve(query: "practice", scope: "Work").evidence.first?.noteID, "speaking")
    XCTAssertTrue(try snapshot.retrieve(query: "unmatchedzz").evidence.isEmpty)
    XCTAssertTrue(try snapshot.retrieve(query: "can you please").evidence.isEmpty)
    let pinned = try snapshot.retrieve(query: "", path: "Personal/Garden.md")
    XCTAssertEqual(pinned.evidence.first?.path, "Personal/Garden.md")
    let result = try snapshot.retrieve(query: "practice", maximumBytes: 800)
    XCTAssertLessThanOrEqual(try JSONEncoder().encode(result).count, 800)
  }

  func testAliasesLongSectionsAndAmbiguityUseActualLines() throws {
    let filler = String(repeating: "Background discussion without the sought detail.\n", count: 250)
    let files = [
      "Knowledge/Long.md": "---\nid: long\ntitle: Presentation handbook\naliases: [\"Talk guide\"]\n---\n# Handbook\n\n## Background\n" + filler + "\n## Breathing\nBefore presenting, breathe slowly and pause.\n",
      "Knowledge/Other.md": "# Other\n\nBreathe slowly during swimming practice.\n",
    ]
    for (path, text) in files { try atomic(root.appendingPathComponent(path), Data(text.utf8)) }
    _ = try engine.replicationSeed(root, files: files)
    let snapshot = try engine.captureRetrievalSnapshot(root)
    let result = try snapshot.retrieve(query: "breathe before presenting")
    XCTAssertEqual(result.evidence.first?.path, "Knowledge/Long.md")
    XCTAssertTrue(result.evidence.first?.lines.contains { $0.text.contains("pause") } == true)
    XCTAssertEqual(try snapshot.retrieve(query: "Talk guide", limit: 1).evidence.first?.path, "Knowledge/Long.md")
    XCTAssertEqual(try snapshot.retrieve(query: "Breathing").evidence.first?.section, "Handbook / Breathing")
    XCTAssertEqual(try snapshot.retrieve(query: "breathe").totalMatchingNotes, 2)
    try verify(result, files: files)
  }

  func testCaptureRefusesChangingBytesRatherThanPublishingMixedEvidence() throws {
    _ = try seed()
    let marker = root.appendingPathComponent(".orbit/vault.json")
    var metadata = try readJSON(marker)
    metadata["data_format"] = 2
    try atomic(marker, encode(metadata))
    let initial = try engine.captureRetrievalSnapshot(root)
    let url = base.appendingPathComponent("snapshot.json")
    try initial.write(to: url)
    let original = try Data(contentsOf: url)
    let target = root.appendingPathComponent("Personal/Garden.md")
    access.afterRead = { touched in
      if touched.path == target.path {
        var bytes = try Data(contentsOf: target)
        bytes.append(Data("external edit\n".utf8))
        try bytes.write(to: target)
      }
    }
    XCTAssertThrowsError(try engine.captureRetrievalSnapshot(root))
    XCTAssertEqual(try Data(contentsOf: url), original)
  }

  func testStableExternalBytesCannotBorrowOldRevisionHeads() throws {
    let files = try seed()
    let sync = try engine.replicationReconcile(root)
    let path = "Personal/Garden.md"
    let bytes = Data((files[path]! + "New external advice.\n").utf8)
    let heads = sync["heads"] as? JSONObject ?? [:]
    let document = OrbitRetrievalSnapshot.Document(path: path, bytes: bytes,
      sha256: digest(bytes), heads: strings(heads[path]))
    XCTAssertThrowsError(try engine.validateRetrievalSnapshotRevisions(root,
      documents: [document], expected: sync)) { error in
      XCTAssertTrue(String(describing: error).contains("bytes do not match"), String(describing: error))
    }
    try bytes.write(to: root.appendingPathComponent(path))
    XCTAssertThrowsError(try engine.validateRetrievalSnapshotRevisions(root,
      documents: [document], expected: sync))
  }

  func testFencedHashLinesAndHashtagsRemainSearchable() throws {
    let text = "# Scripts\n\n```sh\n# criticalMarker\necho ready\n```\n\n#hashtagMarker\n"
    let path = "Knowledge/Code.md"
    try atomic(root.appendingPathComponent(path), Data(text.utf8))
    _ = try engine.replicationSeed(root, files: [path: text])
    let snapshot = try engine.captureRetrievalSnapshot(root)
    for query in ["criticalMarker", "hashtagMarker"] {
      XCTAssertEqual(try snapshot.retrieve(query: query).evidence.first?.path, path)
    }
  }

  func testOverviewUsesProjectFactsRatherThanNavigationAndPeople() throws {
    let files = [
      "Projects/Orchard/Overview.md": "---\nid: orchard\ntitle: Orchard rollout\ntype: project\n---\n# Orchard rollout\n\n## What it is\nDeliver pears to independent grocers.\n\n## Problems\nEarlier crates bruised fruit.\n\n## Transfer provenance\nTell me about Orchard rollout. Original Orchard rollout sources were copied intact.\n\n## Relations\n- [[Knowledge/Cold chain]]\n",
      "Knowledge/Status.md": "---\nid: status\ntitle: Orchard rollout project map\ntype: map\n---\n# Orchard rollout\n\n## Current status\nThe pilot remains limited to three shops.\n\n## Relations\n- [[Projects/Orchard/Overview|Orchard rollout]]\n",
      "Knowledge/People.md": "---\nid: people\ntitle: People - Orchard rollout\ntype: map\n---\n# People\n\nTell me about Orchard rollout. Contact names and identifiers.\n",
      "Knowledge/Cold chain.md": "---\nid: cold\ntitle: Cold chain\ntype: concept\n---\n# Cold chain\n\nA refrigerated handoff protects delicate cargo.\n",
    ]
    for (path, text) in files { try atomic(root.appendingPathComponent(path), Data(text.utf8)) }
    _ = try engine.replicationSeed(root, files: files)
    let result = try engine.captureRetrievalSnapshot(root).retrieve(query: "Tell me about Orchard rollout", limit: 3)
    XCTAssertEqual(result.evidence.first?.noteID, "orchard")
    XCTAssertTrue(result.evidence.first?.lines.contains { $0.text.contains("bruised fruit") } == true)
    XCTAssertTrue(result.evidence.contains { $0.noteID == "status" && $0.lines.contains { $0.text.contains("three shops") } })
    XCTAssertFalse(result.evidence.contains { $0.noteID == "people" })
    XCTAssertTrue(result.evidence.contains { $0.noteID == "cold" })
    XCTAssertFalse(result.evidence.flatMap(\.lines).contains { $0.text.contains("Original Orchard") })
    XCTAssertFalse(result.evidence.flatMap(\.lines).contains { $0.text == "## Relations" })
    XCTAssertFalse(result.evidence.first?.passageComplete ?? true)
    try verify(result, files: files)
  }

  func testOverviewIncludesDatedDecisionAndLatestQualifiedStatus() throws {
    let files = [
      "Projects/Orchard.md": "---\nid: orchard\ntitle: Orchard rollout\ntype: project\nproject: Orchard rollout\n---\n# Orchard rollout\n\n## What it is\nDeliver pears to grocers.\n\n## Problems\nCrates bruise fruit.\n\n## Relations\n- [[Knowledge/Tracker]]\n- [[Knowledge/Updates]]\n- [[Knowledge/Old questions]]\n",
      "Knowledge/Tracker.md": "---\nid: tracker\ntitle: Orchard rollout project map\ntype: note\nproject: Orchard rollout\nsummary: Current status and decisions\n---\n# Orchard rollout\n\n## Status 2026-09-01\nThe redesign was planned.\n\n## Decisions 2026-10-14\n- [decision] The redesign is parked; use padded crates instead.\n\n## Status 2026-10-16\nThe pilot remains limited to three shops.\n",
      "Knowledge/Updates.md": "---\nid: updates\ntitle: Orchard rollout updates\ntype: reference\nproject: Orchard rollout\n---\n# Orchard rollout\n\n## Changes 2026-10-23\nCrate testing completed. Expansion is pending.\nThe shared plan was not updated; this is saved status, not live delivery.\n",
      "Knowledge/Old questions.md": "---\nid: old\ntitle: Orchard rollout open questions\nproject: Orchard rollout\nstatus: historical\n---\n# Orchard rollout\n\n## Current status\nOrchard rollout orchard rollout orchard rollout is waiting for the redesign.\n",
    ]
    for (path, text) in files { try atomic(root.appendingPathComponent(path), Data(text.utf8)) }
    _ = try engine.replicationSeed(root, files: files)
    let snapshot = try engine.captureRetrievalSnapshot(root)
    access.reset()
    access.deny = true
    let result = try snapshot.retrieve(query: "Tell me about Orchard rollout", limit: 3, maximumBytes: 6000)
    let text = result.evidence.flatMap(\.lines).map(\.text).joined(separator: "\n")
    XCTAssertTrue(text.contains("Deliver pears"))
    XCTAssertTrue(text.contains("Crates bruise"))
    XCTAssertTrue(text.contains("redesign is parked"))
    XCTAssertTrue(text.contains("2026-10-23"))
    XCTAssertTrue(text.contains("Expansion is pending"))
    XCTAssertTrue(text.contains("not live delivery"))
    XCTAssertFalse(result.evidence.contains { $0.noteID == "old" })
    XCTAssertLessThanOrEqual(try JSONEncoder().encode(result).count, 6000)
    XCTAssertEqual(access.calls, 0)
    try verify(result, files: files)
  }

  func testOverviewBudgetCannotReturnHeadingsWithoutFacts() throws {
    let text = "---\ntitle: Orchard overview\ntype: project\n---\n# Orchard overview\n\n## Problems\n" + String(repeating: "Long claim about pears. ", count: 500) + "\n\n## Status\n" + String(repeating: "Long claim about crates. ", count: 500) + "\n"
    try atomic(root.appendingPathComponent("Projects/Orchard.md"), Data(text.utf8))
    _ = try engine.replicationSeed(root, files: ["Projects/Orchard.md": text])
    let result = try engine.captureRetrievalSnapshot(root).retrieve(query: "Tell me about Orchard overview", limit: 1, maximumBytes: 900)
    XCTAssertTrue(result.evidence.isEmpty)
    XCTAssertTrue(result.truncated)
  }

  func testScopedOverviewDatesIgnoreExcludedLinkedSources() throws {
    let source: [String: String] = [
      "Allowed/Orchard.md": "---\ntitle: Orchard rollout\ntype: project\n---\n# Orchard overview\n\n## Purpose\nDeliver pears.\n\n## Links\n- [[Allowed/Status]]\n- [[Elsewhere/Updates]]\n",
      "Allowed/Status.md": "---\ntitle: Orchard rollout status\ntype: note\n---\n# Orchard overview\n\n## Changes 2026-10-01\nEarly orchard plan.\n\n## Changes 2026-10-23\nLatest orchard delivery is pending.\n",
      "Elsewhere/Updates.md": "---\ntitle: Orchard rollout updates\ntype: note\n---\n# Updates\n\n## Changes 2026-10-30\nUnrelated excluded update.\n",
    ]
    let documents = source.map { OrbitRetrievalSnapshot.Document(path: $0.key, bytes: Data($0.value.utf8), sha256: digest(Data($0.value.utf8)), heads: []) }.sorted { $0.path < $1.path }
    let id = UUID().uuidString
    func snapshot(_ documents: [OrbitRetrievalSnapshot.Document]) throws -> OrbitRetrievalSnapshot {
      try OrbitRetrievalSnapshot(archive: .init(schema: 1, orbitID: id, snapshotID: UUID().uuidString, capturedAt: "2026-11-01T00:00:00Z", coverage: "complete", excludedPaths: [], documents: documents))
    }
    let scoped = try snapshot(documents).retrieve(query: "Tell me about Orchard rollout", limit: 3, scope: "Allowed")
    let isolated = try snapshot(documents.filter { $0.path.hasPrefix("Allowed/") }).retrieve(query: "Tell me about Orchard rollout", limit: 3, scope: "Allowed")
    XCTAssertEqual(scoped.evidence.map(\.path), isolated.evidence.map(\.path))
    XCTAssertEqual(scoped.evidence.map { $0.lines.map(\.number) }, isolated.evidence.map { $0.lines.map(\.number) })
    XCTAssertTrue(scoped.evidence.flatMap(\.lines).contains { $0.text.contains("2026-10-23") })
    XCTAssertFalse(scoped.evidence.flatMap(\.lines).contains { $0.text.contains("Unrelated") })
  }

  func testSnapshotTiming() throws {
    guard ProcessInfo.processInfo.environment["ORBIT_BENCHMARK"] == "1" else {
      throw XCTSkip("Opt-in disposable snapshot comparison")
    }
    let count = Int(ProcessInfo.processInfo.environment["ORBIT_BENCHMARK_NOTES"] ?? "500") ?? 500
    func checkpoint(_ stage: String) {
      var usage = rusage()
      getrusage(RUSAGE_SELF, &usage)
      print("ORBIT_SNAPSHOT_STAGE \(stage) peak_rss_bytes=\(usage.ru_maxrss)")
      fflush(stdout)
    }
    checkpoint("fixture-begin")
    var files = try seed(includeGenesis: false)
    for index in 0..<count {
      let text = "# Generated \(index)\n\n" + (0..<12).map {
        "## Section \($0)\n\nProject planning covers milestone \($0) for note \(index).\n\n"
      }.joined()
      let path = "Generated/Note\(index).md"
      files[path] = text
      try atomic(root.appendingPathComponent(path), Data(text.utf8))
    }
    checkpoint("seed-begin")
    try autoreleasepool { _ = try engine.replicationSeed(root, files: files) }
    checkpoint("seed-end")
    var samples: [JSONObject] = []
    func measure(_ stage: String, _ operation: () throws -> Void) throws {
      access.reset()
      checkpoint(stage + "-begin")
      let started = DispatchTime.now().uptimeNanoseconds
      try operation()
      let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
      samples.append(["stage": stage, "ms": elapsed, "source_accesses": access.calls,
        "source_reads": access.reads, "source_inspections": access.inspections])
      checkpoint(stage + "-end")
    }
    try measure("direct-cold") {
      let result = try engine.search(root, query: "practice public speaking", limit: 3)
      XCTAssertEqual(eObjects(result["results"]).first?["path"] as? String, "Knowledge/Speaking.md")
    }
    var snapshot: OrbitRetrievalSnapshot!
    try measure("capture") {
      snapshot = try engine.captureRetrievalSnapshot(root)
      XCTAssertEqual(snapshot.noteCount, files.count)
    }
    let url = base.appendingPathComponent("snapshot.json")
    try measure("persist") { try snapshot.write(to: url) }
    try measure("reopen") { snapshot = try OrbitRetrievalSnapshot(contentsOf: url, expectedOrbitID: snapshot.orbitID) }
    for iteration in 0..<25 {
      func direct() throws {
        try measure("direct-warm") {
          let result = try engine.search(root, query: "practice public speaking", limit: 3)
          let evidence = try XCTUnwrap(eObjects(result["results"]).first)
          XCTAssertEqual(evidence["path"] as? String, "Knowledge/Speaking.md")
          XCTAssertEqual(evidence["sha256"] as? String, digest(Data(files["Knowledge/Speaking.md"]!.utf8)))
          XCTAssertTrue(eObjects(evidence["snippets"]).contains { eString($0["text"]).contains("Pause between ideas") })
        }
      }
      func local() throws {
        try measure("snapshot-warm") {
          let result = try snapshot.retrieve(query: "practice public speaking")
          XCTAssertEqual(result.evidence.first?.path, "Knowledge/Speaking.md")
          XCTAssertTrue(result.evidence.first?.lines.contains { $0.text.contains("Pause between ideas") } == true)
          try verify(result, files: files)
          XCTAssertEqual(access.calls, 0)
        }
      }
      if iteration % 2 == 0 { try direct(); try local() } else { try local(); try direct() }
    }
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    #if targetEnvironment(simulator)
    let executionEnvironment = "simulator"
    #elseif os(iOS)
    let executionEnvironment = "physical-device"
    #else
    let executionEnvironment = "macos"
    #endif
    let report: JSONObject = ["schema": 1, "workload": "generated-format-3-local-folder",
      "execution_environment": executionEnvironment,
      "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
      "notes": files.count, "samples": samples, "archive_bytes": try Data(contentsOf: url).count,
      "process_peak_rss_bytes": usage.ru_maxrss,
      "failures": testRun?.failureCount ?? 0,
      "claim": "Core-only; snapshot freshness differs; no iCloud, host, model or end-to-end acceptance"]
    print("ORBIT_SNAPSHOT " + String(decoding: try canonical(report), as: UTF8.self))
  }

  func testRefreshChangesSnapshotAndPreservesOldEvidence() throws {
    let files = try seed()
    let old = try engine.captureRetrievalSnapshot(root)
    let before = try XCTUnwrap(files["Personal/Garden.md"])
    let after = before.replacingOccurrences(of: "rosemary", with: "lavender")
    _ = try engine.replicationCommit(root, writes: [["path": "Personal/Garden.md",
      "before": before, "after": after, "reason": "Fixture edit"]])
    let new = try engine.captureRetrievalSnapshot(root)
    XCTAssertNotEqual(new.snapshotID, old.snapshotID)
    XCTAssertTrue(try new.retrieve(query: "rosemary").evidence.isEmpty)
    XCTAssertEqual(try new.retrieve(query: "lavender").evidence.count, 1)
    XCTAssertEqual(try old.retrieve(query: "rosemary").evidence.count, 1)
  }

  func testConflictedSourceIsExcludedAndCoverageStaysPartial() throws {
    let files = try seed()
    let peer = base.appendingPathComponent("peer")
    try FileManager.default.copyItem(at: root, to: peer)
    let before = try XCTUnwrap(files["Personal/Garden.md"])
    for (folder, plant) in [(root!, "sage"), (peer, "lavender")] {
      _ = try engine.replicationCommit(folder, writes: [["path": "Personal/Garden.md",
        "before": before, "after": before.replacingOccurrences(of: "rosemary", with: plant), "reason": "Conflict fixture"]])
    }
    for url in try FileManager.default.contentsOfDirectory(at: peer.appendingPathComponent(".orbit/commits"), includingPropertiesForKeys: nil) {
      try atomic(root.appendingPathComponent(".orbit/commits/" + url.lastPathComponent), Data(contentsOf: url))
    }
    let result = try engine.captureRetrievalSnapshot(root).retrieve(query: "rosemary")
    XCTAssertTrue(result.evidence.isEmpty)
    XCTAssertEqual(result.capturedCoverage, "partial")
    XCTAssertTrue(result.excludedPaths.contains("Personal/Garden.md"))
  }
}

private final class CountingSnapshotAccess: OrbitFileAccess {
  let root: URL
  var calls = 0
  var deny = false
  var reads = 0
  var inspections = 0
  var afterRead: ((URL) throws -> Void)?
  init(root: URL) { self.root = root }
  func reset() { calls = 0; reads = 0; inspections = 0 }
  func coordinate(_ url: URL, mode: OrbitFileAccessMode, body: (URL) throws -> Void) throws {
    if url.path == root.path || url.path.hasPrefix(root.path + "/") {
      calls += 1
      if mode == .read { reads += 1 }
      if mode == .inspect { inspections += 1 }
      if deny { throw OrbitError("Fixture provider unavailable") }
    }
    try body(url)
    if mode == .read { try afterRead?(url) }
  }
}
