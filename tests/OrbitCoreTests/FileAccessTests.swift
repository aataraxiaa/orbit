import Foundation
import XCTest

@testable import OrbitCore

private final class RecordingFileAccess: OrbitFileAccess {
  struct Call {
    let url: URL
    let mode: OrbitFileAccessMode
  }
  var calls: [Call] = []
  var deny: ((URL, OrbitFileAccessMode) -> Bool)?
  var redirected: [String: URL] = [:]
  func coordinate(_ url: URL, mode: OrbitFileAccessMode, body: (URL) throws -> Void) throws {
    calls.append(Call(url: url, mode: mode))
    if deny?(url, mode) == true { throw OrbitError("Access revoked for disposable test folder") }
    try body(redirected[url.path] ?? url)
  }
}

final class FileAccessTests: XCTestCase {
  var base: URL!
  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "orbit-access-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }

  func testRealExecutionCoordinatesPublicAndHiddenFiles() throws {
    let access = RecordingFileAccess()
    let root = base.appendingPathComponent("folder")
    let engine = OrbitEngine(
      configURL: base.appendingPathComponent("config.json"),
      cacheURL: base.appendingPathComponent("cache"),
      stateURL: base.appendingPathComponent("state"), fileAccess: access)
    _ = try engine.execute(
      "setup", arguments: ["path": root.path, "name": "Disposable", "create": true])
    let content =
      "---\nid: garden\ntitle: Garden\ntype: concept\nsummary: Lavender\n---\n# Garden\n\nLavender thrives.\n"
    _ = try engine.execute(
      "apply",
      arguments: [
        "orbit": "Disposable",
        "plan": [
          "request_id": "a4faef46-1af0-418a-adf1-8834017e1472",
          "changes": [
            [
              "path": "Knowledge/Garden.md", "content": content, "reason": "Requested save",
              "expected_sha256": NSNull(),
            ]
          ],
        ],
      ])
    let read = try engine.execute(
      "read", arguments: ["orbit": "Disposable", "path": "Knowledge/Garden.md"])
    XCTAssertEqual(read["sha256"] as? String, digest(Data(content.utf8)))
    XCTAssertTrue(
      access.calls.contains { $0.url.path.hasSuffix("Knowledge/Garden.md") && $0.mode == .write })
    XCTAssertTrue(
      access.calls.contains { $0.url.path.hasSuffix("Knowledge/Garden.md") && $0.mode == .read })
    XCTAssertTrue(
      access.calls.contains { $0.url.path.contains(".orbit/commits/") && $0.mode == .write })
    XCTAssertTrue(
      access.calls.contains { $0.url.path.hasSuffix("/.orbit/commits") && $0.mode == .read })
    XCTAssertTrue(
      access.calls.contains { $0.url.path.hasSuffix(".orbit/vault.json") && $0.mode == .read })
    XCTAssertTrue(
      access.calls.contains { $0.url.path.hasSuffix("/write.lock") && $0.mode == .write })
  }

  func testRevokedAccessFailsInsteadOfReportingMissingEvidence() throws {
    let access = RecordingFileAccess()
    let root = base.appendingPathComponent("folder")
    let engine = OrbitEngine(
      configURL: base.appendingPathComponent("config.json"),
      cacheURL: base.appendingPathComponent("cache"),
      stateURL: base.appendingPathComponent("state"), fileAccess: access)
    _ = try engine.execute(
      "setup", arguments: ["path": root.path, "name": "Disposable", "create": true])
    access.deny = { url, _ in url.path.hasPrefix(root.path + "/") }
    XCTAssertThrowsError(
      try engine.execute("read", arguments: ["orbit": "Disposable", "path": "ORBIT.md"])
    ) {
      XCTAssertTrue(String(describing: $0).contains("Access revoked"))
    }
    XCTAssertThrowsError(
      try engine.execute("search", arguments: ["orbit": "Disposable", "query": "notes"]))
  }

  func testAccessorURLAndScopeRestorationAreHonored() throws {
    let requested = base.appendingPathComponent("requested.txt")
    let provided = base.appendingPathComponent("provider.txt")
    try Data("Delivered bytes".utf8).write(to: provided)
    let access = RecordingFileAccess()
    access.redirected[requested.path] = provided
    let read = try withOrbitFileAccess(access) { try readData(requested) }
    XCTAssertEqual(String(decoding: read, as: UTF8.self), "Delivered bytes")
    let count = access.calls.count
    _ = try readData(provided)
    XCTAssertEqual(access.calls.count, count)
    access.deny = { _, _ in true }
    XCTAssertThrowsError(try withOrbitFileAccess(access) { try readData(requested) })
    _ = try readData(provided)
    XCTAssertEqual(access.calls.count, count + 1)
  }

  func testAtomicWriteAndDeletionUseProvidedURL() throws {
    let requested = base.appendingPathComponent("requested.txt")
    let provided = base.appendingPathComponent("provider.txt")
    let access = RecordingFileAccess()
    access.redirected[requested.path] = provided
    try withOrbitFileAccess(access) { try atomic(requested, Data("Exact approved bytes".utf8)) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: requested.path))
    XCTAssertEqual(try Data(contentsOf: provided), Data("Exact approved bytes".utf8))
    try withOrbitFileAccess(access) { try removeFile(at: requested) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: provided.path))
    XCTAssertEqual(access.calls.map { $0.mode }, [.write, .delete])
  }
}
