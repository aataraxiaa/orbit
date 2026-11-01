import Foundation
import XCTest

@testable import OrbitCore

final class RetrievalRankingTests: XCTestCase {
  func testRegexOptionsAndUnicodePatternSpellingStayIndependent() {
    XCTAssertTrue(eMatches("^quartz$", "Quartz").isEmpty)
    XCTAssertFalse(eMatches("^quartz$", "Quartz", .caseInsensitive).isEmpty)
    XCTAssertTrue(eMatches("^quartz$", "Quartz").isEmpty)
    XCTAssertFalse(eMatches("é", "é").isEmpty)
    XCTAssertTrue(eMatches("e\u{301}", "é").isEmpty)
    XCTAssertFalse(eMatches("e\u{301}", "e\u{301}").isEmpty)
  }
  private var base: URL!
  private var root: URL!
  private var engine: OrbitEngine!

  override func setUpWithError() throws {
    base = realURL(FileManager.default.temporaryDirectory).appendingPathComponent(
      "orbit-retrieval-ranking-" + UUID().uuidString)
    root = base.appendingPathComponent("vault")
    engine = OrbitEngine(
      configURL: base.appendingPathComponent("config.json"),
      cacheURL: base.appendingPathComponent("cache"),
      stateURL: base.appendingPathComponent("state"))
    try atomic(
      root.appendingPathComponent(".orbit/vault.json"),
      encode([
        "schema": 1, "id": UUID().uuidString.lowercased(), "data_format": 2,
        "orbit_version": "0.5.0",
      ]))
  }

  override func tearDownWithError() throws {
    if let base { try FileManager.default.removeItem(at: base) }
  }

  @discardableResult
  private func write(
    _ path: String, title: String, aliases: [String] = [], type: String = "concept",
    status: String = "current", project: String = "", body: String
  ) throws -> String {
    func compact(_ value: Any) throws -> String {
      String(decoding: try canonical(value), as: UTF8.self)
    }
    let text =
      try "---\nid: " + compact(path) + "\ntitle: " + compact(title)
      + "\ntype: " + compact(type) + "\nstatus: " + compact(status)
      + "\nproject: " + compact(project) + "\naliases: " + compact(aliases)
      + "\nsummary: \"\"\n---\n# " + title + "\n\n" + body + "\n"
    try atomic(root.appendingPathComponent(path), Data(text.utf8))
    return text
  }

  private func paths(_ result: JSONObject) -> [String] {
    eObjects(result["results"]).map { eString($0["path"]) }
  }

  private func verifyEvidence(
    _ result: JSONObject, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    XCTAssertEqual(result["mode"] as? String, "sqlite-fts5-passages", file: file, line: line)
    XCTAssertLessThanOrEqual(eJSON(result).unicodeScalars.count, 12_000, file: file, line: line)
    for row in eObjects(result["results"]) {
      let bytes = try Data(contentsOf: root.appendingPathComponent(eString(row["path"])))
      XCTAssertEqual(row["sha256"] as? String, digest(bytes), file: file, line: line)
      let lines = eLines(String(decoding: bytes, as: UTF8.self))
      let snippets = eObjects(row["snippets"])
      XCTAssertFalse(snippets.isEmpty, file: file, line: line)
      for snippet in snippets {
        let number = eInt(snippet["line"])
        XCTAssertTrue((1...lines.count).contains(number), file: file, line: line)
        if (1...lines.count).contains(number) {
          XCTAssertEqual(snippet["text"] as? String, lines[number - 1], file: file, line: line)
        }
      }
    }
  }

  func testExactTitleOutranksStrongerBodyMatchAtLimitOne() throws {
    let filler = String(
      repeating: "Unrelated background context occupies this passage.\n", count: 180)
    try write("Knowledge/Exact.md", title: "Silver comet", body: filler)
    try write(
      "Knowledge/Decoy.md", title: "Observations",
      body: String(repeating: "silver comet ", count: 40))
    let result = try engine.search(root, query: "silver comet", limit: 1)
    XCTAssertEqual(paths(result), ["Knowledge/Exact.md"])
    XCTAssertEqual(result["total"] as? Int, 2)
    let decoy = try engine.search(
      root, query: "silver comet", limit: 1, scope: "Knowledge/Decoy.md")
    let exactScore = try XCTUnwrap(eObjects(result["results"]).first?["score"] as? Double)
    let decoyScore = try XCTUnwrap(eObjects(decoy["results"]).first?["score"] as? Double)
    XCTAssertLessThan(
      exactScore, decoyScore, "Fixture must require exact-title promotion over BM25")
    try verifyEvidence(result)
  }

  func testExactAliasOutranksStrongerBodyMatchAtLimitOne() throws {
    let filler = String(
      repeating: "Unrelated background context occupies this passage.\n", count: 180)
    try write("Knowledge/Alias.md", title: "Reference", aliases: ["Silver comet"], body: filler)
    try write(
      "Knowledge/Decoy.md", title: "Observations",
      body: String(repeating: "silver comet ", count: 40))
    let result = try engine.search(root, query: "silver comet", limit: 1)
    XCTAssertEqual(paths(result), ["Knowledge/Alias.md"])
    XCTAssertEqual(result["total"] as? Int, 2)
    let decoy = try engine.search(
      root, query: "silver comet", limit: 1, scope: "Knowledge/Decoy.md")
    let aliasScore = try XCTUnwrap(eObjects(result["results"]).first?["score"] as? Double)
    let decoyScore = try XCTUnwrap(eObjects(decoy["results"]).first?["score"] as? Double)
    XCTAssertLessThan(
      aliasScore, decoyScore, "Fixture must require exact-alias promotion over BM25")
    try verifyEvidence(result)
  }

  func testUnicodeCasefoldAliasPromotionIsPreserved() throws {
    let filler = String(
      repeating: "Unrelated background context occupies this passage.\n", count: 180)
    try write(
      "Knowledge/Unicode.md", title: "Reference", aliases: ["Straße"],
      body: "strasse\n" + filler)
    try write(
      "Knowledge/Decoy.md", title: "Observations",
      body: String(repeating: "strasse ", count: 40))
    XCTAssertEqual(casefold("Straße"), casefold("STRASSE"))
    let result = try engine.search(root, query: "STRASSE", limit: 1)
    XCTAssertEqual(paths(result), ["Knowledge/Unicode.md"])
    try verifyEvidence(result)
  }

  func testRepeatedPassagesCannotCrowdOutDistinctNotes() throws {
    let repeated = (0..<30).map { "## Segment \($0)\n\nquartz quartz quartz\n\n" }.joined()
    try write("Knowledge/Long.md", title: "Long", body: repeated)
    for suffix in ["A", "B", "C", "D"] {
      try write("Knowledge/\(suffix).md", title: "Note \(suffix)", body: "quartz")
    }
    let result = try engine.search(root, query: "quartz", limit: 5)
    XCTAssertEqual(result["total"] as? Int, 5)
    XCTAssertEqual(
      Set(paths(result)),
      Set([
        "Knowledge/Long.md", "Knowledge/A.md", "Knowledge/B.md", "Knowledge/C.md", "Knowledge/D.md",
      ]))
    XCTAssertEqual(paths(result).count, 5)
    try verifyEvidence(result)
  }

  func testEqualRanksHaveStablePathOrderAcrossCacheRebuild() throws {
    for suffix in ["C", "A", "B"] {
      try write("Knowledge/\(suffix).md", title: "Identical", body: "quartz evidence")
    }
    let expected = ["Knowledge/A.md", "Knowledge/B.md", "Knowledge/C.md"]
    for _ in 0..<2 {
      let result = try engine.search(root, query: "quartz", limit: 3)
      XCTAssertEqual(paths(result), expected)
      try verifyEvidence(result)
      _ = try engine.retrievalRefresh(root, rebuild: true)
    }
  }

  func testScopeTypeAndStatusApplyBeforeResultLimitAndTotal() throws {
    try write(
      "Knowledge/Chosen.md", title: "Chosen", type: "decision", project: "Orchard",
      body: "quartz evidence")
    try write(
      "Knowledge/Archived.md", title: "Archived", type: "decision", status: "archived",
      project: "Orchard", body: "quartz evidence")
    try write(
      "Knowledge/Concept.md", title: "Concept", project: "Orchard", body: "quartz evidence")
    try write(
      "Elsewhere/Other.md", title: "Other", type: "decision", project: "Elsewhere",
      body: "quartz evidence")
    let result = try engine.search(
      root, query: "quartz", limit: 1, scope: "Orchard", noteType: "decision", status: "current")
    XCTAssertEqual(paths(result), ["Knowledge/Chosen.md"])
    XCTAssertEqual(result["total"] as? Int, 1)
    try verifyEvidence(result)
    let folder = try engine.search(root, query: "quartz", scope: "Knowledge")
    XCTAssertEqual(folder["total"] as? Int, 3)
    XCTAssertTrue(paths(folder).allSatisfy { $0.hasPrefix("Knowledge/") })
    let absent = try engine.search(root, query: "quartz", scope: "Missing")
    XCTAssertEqual(absent["total"] as? Int, 0)
    XCTAssertTrue(paths(absent).isEmpty)
  }

  func testExternalEditRemovalAndCorruptCacheNeverReturnOldEvidence() throws {
    try write("Knowledge/Mutable.md", title: "Mutable", body: "lavender evidence")
    let original = try engine.search(root, query: "lavender")
    XCTAssertEqual(paths(original), ["Knowledge/Mutable.md"])
    try verifyEvidence(original)
    let edited = try write("Knowledge/Mutable.md", title: "Mutable", body: "rosemary evidence")
    XCTAssertTrue(paths(try engine.search(root, query: "lavender")).isEmpty)
    let updated = try engine.search(root, query: "rosemary")
    XCTAssertEqual(paths(updated), ["Knowledge/Mutable.md"])
    try verifyEvidence(updated)
    let cache = try engine.retrievalCachePath(root)
    try Data("Not a SQLite database".utf8).write(to: cache)
    let recovered = try engine.search(root, query: "rosemary")
    XCTAssertEqual(paths(recovered), ["Knowledge/Mutable.md"])
    try verifyEvidence(recovered)
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("Knowledge/Mutable.md")), Data(edited.utf8))
    try FileManager.default.removeItem(at: root.appendingPathComponent("Knowledge/Mutable.md"))
    let removed = try engine.search(root, query: "rosemary")
    XCTAssertEqual(removed["total"] as? Int, 0)
    XCTAssertTrue(paths(removed).isEmpty)
  }

  func testLongExcerptRemainsWithinCapWithTruthfulLineNumbers() throws {
    let body = (0..<200).map { "quartz evidence line \($0) " + String(repeating: "x", count: 70) }
      .joined(separator: "\n")
    try write("Knowledge/Large.md", title: "Large", body: body)
    let result = try engine.search(root, query: "quartz", limit: 8)
    XCTAssertEqual(paths(result), ["Knowledge/Large.md"])
    XCTAssertEqual((result["coverage"] as? JSONObject)?["truncated"] as? Bool, true)
    try verifyEvidence(result)
  }

  func testEscapedUnicodeAliasKeepsPromotionAndTruthfulPayload() throws {
    let alias = "Quote \" slash \\ tab\t line\ncontrol\u{1} café 😀"
    let filler = String(
      repeating: "Unrelated background context occupies this passage.\n", count: 180)
    try write("Knowledge/Escaped.md", title: "Reference", aliases: [alias], body: filler)
    try write(
      "Knowledge/Decoy.md", title: "Observations",
      body: String(repeating: "quote slash tab line control cafe ", count: 40))
    let result = try engine.search(root, query: alias, limit: 1)
    XCTAssertEqual(paths(result), ["Knowledge/Escaped.md"])
    try verifyEvidence(result)
  }

  func testCanonicallyEquivalentUnicodeAliasesRemainExactMatches() throws {
    let filler = String(
      repeating: "Unrelated background context occupies this passage.\n", count: 180)
    try write("Knowledge/Accent.md", title: "Reference", aliases: ["Café"], body: filler)
    try write(
      "Knowledge/Decoy.md", title: "Observations", body: String(repeating: "cafe ", count: 40))
    for query in ["CAFÉ", "Cafe\u{301}"] {
      let result = try engine.search(root, query: query, limit: 1)
      XCTAssertEqual(paths(result), ["Knowledge/Accent.md"])
      try verifyEvidence(result)
    }
  }

  func testTiedUnicodePathsUseSwiftOrdering() throws {
    let names = ["éclair", "zebra", "Äther", "Ωmega", "😀", "あ"]
    let expected = names.map { "Knowledge/" + $0 + ".md" }.sorted()
    for name in names {
      try write("Knowledge/" + name + ".md", title: "Identical", body: "quartz evidence")
    }
    let result = try engine.search(root, query: "quartz", limit: 6)
    XCTAssertEqual(paths(result), expected)
    XCTAssertEqual(result["total"] as? Int, 6)
    try verifyEvidence(result)
  }

  func testEmbeddedNULQueryDoesNotBecomeAnExactTitleMatch() throws {
    let filler = String(
      repeating: "Unrelated background context occupies this passage.\n", count: 180)
    try write("Knowledge/Title.md", title: "quartz", body: filler)
    try write(
      "Knowledge/Relevant.md", title: "Observations",
      body: String(repeating: "quartz suffix ", count: 40))
    let result = try engine.search(root, query: "quartz\u{0}suffix", limit: 1)
    XCTAssertEqual(paths(result), ["Knowledge/Relevant.md"])
    try verifyEvidence(result)
  }

  func testMultipleEscapedExcerptsShareOnePayloadCap() throws {
    for suffix in ["A", "B", "C", "D", "E", "F"] {
      let body = (0..<18).map {
        "quartz \(suffix) \($0) \"quoted\" \\ path\tcontrol\u{1} café 😀 "
          + String(repeating: "context ", count: 4)
      }.joined(separator: "\n")
      try write("Knowledge/\(suffix).md", title: "Reference \(suffix)", body: body)
    }
    let result = try engine.search(root, query: "quartz", limit: 6)
    XCTAssertEqual(result["total"] as? Int, 6)
    XCTAssertGreaterThan(paths(result).count, 1)
    XCTAssertEqual((result["coverage"] as? JSONObject)?["truncated"] as? Bool, true)
    try verifyEvidence(result)
  }

  func testFormatThreeConflictedNoteIsExcludedAfterPreviouslyIndexed() throws {
    let contested = try write("Knowledge/Contested.md", title: "Contested", body: "quartz original")
    let stable = try write("Knowledge/Stable.md", title: "Stable", body: "quartz stable")
    try atomic(
      root.appendingPathComponent(".orbit/vault.json"),
      encode(["schema": 1, "id": UUID().uuidString.lowercased(), "data_format": 3]))
    _ = try engine.replicationSeed(
      root, files: ["Knowledge/Contested.md": contested, "Knowledge/Stable.md": stable])
    let initial = try engine.search(root, query: "quartz")
    XCTAssertEqual(Set(paths(initial)), Set(["Knowledge/Contested.md", "Knowledge/Stable.md"]))
    let peer = base.appendingPathComponent("peer")
    try FileManager.default.copyItem(at: root, to: peer)
    for (folder, suffix) in [(root!, "local"), (peer, "remote")] {
      _ = try engine.replicationCommit(
        folder,
        writes: [
          [
            "path": "Knowledge/Contested.md", "before": contested,
            "after": contested.replacingOccurrences(
              of: "quartz original", with: "quartz " + suffix),
            "reason": "Concurrent fixture update",
          ]
        ])
    }
    let commits = peer.appendingPathComponent(".orbit/commits")
    for commit in try FileManager.default.contentsOfDirectory(
      at: commits, includingPropertiesForKeys: nil)
    {
      try atomic(
        root.appendingPathComponent(".orbit/commits/" + commit.lastPathComponent),
        Data(contentsOf: commit))
    }
    let result = try engine.search(root, query: "quartz")
    XCTAssertEqual(paths(result), ["Knowledge/Stable.md"])
    XCTAssertEqual(result["total"] as? Int, 1)
    XCTAssertEqual((result["sync"] as? JSONObject)?["status"] as? String, "conflicted")
    try verifyEvidence(result)
  }

}
