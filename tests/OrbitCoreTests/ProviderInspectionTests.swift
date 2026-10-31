import Darwin
import Foundation
import XCTest

@testable import OrbitCore

private final class PendingInspectionAccess: OrbitFileAccess {
  struct Call {
    let url: URL
    let mode: OrbitFileAccessMode
  }
  let root: URL
  var pendingPaths = Set<String>()
  var calls: [Call] = []
  init(root: URL) { self.root = root }
  func coordinate(_ url: URL, mode: OrbitFileAccessMode, body: (URL) throws -> Void) throws {
    calls.append(Call(url: url, mode: mode))
    let isShared = url.path == root.path || url.path.hasPrefix(root.path + "/")
    if isShared && (mode == .write || mode == .delete) {
      throw OrbitError("Shared folder is read-only")
    }
    if mode == .read && pendingPaths.contains(url.path) {
      throw OrbitError("Pending file content is unavailable")
    }
    try body(url)
  }
}

final class ProviderInspectionTests: XCTestCase {
  var base: URL!
  var root: URL!
  var note: URL!
  var pendingPNG: URL!
  private var adapter: PendingInspectionAccess!
  var engine: OrbitEngine!

  override func setUpWithError() throws {
    let temp = realpath(NSTemporaryDirectory(), nil)!
    defer { free(temp) }
    base = URL(fileURLWithPath: String(cString: temp)).appendingPathComponent(
      "orbit-provider-inspection-" + UUID().uuidString)
    root = base.appendingPathComponent("folder")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".orbit"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Sources/assets"), withIntermediateDirectories: true)
    let id = "bb77c713-c5d3-4125-b0a3-4efc6db53816"
    try atomic(
      root.appendingPathComponent(".orbit/vault.json"),
      encode(["schema": 1, "id": id, "data_format": 2, "orbit_version": "0.5.0"]))
    note = root.appendingPathComponent("Note.md")
    try atomic(
      note,
      Data(
        "---\nid: note\ntitle: Note\ntype: concept\nsummary: Available evidence\n---\n# Note\nLavender needs dry soil.\n"
          .utf8))
    pendingPNG = root.appendingPathComponent("Sources/assets/pending.png")
    try atomic(pendingPNG, Data([0x89, 0x50, 0x4e, 0x47]))
    let config = base.appendingPathComponent("config.json")
    try atomic(
      config,
      encode(["schema": 2, "orbits": ["Disposable": ["path": root.path, "vault_id": id]]]))
    adapter = PendingInspectionAccess(root: root)
    adapter.pendingPaths.insert(pendingPNG.path)
    engine = OrbitEngine(
      configURL: config, cacheURL: base.appendingPathComponent("cache"),
      stateURL: base.appendingPathComponent("state"), fileAccess: adapter)
  }

  override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }

  func testPendingExcludedPNGDoesNotBlockCatalogOrSearch() throws {
    let before = try Data(contentsOf: note)
    let catalog = try engine.execute("catalog", arguments: ["orbit": "Disposable"])
    XCTAssertEqual(catalog["total"] as? Int, 1)
    XCTAssertEqual(eObjects(catalog["entries"]).map { eString($0["path"]) }, ["Note.md"])
    let search = try engine.execute(
      "search", arguments: ["orbit": "Disposable", "query": "lavender"])
    XCTAssertEqual(eObjects(search["results"]).map { eString($0["path"]) }, ["Note.md"])
    let pngCalls = adapter.calls.filter { $0.url.path == pendingPNG.path }
    XCTAssertFalse(pngCalls.isEmpty)
    XCTAssertTrue(pngCalls.allSatisfy { $0.mode == .inspect })
    XCTAssertFalse(
      adapter.calls.contains {
        ($0.url.path == root.path || $0.url.path.hasPrefix(root.path + "/"))
          && ($0.mode == .write || $0.mode == .delete)
      })
    XCTAssertEqual(try Data(contentsOf: note), before)
  }

  func testActualPendingContentReadStillFails() throws {
    XCTAssertThrowsError(try withOrbitFileAccess(adapter) { try readData(pendingPNG) }) {
      XCTAssertEqual(String(describing: $0), "Pending file content is unavailable")
    }
    adapter.pendingPaths.insert(note.path)
    XCTAssertThrowsError(
      try engine.execute("read", arguments: ["orbit": "Disposable", "path": "Note.md"])
    ) {
      XCTAssertEqual(String(describing: $0), "Pending file content is unavailable")
    }
    XCTAssertThrowsError(
      try engine.execute("catalog", arguments: ["orbit": "Disposable"]))
  }

  func testInspectionPreservesMissingAndSymlinkMetadataWithoutReadingContents() throws {
    let missing = root.appendingPathComponent("missing.md")
    let link = root.appendingPathComponent("link.md")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: note)
    adapter.pendingPaths.insert(note.path)
    try withOrbitFileAccess(adapter) {
      XCTAssertFalse(try fileExists(atPath: missing.path))
      XCTAssertNil(try fileLStat(missing))
      XCTAssertTrue(try fileExists(atPath: link.path))
      XCTAssertTrue(try fileIsSymbolicLink(link))
      XCTAssertEqual(
        try fileAttributes(atPath: link.path)[.type] as? FileAttributeType, .typeSymbolicLink)
      XCTAssertThrowsError(try safe(root, "link.md"))
    }
    XCTAssertTrue(adapter.calls.allSatisfy { $0.mode == .inspect })
  }
}
