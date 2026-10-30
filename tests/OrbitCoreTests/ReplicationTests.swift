import Foundation
import XCTest

@testable import OrbitCore

final class ReplicationTests: XCTestCase {
  private var base: URL!
  private var engine: OrbitEngine!
  private var a: URL!
  private var b: URL!
  private let identity = "d070a43d-ffb6-4af5-a8c7-f62bd812e581"

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "orbit-swift-replication-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    engine = OrbitEngine(
      configURL: base.appendingPathComponent("config.json"),
      cacheURL: base.appendingPathComponent("cache"), stateURL: base.appendingPathComponent("state")
    )
    a = base.appendingPathComponent("a")
    b = base.appendingPathComponent("b")
    try atomic(
      a.appendingPathComponent(".orbit/vault.json"), encode(["id": identity, "data_format": 3]))
    let files = ["A.md": note("a", "original A"), "B.md": note("b", "original B")]
    for (path, content) in files { try atomic(a.appendingPathComponent(path), Data(content.utf8)) }
    _ = try engine.replicationSeed(a, files: files)
    try FileManager.default.copyItem(at: a, to: b)
  }
  override func tearDownWithError() throws {
    if let base { try FileManager.default.removeItem(at: base) }
  }
  private func note(_ id: String, _ body: String) -> String {
    "---\nid: " + id + "\ntitle: Test\ntype: knowledge\nsummary: Test\n---\n" + body + "\n"
  }
  private func write(_ root: URL, _ path: String, _ after: String?) throws -> JSONObject {
    let target = root.appendingPathComponent(path)
    return [
      "path": path,
      "before": (try? String(contentsOf: target, encoding: .utf8)) as Any? ?? NSNull(),
      "after": after as Any? ?? NSNull(), "reason": "test",
    ]
  }
  private func deliver(_ source: URL, _ target: URL, only: String? = nil) throws {
    for directory in ["commits", "observations"] {
      let folder = source.appendingPathComponent(".orbit/" + directory)
      guard FileManager.default.fileExists(atPath: folder.path) else { continue }
      for path in try FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil)
      {
        if let only, directory == "commits", path.deletingPathExtension().lastPathComponent != only
        {
          continue
        }
        try atomic(
          target.appendingPathComponent(".orbit/" + directory + "/" + path.lastPathComponent),
          Data(contentsOf: path))
      }
    }
  }
  func testIndependentWritesConvergeWithoutNewHistory() throws {
    _ = try engine.replicationCommit(a, writes: [write(a, "A.md", note("a", "new A"))])
    _ = try engine.replicationCommit(b, writes: [write(b, "B.md", note("b", "new B"))])
    try deliver(a, b)
    try deliver(b, a)
    for root in [a!, b!] {
      XCTAssertEqual(try engine.replicationReconcile(root)["status"] as? String, "ready")
      XCTAssertEqual(
        try String(contentsOf: root.appendingPathComponent("A.md")), note("a", "new A"))
      XCTAssertEqual(
        try String(contentsOf: root.appendingPathComponent("B.md")), note("b", "new B"))
      XCTAssertEqual(
        try FileManager.default.contentsOfDirectory(
          atPath: root.appendingPathComponent(".orbit/commits").path
        ).count, 3)
    }
    XCTAssertEqual(
      try canonical(engine.replicationInspect(a)), try canonical(engine.replicationInspect(b)))
  }
  func testConflictRequiresExactHeadsAndLateBranchReturns() throws {
    let c = base.appendingPathComponent("c")
    try FileManager.default.copyItem(at: a, to: c)
    for (root, body) in [(a!, "left"), (b!, "right"), (c, "late")] {
      _ = try engine.replicationCommit(root, writes: [write(root, "A.md", note("a", body))])
    }
    try deliver(b, a)
    let state = try engine.replicationReconcile(a)
    XCTAssertEqual(state["blocked_paths"] as? [String], ["A.md"])
    XCTAssertThrowsError(
      try engine.replicationCommit(a, writes: [write(a, "A.md", note("a", "bad merge"))]))
    var resolution = try write(a, "A.md", note("a", "resolved"))
    resolution["expected_heads"] = (state["heads"] as! JSONObject)["A.md"]!
    XCTAssertEqual(try engine.replicationCommit(a, writes: [resolution])["verified"] as? Bool, true)
    try deliver(a, b)
    XCTAssertEqual(try engine.replicationReconcile(b)["status"] as? String, "ready")
    try deliver(c, a)
    let conflicts = try engine.replicationReconcile(a)["conflicts"] as! [JSONObject]
    XCTAssertEqual((conflicts[0]["heads"] as! [String]).count, 2)
    let revisions = try engine.replicationHistory(a, path: "A.md")["revisions"] as! [JSONObject]
    XCTAssertTrue(
      Set(["left", "right", "late", "resolved"].map { note("a", $0) }).isSubset(
        of: Set(revisions.compactMap { $0["content"] as? String })))
  }
  func testExternalBytesRequireObservationAndHeads() throws {
    let edited = note("a", "external\r\nexact")
    try atomic(a.appendingPathComponent("A.md"), Data(edited.utf8))
    XCTAssertEqual(try engine.replicationInspect(a)["status"] as? String, "conflicted")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: a.appendingPathComponent(".orbit/observations").path))
    let state = try engine.replicationReconcile(a)
    let observations = (state["conflicts"] as! [JSONObject])[0]["observations"] as! [String]
    var change = try write(a, "A.md", edited)
    change["observations"] = observations
    XCTAssertThrowsError(try engine.replicationCommit(a, writes: [change]))
    change["expected_heads"] = (state["heads"] as! JSONObject)["A.md"]!
    let result = try engine.replicationCommit(a, writes: [change])
    XCTAssertEqual((result["sync"] as! JSONObject)["status"] as? String, "ready")
    let history = try engine.replicationHistory(a, path: "A.md")
    XCTAssertEqual((history["observations"] as! [JSONObject])[0]["content"] as? String, edited)
    XCTAssertEqual(try Data(contentsOf: a.appendingPathComponent("A.md")), Data(edited.utf8))
  }
  func testMissingParentsAndChangedRetryRefuse() throws {
    let first = try engine.replicationCommit(a, writes: [write(a, "A.md", note("a", "first"))])
    let request = UUID().uuidString.lowercased()
    let second = try engine.replicationCommit(
      a, writes: [write(a, "A.md", note("a", "second"))], requestID: request,
      requestDigest: "logical request")
    try deliver(a, b, only: second["operation"] as? String)
    XCTAssertEqual(try engine.replicationReconcile(b)["status"] as? String, "pending")
    XCTAssertThrowsError(try engine.replicationOperation(b, id: request))
    try deliver(a, b, only: first["operation"] as? String)
    XCTAssertEqual(try engine.replicationReconcile(b)["status"] as? String, "ready")
    XCTAssertEqual(
      try engine.replicationRetry(a, requestID: request, requestDigest: "logical request")?[
        "operation"] as? String, request)
    XCTAssertThrowsError(
      try engine.replicationRetry(a, requestID: request, requestDigest: "changed"))
  }
  func testCorruptionBlocksEveryPathAndDoesNotWrite() throws {
    let before = try Data(contentsOf: a.appendingPathComponent("A.md"))
    try atomic(a.appendingPathComponent(".orbit/commits/bad.json"), Data("{}".utf8))
    let state = try engine.replicationInspect(a)
    XCTAssertEqual(state["status"] as? String, "invalid")
    XCTAssertEqual(state["blocked_paths"] as? [String], ["A.md", "B.md"])
    XCTAssertEqual(try engine.replicationReconcile(a)["materialized"] as? [String], [])
    XCTAssertEqual(try Data(contentsOf: a.appendingPathComponent("A.md")), before)
  }
  func testGenesisIsStableAndPreviewMatchesPublishedBytes() throws {
    let preview = try engine.replicationSeedPreview(
      a, files: ["A.md": note("a", "original A"), "B.md": note("b", "original B")])
    XCTAssertEqual(preview["operation"] as? String, "a37a039c-0b1a-5761-803a-43d1a3df9e48")
    let raw = try Data(contentsOf: a.appendingPathComponent(preview["path"] as! String))
    XCTAssertEqual(digest(raw), preview["sha256"] as? String)
    XCTAssertEqual(digest(raw), "2b06bbace8c812328f31e942d9d68c1c40ab1560e885fe9a40bd4adc16bec65a")
  }
  func testRenameRetainsHistoryAndConcurrentOldPathEditConflicts() throws {
    _ = try engine.replicationCommit(
      a, writes: [write(a, "A.md", nil), write(a, "New.md", note("a", "renamed"))])
    XCTAssertFalse(FileManager.default.fileExists(atPath: a.appendingPathComponent("A.md").path))
    _ = try engine.replicationCommit(b, writes: [write(b, "A.md", note("a", "stale"))])
    try deliver(b, a)
    XCTAssertEqual(
      try engine.replicationReconcile(a)["blocked_paths"] as? [String], ["A.md", "New.md"])
  }
  func testAssetsHoldEntireOperationUntilDelivered() throws {
    let raw = Data("original source".utf8)
    let hash = digest(Data("original source".utf8))
    let relative = "Sources/assets/" + hash + ".txt"
    try atomic(a.appendingPathComponent(relative), raw)
    _ = try engine.replicationCommit(
      a,
      writes: [
        write(a, "A.md", note("a", "[[" + relative + "]]")), write(a, "B.md", note("b", "batch")),
      ])
    try deliver(a, b)
    XCTAssertEqual(try engine.replicationReconcile(b)["status"] as? String, "pending")
    XCTAssertEqual(
      try String(contentsOf: b.appendingPathComponent("B.md")), note("b", "original B"))
    try atomic(b.appendingPathComponent(relative), raw)
    XCTAssertEqual(try engine.replicationReconcile(b)["status"] as? String, "ready")
    XCTAssertEqual(try String(contentsOf: b.appendingPathComponent("B.md")), note("b", "batch"))
  }
  func testCanonicalGenesisPathHashMatchesPython() throws {
    let files = [
      "a10": "ten", "a2": "two", "A": "upper", "a": "lower", "é": "accent", "😀": "emoji",
      "Z": "last", "/": "slash", "control": "line\u{2028}paragraph\u{2029}tab\t",
    ]
    XCTAssertEqual(
      digest(try canonical(files)),
      "1968b2021f6c765b581b0f824eb3e39f96946944a546f3443ae900c0e93feb54")
  }

  func testCanonicallyEquivalentUnicodeBytesRemainDistinct() throws {
    let decomposed = note("a", "e\u{0301}")
    let composed = note("a", "é")
    _ = try engine.replicationCommit(a, writes: [write(a, "A.md", decomposed)])
    try atomic(a.appendingPathComponent("A.md"), Data(composed.utf8))
    let state = try engine.replicationReconcile(a)
    XCTAssertEqual(state["status"] as? String, "conflicted")
    XCTAssertEqual(try Data(contentsOf: a.appendingPathComponent("A.md")), Data(composed.utf8))
    XCTAssertThrowsError(try engine.replicationCommit(a, writes: [write(a, "A.md", decomposed)]))
  }

  func testConcurrentPathCollisionRequiresUnionAndRetainsLoser() throws {
    _ = try engine.replicationCommit(a, writes: [write(a, "Same.md", note("left", "left"))])
    _ = try engine.replicationCommit(b, writes: [write(b, "Same.md", note("right", "right"))])
    try deliver(a, b)
    try deliver(b, a)
    let state = try engine.replicationReconcile(a)
    XCTAssertEqual((state["conflicts"] as! [JSONObject]).count, 2)
    XCTAssertEqual(state["blocked_paths"] as? [String], ["Same.md"])
    let heads = (state["heads"] as! JSONObject)["Same.md"] as! [String]
    var change = try write(a, "Same.md", note("right", "right"))
    change["expected_heads"] = Array(heads.prefix(1))
    XCTAssertThrowsError(try engine.replicationCommit(a, writes: [change]))
    change["expected_heads"] = heads
    let result = try engine.replicationCommit(a, writes: [change])
    XCTAssertEqual(result["verified"] as? Bool, true)
    XCTAssertEqual((result["sync"] as! JSONObject)["status"] as? String, "ready")
    try deliver(a, b)
    XCTAssertEqual(try engine.replicationReconcile(b)["status"] as? String, "ready")
    for root in [a!, b!] {
      XCTAssertEqual(
        try String(contentsOf: root.appendingPathComponent("Same.md")), note("right", "right"))
      let revisions =
        try engine.replicationHistory(root, path: "Same.md")["revisions"] as! [JSONObject]
      XCTAssertTrue(revisions.contains { $0["retired"] as? Bool == true })
      XCTAssertTrue(revisions.contains { $0["content"] as? String == note("left", "left") })
    }
    XCTAssertEqual(
      try engine.replicationCommit(a, writes: [write(a, "Same.md", note("right", "later"))])[
        "verified"] as? Bool, true)
  }
  func testStalePhysicalBytesCannotParentUnreadAcceptedHead() throws {
    let accepted = try engine.replicationCommit(a, writes: [write(a, "A.md", note("a", "remote"))])
    try deliver(a, b, only: accepted["operation"] as? String)
    XCTAssertThrowsError(
      try engine.replicationCommit(b, writes: [write(b, "A.md", note("a", "overwrite"))]))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        atPath: b.appendingPathComponent(".orbit/commits").path
      ).count, 2)
  }
  func testMarkdownBeforeEnvelopeNeverInventsAncestry() throws {
    let result = try engine.replicationCommit(a, writes: [write(a, "A.md", note("a", "remote"))])
    try atomic(b.appendingPathComponent("A.md"), Data(contentsOf: a.appendingPathComponent("A.md")))
    XCTAssertEqual(try engine.replicationReconcile(b)["status"] as? String, "conflicted")
    try deliver(a, b, only: result["operation"] as? String)
    XCTAssertEqual(try engine.replicationReconcile(b)["status"] as? String, "ready")
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        atPath: b.appendingPathComponent(".orbit/commits").path
      ).count, 2)
  }
  func testPlainObservationAdoptsIdentityAndDuplicateIdentityBlocksBoth() throws {
    try atomic(a.appendingPathComponent("Plain.md"), Data("# Plain\n".utf8))
    let state = try engine.replicationReconcile(a)
    let conflict = (state["conflicts"] as! [JSONObject]).first {
      $0["entity"] as? String == "path:Plain.md"
    }!
    var change = try write(a, "Plain.md", note("a", "duplicate"))
    change["expected_heads"] = [String]()
    change["observations"] = conflict["observations"]!
    let result = try engine.replicationCommit(a, writes: [change])
    let sync = result["sync"] as! JSONObject
    XCTAssertEqual(sync["status"] as? String, "conflicted")
    XCTAssertEqual(sync["blocked_paths"] as? [String], ["A.md", "Plain.md"])
    XCTAssertEqual(try String(contentsOf: a.appendingPathComponent("Plain.md")), "# Plain\n")
  }
  private func durableFiles(_ root: URL) throws -> [String: Data] {
    var files: [String: Data] = [:]
    func walk(_ directory: URL, _ prefix: String) throws {
      for path in try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isDirectoryKey])
      {
        let key = prefix + path.lastPathComponent
        if try path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
          try walk(path, key + "/")
        } else {
          files[key] = try Data(contentsOf: path)
        }
      }
    }
    try walk(root, "")
    return files
  }
  func testDryRunAdoptsEphemeralObservationWithoutAnyWrites() throws {
    try atomic(a.appendingPathComponent("Plain.md"), Data("# Plain\n".utf8))
    let state = try engine.replicationInspect(a)
    let conflict = (state["conflicts"] as! [JSONObject]).first {
      $0["entity"] as? String == "path:Plain.md"
    }!
    var change = try write(a, "Plain.md", note("formatted", "Plain"))
    change["expected_heads"] = [String]()
    change["observations"] = conflict["observations"]!
    let before = try durableFiles(base)
    let result = try engine.replicationCommit(a, writes: [change], dryRun: true)
    XCTAssertEqual(result["status"] as? String, "preview")
    XCTAssertEqual(try durableFiles(base), before)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: a.appendingPathComponent(".orbit/observations").path))
    XCTAssertEqual(try engine.replicationCommit(a, writes: [change])["verified"] as? Bool, true)
  }
  func testDryRunRetryNeverReconcilesAcceptedOperation() throws {
    let request = UUID().uuidString.lowercased()
    let writes = try [write(a, "A.md", note("a", "accepted"))]
    let result = try engine.replicationCommit(a, writes: writes, requestID: request)
    try atomic(a.appendingPathComponent("A.md"), Data(note("a", "original A").utf8))
    let before = try durableFiles(base)
    let preview = try engine.replicationCommit(a, writes: writes, requestID: request, dryRun: true)
    XCTAssertEqual(preview["status"] as? String, "preview")
    XCTAssertEqual(preview["already_committed"] as? Bool, true)
    XCTAssertEqual(preview["operation"] as? String, result["operation"] as? String)
    XCTAssertEqual(try durableFiles(base), before)
    XCTAssertThrowsError(
      try engine.replicationCommit(
        a, writes: writes, requestID: request, requestDigest: "changed", dryRun: true))
  }
  func testNestedLocksAndMissingHistory() throws {
    try engine.withLocalLock(a) {
      try engine.withLocalLock(a) {
        XCTAssertEqual(try engine.replicationInspect(a)["status"] as? String, "ready")
      }
    }
    try FileManager.default.removeItem(at: a.appendingPathComponent(".orbit/commits"))
    XCTAssertEqual(try engine.replicationInspect(a)["status"] as? String, "invalid")
    XCTAssertEqual(try engine.replicationReconcile(a)["materialized"] as? [String], [])
  }
  func testRenameDescendantRemovesOldLocationAfterLateDelivery() throws {
    _ = try engine.replicationCommit(
      a, writes: [write(a, "A.md", nil), write(a, "New.md", note("a", "renamed"))])
    _ = try engine.replicationCommit(a, writes: [write(a, "New.md", note("a", "later"))])
    try deliver(a, b)
    XCTAssertEqual(try engine.replicationReconcile(b)["status"] as? String, "ready")
    try atomic(b.appendingPathComponent("A.md"), Data(note("a", "original A").utf8))
    XCTAssertEqual(try engine.replicationReconcile(b)["status"] as? String, "ready")
    XCTAssertFalse(FileManager.default.fileExists(atPath: b.appendingPathComponent("A.md").path))
    XCTAssertEqual(try String(contentsOf: b.appendingPathComponent("New.md")), note("a", "later"))
  }

  func testEveryDeliveryOrderKeepsIdenticalHeads() throws {
    let seedFiles = try FileManager.default.contentsOfDirectory(
      at: a.appendingPathComponent(".orbit/commits"), includingPropertiesForKeys: nil)
    let first =
      try engine.replicationCommit(a, writes: [write(a, "A.md", note("a", "one"))])["operation"]
      as! String
    let second =
      try engine.replicationCommit(a, writes: [write(a, "A.md", note("a", "two"))])["operation"]
      as! String
    let third =
      try engine.replicationCommit(b, writes: [write(b, "A.md", note("a", "concurrent"))])[
        "operation"] as! String
    let sources = [first: a!, second: a!, third: b!]
    let orders = [
      [first, second, third], [first, third, second], [second, first, third],
      [second, third, first], [third, first, second], [third, second, first],
    ]
    var reports: [Data] = []
    for (number, order) in orders.enumerated() {
      let target = base.appendingPathComponent("order-" + String(number))
      try atomic(
        target.appendingPathComponent(".orbit/vault.json"),
        Data(contentsOf: a.appendingPathComponent(".orbit/vault.json")))
      try atomic(
        target.appendingPathComponent(".orbit/commits/" + seedFiles[0].lastPathComponent),
        Data(contentsOf: seedFiles[0]))
      try atomic(target.appendingPathComponent("A.md"), Data(note("a", "original A").utf8))
      try atomic(target.appendingPathComponent("B.md"), Data(note("b", "original B").utf8))
      for operation in order {
        try deliver(sources[operation]!, target, only: operation)
        _ = try engine.replicationReconcile(target)
        try deliver(sources[operation]!, target, only: operation)
      }
      reports.append(try canonical(engine.replicationInspect(target)))
      let conflicts = try engine.replicationInspect(target)["conflicts"] as! [JSONObject]
      XCTAssertEqual((conflicts[0]["heads"] as! [String]).count, 2)
    }
    XCTAssertTrue(reports.allSatisfy { $0 == reports[0] })
  }
  func testConcurrentIntegrationVersionsPreserveBothEvidenceSets() throws {
    let hash = String(repeating: "a", count: 64)
    let path = ".orbit/integrations/" + String(repeating: "a", count: 64) + ".json"
    let initial = String(
      data: try canonical(["source_sha256": hash, "stage": "captured", "version": 1]),
      encoding: .utf8)!
    _ = try engine.replicationCommit(a, writes: [write(a, path, initial)])
    try deliver(a, b)
    _ = try engine.replicationReconcile(b)
    for (root, evidence) in [(a!, "left evidence"), (b!, "right evidence")] {
      let content = String(
        data: try canonical([
          "source_sha256": hash, "stage": "extracted", "version": 2, "evidence": evidence,
        ]), encoding: .utf8)!
      _ = try engine.replicationCommit(root, writes: [write(root, path, content)])
    }
    try deliver(a, b)
    let report = try engine.replicationReconcile(b)
    XCTAssertEqual(report["blocked_paths"] as? [String], [path])
    XCTAssertEqual((((report["conflicts"] as! [JSONObject])[0])["heads"] as! [String]).count, 2)
    XCTAssertEqual(
      (try engine.replicationHistory(b, path: path)["revisions"] as! [JSONObject]).count, 3)
  }
  func testDryRunChecksExactHeadsWithoutChangingAnyFiles() throws {
    _ = try engine.replicationCommit(a, writes: [write(a, "A.md", note("a", "left"))])
    _ = try engine.replicationCommit(b, writes: [write(b, "A.md", note("a", "right"))])
    try deliver(b, a)
    let state = try engine.replicationInspect(a)
    let heads = (try engine.replicationInspect(a)["heads"] as! JSONObject)["A.md"] as! [String]
    let before = try durableFiles(base)
    for supplied in [[String](), Array(heads.prefix(1)), ["stale"]] {
      var change = try write(a, "A.md", note("a", "resolved"))
      change["expected_heads"] = supplied
      XCTAssertThrowsError(try engine.replicationCommit(a, writes: [change], dryRun: true))
    }
    var change = try write(a, "A.md", note("a", "resolved"))
    change["expected_heads"] = (state["heads"] as! JSONObject)["A.md"]!
    XCTAssertEqual(
      try engine.replicationCommit(a, writes: [change], dryRun: true)["status"] as? String,
      "preview")
    XCTAssertEqual(try durableFiles(base), before)
  }

  func testFirstLockCreationAndAlternateCanonicalURLAreReentrant() throws {
    let state = base.appendingPathComponent("new-state")
    let other = OrbitEngine(
      configURL: base.appendingPathComponent("other-config.json"),
      cacheURL: base.appendingPathComponent("other-cache"), stateURL: state)
    let resolved = a.path.withCString { realpath($0, nil) }!
    let canonicalRoot = String(cString: resolved)
    free(resolved)
    let root = URL(fileURLWithPath: canonicalRoot)
    try other.withLocalLock(a) {
      try other.withLocalLock(root) {
        XCTAssertEqual(try other.replicationInspect(root)["status"] as? String, "ready")
      }
    }
    let expected = digest(try canonical([canonicalRoot, identity]))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: state.appendingPathComponent(expected).appendingPathComponent("write.lock").path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: a.appendingPathComponent(".orbit/write.lock").path))
  }

  func testNewNestedDestinationUnderCanonicalTemporaryRoot() throws {
    let resolved = a.path.withCString { realpath($0, nil) }!
    let root = URL(fileURLWithPath: String(cString: resolved))
    free(resolved)
    let relative = "Nested/Previously Missing/Note.md"
    let result = try engine.replicationCommit(
      root, writes: [write(root, relative, note("nested", "new"))])
    XCTAssertEqual(result["verified"] as? Bool, true)
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent(relative)), Data(note("nested", "new").utf8))
    for invalid in ["Nested//Bad.md", "Nested/./Bad.md", "Nested/Bad.md/"] {
      XCTAssertThrowsError(
        try engine.replicationCommit(root, writes: [write(root, invalid, note("bad", "bad"))]))
    }
  }

}
