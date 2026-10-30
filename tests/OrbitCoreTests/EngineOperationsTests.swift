import XCTest

@testable import OrbitCore

final class EngineOperationsTests: XCTestCase {
  var base: URL!
  var root: URL!
  var engine: OrbitEngine!
  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "orbit-swift-engine-" + UUID().uuidString)
    root = base.appendingPathComponent("folder")
    engine = OrbitEngine(
      configURL: base.appendingPathComponent("config.json"),
      cacheURL: base.appendingPathComponent("cache"), stateURL: base.appendingPathComponent("state")
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try atomic(
      root.appendingPathComponent(".orbit/vault.json"),
      encode([
        "schema": 1, "id": "d76cb92b-49de-448d-bec7-438428196d31", "data_format": 2,
        "orbit_version": "0.5.0",
      ]))
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }
  func note(_ id: String = "n", extra: String = "", body: String = "Body\n") -> String {
    "---\nid: \"" + id
      + "\"\ntitle: \"Garden\"\ntype: \"concept\"\nsummary: \"Herbs beside the kitchen door\"\n"
      + extra + "---\n# Garden\n\n" + body
  }
  func plan(_ content: String, hash: Any = NSNull()) -> JSONObject {
    [
      "changes": [
        [
          "path": "Knowledge/Garden.md", "content": content, "reason": "Requested save",
          "expected_sha256": hash,
        ]
      ]
    ]
  }
  func testApplyPreservesExactBytesAndRejectsStaleVersion() throws {
    let text = note(body: "A user-written final section.\n")
    let receipt = try engine.apply(root, plan: plan(text))
    XCTAssertEqual(receipt["status"] as? String, "committed")
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("Knowledge/Garden.md")), Data(text.utf8))
    XCTAssertThrowsError(
      try engine.apply(
        root, plan: plan(note(body: "Changed\n"), hash: String(repeating: "0", count: 64))))
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("Knowledge/Garden.md")), Data(text.utf8))
    let read = try engine.read(root, path: "Knowledge/Garden.md", start: 1, count: 3)
    XCTAssertEqual(read["sha256"] as? String, digest(Data(text.utf8)))
    XCTAssertEqual(eObjects(read["lines"]).count, 3)
    XCTAssertTrue(eBool(read["more"]))
  }
  func testUnknownMetadataMustRemainVerbatim() throws {
    let text = note(extra: "custom:\n  nested: [a, b]\n")
    _ = try engine.apply(root, plan: plan(text))
    let hash = digest(Data(text.utf8))
    XCTAssertThrowsError(
      try engine.apply(root, plan: plan(note(extra: "custom:\n  nested: [b, a]\n"), hash: hash)))
    XCTAssertEqual(try eText(root.appendingPathComponent("Knowledge/Garden.md")), text)
  }
  func testSearchCatalogAndExternalFreshness() throws {
    let text = note(
      body:
        "Plant lavender beside the kitchen door.\n\n## Qualifications\nDo not plant before frost passes.\n"
    )
    _ = try engine.apply(root, plan: plan(text))
    let result = try engine.search(root, query: "lavender")
    XCTAssertEqual(eObjects(result["results"]).map { eString($0["path"]) }, ["Knowledge/Garden.md"])
    XCTAssertEqual(result["mode"] as? String, "sqlite-fts5-passages")
    let catalog = try engine.retrievalCatalog(root)
    XCTAssertEqual(catalog["total"] as? Int, 1)
    try atomic(
      root.appendingPathComponent("Knowledge/Garden.md"), Data(note(body: "Rosemary only.\n").utf8))
    XCTAssertTrue(eObjects(try engine.search(root, query: "lavender")["results"]).isEmpty)
    XCTAssertEqual(eObjects(try engine.search(root, query: "rosemary")["results"]).count, 1)
  }
  func testRecoveryRefusesHumanEditBeforeChangingAnyFile() throws {
    let operation = "185d95cc-30cb-4f2a-8a66-ea05a60cc29f"
    let text = note()
    let changed = note(body: "User edit\n")
    try atomic(root.appendingPathComponent("Knowledge/Garden.md"), Data(changed.utf8))
    try atomic(
      root.appendingPathComponent(".orbit/operations/" + operation + ".json"),
      encode([
        "id": operation, "status": "prepared",
        "writes": [
          ["path": "Knowledge/Garden.md", "before": text, "after": note(body: "Proposed\n")]
        ],
      ]))
    XCTAssertThrowsError(try engine.recover(root, operation: operation))
    XCTAssertEqual(try eText(root.appendingPathComponent("Knowledge/Garden.md")), changed)
    let abandoned = try engine.recover(root, operation: operation, abandon: true)
    XCTAssertEqual(abandoned["status"] as? String, "abandoned")
    XCTAssertEqual(try eText(root.appendingPathComponent("Knowledge/Garden.md")), changed)
  }
  func testPassagesRespectFencedHeadingsAndQualification() throws {
    let text =
      "---\nid: n\n---\n# Garden\n\nPlant herbs.\n\n```md\n## This is code\n```\n\n## Qualifications\nKeep dry.\n"
    let passages = notePassages(text)
    XCTAssertEqual(passages.count, 2)
    XCTAssertEqual(passages[0].section, "Garden")
    XCTAssertEqual(passages[1].section, "Garden / Qualifications")
    XCTAssertTrue(passages[0].body.contains("## This is code"))
  }
  func testCaptureDeduplicatesWithoutOverwritingAsset() throws {
    let file = base.appendingPathComponent("original.txt")
    try Data("Original source".utf8).write(to: file)
    let receipt = try engine.capture(root, source: file.path)
    XCTAssertEqual(receipt["status"] as? String, "captured")
    let duplicate = try engine.capture(root, source: file.path)
    XCTAssertEqual(duplicate["status"] as? String, "already-captured")
    let asset = try safe(root, eString(receipt["path"]))
    try atomic(asset, Data("Changed externally".utf8))
    XCTAssertThrowsError(try engine.capture(root, source: file.path))
    XCTAssertEqual(try eText(asset), "Changed externally")
  }
  func testIntegrationVersionRejectsBooleanAndAcceptsDecodedInteger() throws {
    let sourceHash = String(repeating: "a", count: 64)
    let path = try engine.knowledgeRecordPath(root, sha: sourceHash)
    let record: JSONObject = [
      "schema": 1, "source_sha256": sourceHash,
      "source_path": "Sources/assets/" + sourceHash + ".txt", "version": 1,
      "stage": "captured", "coverage": ["status": "unknown", "description": ""],
      "deferred": [], "errors": [], "extraction": [], "notes": [], "operations": [],
      "verification": [],
    ]
    try atomic(path, encode(record))
    let decoded = try readJSON(path)
    XCTAssertNoThrow(try engine.knowledgeValidateRecord(root, record: decoded, path: path))
    var invalid = record
    invalid["version"] = true
    XCTAssertThrowsError(try engine.knowledgeValidateRecord(root, record: invalid, path: path))
  }

  func testIntegrationRequiresEvidenceAndAdvancesThroughVerifiedRecall() throws {
    let file = base.appendingPathComponent("source.txt")
    try Data("Evidence about lavender".utf8).write(to: file)
    let capture = try engine.capture(root, source: file.path)
    let hash = eString(capture["sha256"])
    XCTAssertThrowsError(
      try engine.knowledgeIntegration(
        root,
        record: [
          "source_sha256": hash, "expected_version": 1, "stage": "integrated",
        ]))
    let text = note(body: "Lavender needs dry soil.\n")
    let operation = try engine.apply(root, plan: plan(text))
    let evidence: JSONObject = ["path": "Knowledge/Garden.md", "sha256": digest(Data(text.utf8))]
    let extracted = try engine.knowledgeIntegration(
      root,
      record: [
        "source_sha256": hash, "expected_version": 1, "stage": "extracted",
        "coverage": ["status": "full", "description": "Read complete source"],
        "extraction": [evidence],
      ])
    XCTAssertEqual(extracted["version"] as? Int, 2)
    let integrated = try engine.knowledgeIntegration(
      root,
      record: [
        "source_sha256": hash, "expected_version": 2, "stage": "integrated",
        "notes": [evidence], "operations": [eString(operation["operation"])],
      ])
    XCTAssertEqual(integrated["version"] as? Int, 3)
    let verified = try engine.knowledgeIntegration(
      root,
      record: [
        "source_sha256": hash, "expected_version": 3, "stage": "verified",
        "verification": [["query": "lavender", "paths": ["Knowledge/Garden.md"]]],
      ])
    XCTAssertEqual(verified["stage"] as? String, "verified")
    XCTAssertEqual(verified["version"] as? Int, 4)
    let finalRecord = try engine.knowledgeLoadRecord(
      root, path: engine.knowledgeRecordPath(root, sha: hash))
    XCTAssertEqual(finalRecord["stage"] as? String, "verified")
    try atomic(
      root.appendingPathComponent("Knowledge/Garden.md"), Data(note(body: "Human edit\n").utf8))
    let flags = eObjects(try engine.knowledgeMaintain(root)["candidates"])
    XCTAssertTrue(
      flags.contains { eString($0["kind"]) == "integration-evidence-changed" }, eJSON(flags))
  }

  func testUnavailableIndexFallsBackOnlyWithoutScope() throws {
    let text = note(body: "Lavender survives here.\n")
    _ = try engine.apply(root, plan: plan(text))
    let badCacheEngine = OrbitEngine(
      configURL: engine.configURL,
      cacheURL: root.appendingPathComponent(".orbit/cache"), stateURL: engine.stateURL)
    let fallback = try badCacheEngine.search(root, query: "lavender")
    XCTAssertEqual(fallback["mode"] as? String, "lexical-bm25-with-title-and-alias-boost")
    XCTAssertEqual((fallback["coverage"] as? JSONObject)?["state"] as? String, "degraded")
    XCTAssertEqual(eObjects(fallback["results"]).count, 1)
    let scoped = try badCacheEngine.search(root, query: "lavender", scope: "Knowledge")
    XCTAssertEqual(scoped["mode"] as? String, "unavailable")
    XCTAssertTrue(eObjects(scoped["results"]).isEmpty)
    XCTAssertFalse(eExists(root.appendingPathComponent(".orbit/cache")))
  }
  func testCorruptDerivedCacheRebuildDoesNotChangeNotes() throws {
    let text = note(body: "Lavender survives here.\n")
    _ = try engine.apply(root, plan: plan(text))
    let cache = try engine.retrievalCachePath(root)
    try Data("This is not a SQLite database".utf8).write(to: cache)
    let result = try engine.search(root, query: "lavender")
    XCTAssertEqual(result["mode"] as? String, "sqlite-fts5-passages")
    XCTAssertEqual(eObjects(result["results"]).count, 1)
    XCTAssertEqual(try eText(root.appendingPathComponent("Knowledge/Garden.md")), text)
  }

}
