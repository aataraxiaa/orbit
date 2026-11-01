import Darwin
import Foundation
import XCTest

@testable import OrbitCore

private struct InspectionReadFailureAccess: OrbitFileAccess {
  enum Failure {
    case unavailable
    case cancelled
  }
  let path: String
  let failure: Failure

  func coordinate(_ url: URL, mode: OrbitFileAccessMode, body: (URL) throws -> Void) throws {
    if mode == .read && url.path == path {
      switch failure {
      case .unavailable: throw OrbitError("Disposable provider content is unavailable")
      case .cancelled: throw CancellationError()
      }
    }
    try body(url)
  }
}

final class ReplicationFreshnessTests: XCTestCase {
  private var base: URL!
  private var root: URL!
  private var engine: OrbitEngine!
  private let original =
    "---\nid: inspection-note\ntitle: Inspection note\ntype: concept\nsummary: Fixture\n---\nOriginal bytes\n"

  override func setUpWithError() throws {
    base = realURL(FileManager.default.temporaryDirectory).appendingPathComponent(
      "orbit-replication-read-inspection-" + UUID().uuidString)
    root = base.appendingPathComponent("vault")
    engine = OrbitEngine(
      configURL: base.appendingPathComponent("config.json"),
      cacheURL: base.appendingPathComponent("cache"),
      stateURL: base.appendingPathComponent("state"))
    try atomic(
      root.appendingPathComponent(".orbit/vault.json"),
      encode(["id": "7b727ac3-4f39-465d-9f13-efab4a8ccb6a", "data_format": 3]))
    try atomic(root.appendingPathComponent("A.md"), Data(original.utf8))
    _ = try engine.replicationSeed(root, files: ["A.md": original])
  }

  override func tearDownWithError() throws {
    if let base { try FileManager.default.removeItem(at: base) }
  }

  private func genesisCommit() throws -> URL {
    let commits = try FileManager.default.contentsOfDirectory(
      at: root.appendingPathComponent(".orbit/commits"), includingPropertiesForKeys: nil)
    XCTAssertEqual(commits.count, 1)
    return try XCTUnwrap(commits.first)
  }

  private func assertReady(file: StaticString = #filePath, line: UInt = #line) throws {
    let report = try engine.replicationInspect(root)
    XCTAssertEqual(report["status"] as? String, "ready", eJSON(report), file: file, line: line)
    XCTAssertTrue(eObjects(report["invalid"]).isEmpty, file: file, line: line)
  }

  func testSameLengthSameModificationTimeCommitChangeIsRevalidatedInsideOneLock() throws {
    let commit = try genesisCommit()
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: commit.path)
    let before = try Data(contentsOf: commit)
    let beforeStat = try XCTUnwrap(fileLStat(commit))
    let corrupted = Data(
      String(decoding: before, as: UTF8.self)
        .replacingOccurrences(of: "Original bytes", with: "Tampered bytes").utf8)
    XCTAssertNotEqual(corrupted, before)
    XCTAssertEqual(corrupted.count, before.count)
    try engine.withLocalLock(root) {
      try assertReady()
      try corrupted.write(to: commit)
      try FileManager.default.setAttributes(
        [.modificationDate: timestamp], ofItemAtPath: commit.path)
      let afterStat = try XCTUnwrap(fileLStat(commit))
      XCTAssertEqual(afterStat.st_size, beforeStat.st_size)
      XCTAssertEqual(afterStat.st_mtimespec.tv_sec, beforeStat.st_mtimespec.tv_sec)
      XCTAssertEqual(afterStat.st_mtimespec.tv_nsec, beforeStat.st_mtimespec.tv_nsec)
      let invalid = try engine.replicationInspect(root)
      XCTAssertEqual(invalid["status"] as? String, "invalid")
      XCTAssertTrue(
        eObjects(invalid["invalid"]).contains {
          eString($0["error"]).contains("integrity mismatch")
        })
      try before.write(to: commit)
      try assertReady()
    }
  }

  func testCurrentVaultIdentityIsCheckedOnRepeatedInspection() throws {
    let marker = root.appendingPathComponent(".orbit/vault.json")
    let before = try Data(contentsOf: marker)
    try engine.withLocalLock(root) {
      try assertReady()
      try atomic(
        marker, encode(["id": "6af8b2ad-fb0c-45d3-9228-8280343fc339", "data_format": 3]))
      let invalid = try engine.replicationInspect(root)
      XCTAssertEqual(invalid["status"] as? String, "invalid")
      XCTAssertTrue(
        eObjects(invalid["invalid"]).contains {
          eString($0["error"]).contains("different Orbit identity")
        })
      try atomic(marker, before)
      try assertReady()
    }
  }

  func testReferencedPathSymlinkIsRejectedOnRepeatedInspection() throws {
    let note = root.appendingPathComponent("A.md")
    let outside = base.appendingPathComponent("outside.md")
    try atomic(outside, Data(original.utf8))
    try engine.withLocalLock(root) {
      try assertReady()
      try FileManager.default.removeItem(at: note)
      try FileManager.default.createSymbolicLink(at: note, withDestinationURL: outside)
      do {
        let report = try engine.replicationInspect(root)
        XCTAssertEqual(report["status"] as? String, "invalid", eJSON(report))
      } catch {
        XCTAssertTrue(String(describing: error).lowercased().contains("symlink"), "\(error)")
      }
      try FileManager.default.removeItem(at: note)
      try atomic(note, Data(original.utf8))
      try assertReady()
    }
    XCTAssertEqual(try Data(contentsOf: outside), Data(original.utf8))
  }

  func testUnavailableCommitReadCannotReuseEarlierSuccess() throws {
    let commit = try genesisCommit()
    try engine.withLocalLock(root) {
      try assertReady()
      let access = InspectionReadFailureAccess(path: commit.path, failure: .unavailable)
      let invalid = try withOrbitFileAccess(access) { try engine.replicationInspect(root) }
      XCTAssertEqual(invalid["status"] as? String, "invalid")
      XCTAssertTrue(
        eObjects(invalid["invalid"]).contains {
          eString($0["error"]).contains("provider content is unavailable")
        })
      try assertReady()
    }
  }

  func testCancelledRepeatedInspectionPropagatesAndReleasesLock() throws {
    let commit = try genesisCommit()
    let access = InspectionReadFailureAccess(path: commit.path, failure: .cancelled)
    XCTAssertThrowsError(
      try engine.withLocalLock(root) {
        try assertReady()
        return try withOrbitFileAccess(access) { try engine.replicationInspect(root) }
      }
    ) {
      XCTAssertTrue($0 is CancellationError, "Cancellation became another outcome: \($0)")
    }
    try engine.withLocalLock(root) { try assertReady() }
  }

  func testAssetPresenceAndBytesAreRecheckedInsideOneLock() throws {
    let bytes = Data("Disposable original asset".utf8)
    let relative = "Sources/assets/" + digest(bytes) + ".txt"
    let asset = root.appendingPathComponent(relative)
    try atomic(asset, bytes)
    let changed = original + "\n[[" + relative + "]]\n"
    _ = try engine.replicationCommit(
      root,
      writes: [
        [
          "path": "A.md", "before": original, "after": changed, "reason": "Asset fixture",
        ]
      ])
    try engine.withLocalLock(root) {
      try assertReady()
      try FileManager.default.removeItem(at: asset)
      let missing = try engine.replicationInspect(root)
      XCTAssertEqual(missing["status"] as? String, "pending")
      XCTAssertTrue(strings(missing["blocked_paths"]).contains("A.md"))
      try atomic(asset, bytes)
      try assertReady()
      var altered = bytes
      altered[altered.startIndex] ^= 1
      try atomic(asset, altered)
      let mismatched = try engine.replicationInspect(root)
      XCTAssertEqual(mismatched["status"] as? String, "pending")
      XCTAssertTrue(
        eObjects(mismatched["pending"]).contains {
          strings($0["reasons"]).contains("asset hash mismatch " + relative)
        })
      try atomic(asset, bytes)
      try assertReady()
      let access = InspectionReadFailureAccess(path: asset.path, failure: .unavailable)
      XCTAssertThrowsError(try withOrbitFileAccess(access) { try engine.replicationInspect(root) })
      {
        XCTAssertTrue(String(describing: $0).contains("provider content is unavailable"))
      }
      try assertReady()
    }
  }
}
