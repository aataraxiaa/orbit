import Foundation
import XCTest

@testable import OrbitCore

final class RetrievalServiceTests: XCTestCase {
  func testRetainedQueriesSurviveUnavailableSourceAndRestart() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("source")
    let id = UUID().uuidString.lowercased()
    try atomic(root.appendingPathComponent(".orbit/vault.json"), encode(["schema": 1, "id": id, "data_format": 2]))
    try atomic(root.appendingPathComponent("Knowledge/Test.md"), Data("# Orchard\n\nUse padded crates for pears.\n".utf8))
    let engine = OrbitEngine(configURL: base.appendingPathComponent("config.json"), cacheURL: base.appendingPathComponent("cache"), stateURL: base.appendingPathComponent("state"))
    let retained = try engine.captureRetrievalSnapshot(root)
    let local = base.appendingPathComponent("retained")
    let service = try OrbitRetrievalService(orbitID: id, sourceBinding: "fixture-link", localDirectory: local)
    try await service.refresh { retained }
    try FileManager.default.removeItem(at: root)
    do { try await service.refresh { throw OrbitError("Fixture provider unavailable") } }
    catch {}
    guard case .ready(let previous, _, let failure) = try await service.retrieve(.init(query: "pears")) else {
      return XCTFail("A failed refresh discarded usable retained evidence")
    }
    XCTAssertEqual(previous.snapshotID, retained.snapshotID)
    XCTAssertNotNil(failure)
    let reopened = try OrbitRetrievalService(orbitID: id, sourceBinding: "fixture-link", localDirectory: local)
    guard case .ready(let result, _, _) = try await reopened.retrieve(.init(query: "pears")) else {
      return XCTFail("Retained evidence was unavailable")
    }
    XCTAssertEqual(result.evidence.first?.lines.last?.text, "Use padded crates for pears.")
    XCTAssertEqual(result.freshness, "snapshot-not-current-provider")
    try await reopened.invalidate()
    guard case .unavailable = try await reopened.retrieve(.init(query: "pears")) else {
      return XCTFail("Disconnected binding exposed retained evidence")
    }
    let other = try OrbitRetrievalService(orbitID: id, sourceBinding: "other-link", localDirectory: local)
    guard case .unavailable = try await other.retrieve(.init(query: "pears")) else {
      return XCTFail("Different replica shared the retained cache")
    }
  }
}
