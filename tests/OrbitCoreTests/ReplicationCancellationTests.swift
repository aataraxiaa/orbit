import Foundation
import XCTest

@testable import OrbitCore

private struct CancelReplicaAccess: OrbitFileAccess {
  let shouldCancel: (URL, OrbitFileAccessMode) -> Bool
  func coordinate(_ url: URL, mode: OrbitFileAccessMode, body: (URL) throws -> Void) throws {
    if shouldCancel(url, mode) { throw CancellationError() }
    try body(url)
  }
}

final class ReplicationCancellationTests: XCTestCase {
  private var base: URL!
  private var root: URL!
  private var engine: OrbitEngine!
  private let original =
    "---\nid: a\ntitle: A\ntype: knowledge\nsummary: Fixture\n---\nOriginal bytes\n"
  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "orbit-replication-cancel-" + UUID().uuidString)
    root = base.appendingPathComponent("folder")
    engine = OrbitEngine(
      configURL: base.appendingPathComponent("config.json"),
      cacheURL: base.appendingPathComponent("cache"), stateURL: base.appendingPathComponent("state")
    )
    try atomic(
      root.appendingPathComponent(".orbit/vault.json"),
      encode(["id": "d070a43d-ffb6-4af5-a8c7-f62bd812e581", "data_format": 3]))
    try atomic(root.appendingPathComponent("A.md"), Data(original.utf8))
    _ = try engine.replicationSeed(root, files: ["A.md": original])
  }
  override func tearDownWithError() throws {
    if let base { try FileManager.default.removeItem(at: base) }
  }
  private func assertCancellation(_ access: CancelReplicaAccess) throws {
    XCTAssertThrowsError(try withOrbitFileAccess(access) { try engine.replicationInspect(root) }) {
      error in
      XCTAssertTrue(
        error is CancellationError,
        "Cancellation must propagate without becoming invalid history: \(error)")
    }
    XCTAssertEqual(try engine.replicationInspect(root)["status"] as? String, "ready")
  }
  func testCancelledIdentityReadDoesNotBecomeInvalidHistory() throws {
    try assertCancellation(
      CancelReplicaAccess { url, mode in mode == .read && url.lastPathComponent == "vault.json" })
  }
  func testCancelledCommitReadDoesNotBecomeInvalidHistory() throws {
    try assertCancellation(
      CancelReplicaAccess { url, mode in
        mode == .read && url.path.contains("/.orbit/commits/") && url.pathExtension == "json"
      })
  }
  func testCancelledObservationReadDoesNotBecomeInvalidEvidence() throws {
    try atomic(root.appendingPathComponent("A.md"), Data((original + "Editor bytes\n").utf8))
    _ = try engine.replicationReconcile(root)
    let access = CancelReplicaAccess { url, mode in
      mode == .read && url.path.contains("/.orbit/observations/") && url.pathExtension == "json"
    }
    XCTAssertThrowsError(try withOrbitFileAccess(access) { try engine.replicationInspect(root) }) {
      XCTAssertTrue($0 is CancellationError)
    }
    XCTAssertEqual(try engine.replicationInspect(root)["status"] as? String, "conflicted")
  }
  func testCancellationAfterAcceptanceRetainsDurableReceiptAndRecovers() throws {
    let changed = original + "Accepted new bytes\n"
    let request = "99999999-0000-4000-8000-000000000001"
    let writes: [JSONObject] = [
      ["path": "A.md", "before": original, "after": changed, "reason": "cancellation fixture"]
    ]
    let access = CancelReplicaAccess { url, mode in
      mode == .write && url.lastPathComponent == "A.md"
    }
    let receipt = try withOrbitFileAccess(access) {
      try engine.replicationCommit(
        root, writes: writes, requestID: request, requestDigest: "exact cancelled projection")
    }
    XCTAssertEqual(receipt["status"] as? String, "committed")
    XCTAssertEqual(receipt["durability"] as? String, "local")
    XCTAssertEqual(receipt["verified"] as? Bool, false)
    XCTAssertEqual((receipt["sync"] as! JSONObject)["status"] as? String, "interrupted")
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("A.md")), Data(original.utf8))
    let retry = try engine.replicationRetry(
      root, requestID: request, requestDigest: "exact cancelled projection")!
    XCTAssertEqual(retry["verified"] as? Bool, true)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("A.md")), Data(changed.utf8))
    XCTAssertEqual(
      (try engine.replicationHistory(root, path: "A.md")["revisions"] as! [JSONObject]).count, 2)
  }
}
