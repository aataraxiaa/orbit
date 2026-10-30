import Foundation
import XCTest
@testable import OrbitCore

final class ReplicationByteIdentityTests: XCTestCase {
    private var base: URL!
    private var a: URL!
    private var b: URL!
    private var engine: OrbitEngine!
    private let composed = "café"
    private let decomposed = "cafe\u{0301}"
    private func note(_ id: String, _ body: String) -> String {
        "---\nid: " + id + "\ntitle: Test\ntype: knowledge\nsummary: Fixture\n---\n" + body + "\n"
    }
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-byte-identities-" + UUID().uuidString)
        a = base.appendingPathComponent("a"); b = base.appendingPathComponent("b")
        engine = OrbitEngine(configURL: base.appendingPathComponent("config.json"), cacheURL: base.appendingPathComponent("cache"), stateURL: base.appendingPathComponent("state"))
        try atomic(a.appendingPathComponent(".orbit/vault.json"), encode(["id": "d070a43d-ffb6-4af5-a8c7-f62bd812e581", "data_format": 3]))
        try atomic(a.appendingPathComponent("ORBIT.md"), Data("# Fixture\n".utf8))
        _ = try engine.replicationSeed(a, files: ["ORBIT.md": "# Fixture\n"])
    }
    override func tearDownWithError() throws { if let base { try FileManager.default.removeItem(at: base) } }
    private func write(_ root: URL, _ path: String, _ text: String) -> JSONObject {
        ["path": path, "before": (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) as Any? ?? NSNull(), "after": text, "reason": "byte identity fixture"]
    }
    private func deliver(_ source: URL, _ target: URL) throws {
        for directory in ["commits", "observations"] {
            let path = source.appendingPathComponent(".orbit/" + directory)
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            for file in try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil) {
                try atomic(target.appendingPathComponent(".orbit/" + directory + "/" + file.lastPathComponent), Data(contentsOf: file))
            }
        }
    }
    private func createBoth() throws {
        let result = try engine.replicationCommit(a, writes: [write(a, "NFC.md", note(composed, "composed original")), write(a, "NFD.md", note(decomposed, "decomposed original"))])
        XCTAssertEqual(result["verified"] as? Bool, true)
        XCTAssertEqual((result["sync"] as! JSONObject)["status"] as? String, "ready")
        XCTAssertEqual(try Data(contentsOf: a.appendingPathComponent("NFC.md")), Data(note(composed, "composed original").utf8))
        XCTAssertEqual(try Data(contentsOf: a.appendingPathComponent("NFD.md")), Data(note(decomposed, "decomposed original").utf8))
    }
    func testSingleOperationPreservesDistinctCanonicalEquivalentIDs() throws {
        try createBoth()
        let state = try engine.replicationInspect(a)
        XCTAssertEqual(state["status"] as? String, "ready")
        XCTAssertEqual((state["invalid"] as! [JSONObject]).count, 0)
        for (path, identity) in [("NFC.md", composed), ("NFD.md", decomposed)] {
            let revisions = try engine.replicationHistory(a, path: path)["revisions"] as! [JSONObject]
            XCTAssertEqual(revisions.count, 1)
            XCTAssertEqual(Data((revisions[0]["entity"] as! String).utf8), Data(("note:" + identity).utf8))
        }
    }
    func testGenesisPreservesBothHistoricallyValidIDs() throws {
        let root = base.appendingPathComponent("genesis")
        try atomic(root.appendingPathComponent(".orbit/vault.json"), encode(["id": "e070a43d-ffb6-4af5-a8c7-f62bd812e581", "data_format": 3]))
        let files = ["NFC.md": note(composed, "one"), "NFD.md": note(decomposed, "two")]
        for (path, text) in files { try atomic(root.appendingPathComponent(path), Data(text.utf8)) }
        _ = try engine.replicationSeed(root, files: files)
        XCTAssertEqual(try engine.replicationInspect(root)["status"] as? String, "ready")
    }
    func testIndependentUpdatesNeverBecomeBranchesOfTheOtherID() throws {
        try createBoth()
        try FileManager.default.copyItem(at: a, to: b)
        _ = try engine.replicationCommit(a, writes: [write(a, "NFC.md", note(composed, "composed update"))])
        _ = try engine.replicationCommit(b, writes: [write(b, "NFD.md", note(decomposed, "decomposed update"))])
        try deliver(a, b); try deliver(b, a)
        for root in [a!, b!] {
            XCTAssertEqual(try engine.replicationReconcile(root)["status"] as? String, "ready")
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("NFC.md")), Data(note(composed, "composed update").utf8))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("NFD.md")), Data(note(decomposed, "decomposed update").utf8))
            for path in ["NFC.md", "NFD.md"] { XCTAssertEqual((try engine.replicationHistory(root, path: path)["revisions"] as! [JSONObject]).count, 2) }
        }
    }
    func testExternalObservationsRemainWithTheirExactIdentity() throws {
        try createBoth()
        try atomic(a.appendingPathComponent("NFC.md"), Data(note(composed, "external composed").utf8))
        try atomic(a.appendingPathComponent("NFD.md"), Data(note(decomposed, "external decomposed").utf8))
        let state = try engine.replicationReconcile(a), conflicts = state["conflicts"] as! [JSONObject]
        XCTAssertEqual(conflicts.count, 2)
        let chosen = conflicts.first { Data(($0["entity"] as! String).utf8) == Data(("note:" + composed).utf8) }!
        var adoption = write(a, "NFC.md", note(composed, "external composed"))
        adoption["expected_heads"] = chosen["heads"]!; adoption["observations"] = chosen["observations"]!
        _ = try engine.replicationCommit(a, writes: [adoption])
        let remaining = try engine.replicationInspect(a)["conflicts"] as! [JSONObject]
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(Data((remaining[0]["entity"] as! String).utf8), Data(("note:" + decomposed).utf8))
        XCTAssertEqual((try engine.replicationHistory(a, path: "NFC.md")["observations"] as! [JSONObject]).count, 1)
        XCTAssertEqual((try engine.replicationHistory(a, path: "NFD.md")["observations"] as! [JSONObject]).count, 1)
    }
    func testCollisionRetiresOnlyExactLosingIdentity() throws {
        try FileManager.default.copyItem(at: a, to: b)
        _ = try engine.replicationCommit(a, writes: [write(a, "Same.md", note(composed, "left"))])
        _ = try engine.replicationCommit(b, writes: [write(b, "Same.md", note(decomposed, "right"))])
        try deliver(b, a)
        let state = try engine.replicationReconcile(a)
        XCTAssertEqual((state["conflicts"] as! [JSONObject]).count, 2)
        var resolution = write(a, "Same.md", note(decomposed, "chosen right"))
        resolution["expected_heads"] = (state["heads"] as! JSONObject)["Same.md"]!
        let result = try engine.replicationCommit(a, writes: [resolution])
        XCTAssertEqual(result["verified"] as? Bool, true)
        XCTAssertEqual((result["sync"] as! JSONObject)["status"] as? String, "ready")
        let revisions = try engine.replicationHistory(a, path: "Same.md")["revisions"] as! [JSONObject]
        let retired = revisions.filter { $0["retired"] as? Bool == true }
        XCTAssertEqual(retired.count, 1)
        XCTAssertEqual(Data((retired[0]["entity"] as! String).utf8), Data(("note:" + composed).utf8))
    }
    func testCanonicalEquivalentSpellingIsStillAnIdentityChange() throws {
        try createBoth()
        XCTAssertThrowsError(try engine.replicationCommit(a, writes: [write(a, "NFC.md", note(decomposed, "identity changed"))]))
        XCTAssertEqual(try engine.replicationInspect(a)["status"] as? String, "ready")
    }
}
