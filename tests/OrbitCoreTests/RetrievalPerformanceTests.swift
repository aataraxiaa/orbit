import XCTest

@testable import OrbitCore

/// Opt-in measurements use only generated notes and device-local temporary storage.
final class RetrievalPerformanceTests: XCTestCase {
  func testRetrievalTiming() throws {
    guard ProcessInfo.processInfo.environment["ORBIT_BENCHMARK"] == "1" else {
      throw XCTSkip("Set ORBIT_BENCHMARK=1 for generated-vault timing")
    }
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "orbit-perf-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("vault")
    let engine = OrbitEngine(
      configURL: base.appendingPathComponent("config.json"),
      cacheURL: base.appendingPathComponent("cache"), stateURL: base.appendingPathComponent("state")
    )
    try atomic(
      root.appendingPathComponent(".orbit/vault.json"),
      encode([
        "schema": 1, "id": UUID().uuidString.lowercased(), "data_format": 2,
        "orbit_version": "0.5.0",
      ]))
    let count = Int(ProcessInfo.processInfo.environment["ORBIT_BENCHMARK_NOTES"] ?? "500") ?? 500
    var files: [String: String] = [:]
    for n in 0..<count {
      let body = (0..<12).map {
        "## Section \($0)\n\nProject planning includes delivery and review. Note \(n) tracks milestone \($0).\n\n"
      }.joined()
      let text =
        "---\nid: \"note-\(n)\"\ntitle: \"Project \(n)\"\ntype: \"concept\"\nsummary: \"Project planning and review\"\n---\n# Project \(n)\n\n"
        + body
      files["Knowledge/Note\(n).md"] = text
      try atomic(root.appendingPathComponent("Knowledge/Note\(n).md"), Data(text.utf8))
    }
    let format3 = ProcessInfo.processInfo.environment["ORBIT_BENCHMARK_FORMAT"] == "3"
    if format3 {
      try atomic(
        root.appendingPathComponent(".orbit/vault.json"),
        encode([
          "schema": 1, "id": UUID().uuidString.lowercased(), "data_format": 3,
          "orbit_version": "0.6.0",
        ]))
      _ = try engine.replicationSeed(root, files: files)
    }
    print("ORBIT_PERF fixture notes=\(count) passages=\(count * 13) format=\(format3 ? 3 : 2)")
    func timed(_ label: String, _ work: () throws -> Void) rethrows {
      let start = DispatchTime.now().uptimeNanoseconds
      try work()
      let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
      print("ORBIT_PERF \(label) \(String(format: "%.3f", ms)) ms")
    }
    try timed("cold-search") {
      let result = try engine.search(root, query: "project planning")
      XCTAssertEqual(result["total"] as? Int, count)
      XCTAssertFalse(eObjects(result["results"]).isEmpty)
    }
    for run in 0..<5 {
      if run == 0 {
        try timed("no-match-\(run)") {
          XCTAssertTrue(
            eObjects(try engine.search(root, query: "absentuniqueterm")["results"]).isEmpty)
        }
        try timed("single-result-\(run)") {
          let result = try engine.search(root, query: "project planning", limit: 1)
          XCTAssertEqual(result["total"] as? Int, count)
          XCTAssertEqual(eObjects(result["results"]).count, 1)
        }
      }
      try timed("warm-search-\(run)") {
        let result = try engine.search(root, query: "project planning")
        XCTAssertEqual(result["total"] as? Int, count)
        let rows = eObjects(result["results"])
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
          let path = eString(row["path"])
          XCTAssertEqual(row["sha256"] as? String, files[path].map { digest(Data($0.utf8)) })
          XCTAssertFalse(eObjects(row["snippets"]).isEmpty)
        }
        let evidence: JSONObject = [
          "total": result["total"]!, "results": rows, "coverage": result["coverage"]!,
        ]
        print("ORBIT_PERF evidence \(try digest(canonical(evidence)))")
        XCTAssertEqual((result["freshness"] as? JSONObject)?["reparsed"] as? Int, 0)
      }
      if run == 0 {
        if format3 {
          try timed("reconcile-\(run)") {
            XCTAssertEqual(try engine.replicationReconcile(root)["status"] as? String, "ready")
          }
        }
        try timed("inventory-\(run)") {
          XCTAssertEqual(try engine.retrievalInventory(root).count, count)
        }
        try timed("refresh-\(run)") {
          XCTAssertEqual(try engine.retrievalRefresh(root)["reparsed"] as? Int, 0)
        }
      }
    }
  }
}
