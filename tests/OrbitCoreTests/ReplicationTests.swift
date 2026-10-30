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
        base = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-swift-replication-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        engine = OrbitEngine(configURL: base.appendingPathComponent("config.json"), cacheURL: base.appendingPathComponent("cache"), stateURL: base.appendingPathComponent("state"))
        a = base.appendingPathComponent("a")
        b = base.appendingPathComponent("b")
        try atomic(a.appendingPathComponent(".orbit/vault.json"), encode(["id": identity, "data_format": 3]))
        let files = ["A.md": note("a", "original A"), "B.md": note("b", "original B")]
        for (path, content) in files { try atomic(a.appendingPathComponent(path), Data(content.utf8)) }
        _ = try engine.replicationSeed(a, files: files)
        try FileManager.default.copyItem(at: a, to: b)
    }
    override func tearDownWithError() throws { if let base { try FileManager.default.removeItem(at: base) } }
    private func note(_ id: String, _ body: String) -> String { "---\nid: " + id + "\ntitle: Test\ntype: knowledge\nsummary: Test\n---\n" + body + "\n" }
    private func write(_ root: URL, _ path: String, _ after: String?) throws -> JSONObject {
        let target = root.appendingPathComponent(path)
        return ["path": path, "before": (try? String(contentsOf: target, encoding: .utf8)) as Any? ?? NSNull(), "after": after as Any? ?? NSNull(), "reason": "test"]
    }
    private func deliver(_ source: URL, _ target: URL, only: String? = nil) throws {
        for directory in ["commits", "observations"] {
            let folder = source.appendingPathComponent(".orbit/" + directory)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            for path in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                if let only, directory == "commits", path.deletingPathExtension().lastPathComponent != only { continue }
                try atomic(target.appendingPathComponent(".orbit/" + directory + "/" + path.lastPathComponent), Data(contentsOf: path))
            }
        }
    }
    func testIndependentWritesConvergeWithoutNewHistory() throws {
        _ = try engine.replicationCommit(a, writes: [write(a, "A.md", note("a", "new A"))])
        _ = try engine.replicationCommit(b, writes: [write(b, "B.md", note("b", "new B"))])
        try deliver(a, b); try deliver(b, a)
        for root in [a!, b!] {
            XCTAssertEqual(try engine.replicationReconcile(root)["status"] as? String, "ready")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("A.md")), note("a", "new A"))
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("B.md")), note("b", "new B"))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".orbit/commits").path).count, 3)
        }
        XCTAssertEqual(try canonical(engine.replicationInspect(a)), try canonical(engine.replicationInspect(b)))
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
        XCTAssertThrowsError(try engine.replicationCommit(a, writes: [write(a, "A.md", note("a", "bad merge"))]))
        var resolution = try write(a, "A.md", note("a", "resolved"))
        resolution["expected_heads"] = (state["heads"] as! JSONObject)["A.md"]!
        XCTAssertEqual(try engine.replicationCommit(a, writes: [resolution])["verified"] as? Bool, true)
        try deliver(a, b)
        XCTAssertEqual(try engine.replicationReconcile(b)["status"] as? String, "ready")
        try deliver(c, a)
        let conflicts = try engine.replicationReconcile(a)["conflicts"] as! [JSONObject]
        XCTAssertEqual((conflicts[0]["heads"] as! [String]).count, 2)
        let revisions = try engine.replicationHistory(a, path: "A.md")["revisions"] as! [JSONObject]
        XCTAssertTrue(Set(["left", "right", "late", "resolved"].map { note("a", $0) }).isSubset(of: Set(revisions.compactMap { $0["content"] as? String })))
    }
    func testExternalBytesRequireObservationAndHeads() throws {
        let edited = note("a", "external\r\nexact")
        try atomic(a.appendingPathComponent("A.md"), Data(edited.utf8))
        XCTAssertEqual(try engine.replicationInspect(a)["status"] as? String, "conflicted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.appendingPathComponent(".orbit/observations").path))
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
        let second = try engine.replicationCommit(a, writes: [write(a, "A.md", note("a", "second"))], requestID: request, requestDigest: "logical request")
        try deliver(a, b, only: second["operation"] as? String)
        XCTAssertEqual(try engine.replicationReconcile(b)["status"] as? String, "pending")
        XCTAssertThrowsError(try engine.replicationOperation(b, id: request))
        try deliver(a, b, only: first["operation"] as? String)
        XCTAssertEqual(try engine.replicationReconcile(b)["status"] as? String, "ready")
        XCTAssertEqual(try engine.replicationRetry(a, requestID: request, requestDigest: "logical request")?["operation"] as? String, request)
        XCTAssertThrowsError(try engine.replicationRetry(a, requestID: request, requestDigest: "changed"))
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
        let preview = try engine.replicationSeedPreview(a, files: ["A.md": note("a", "original A"), "B.md": note("b", "original B")])
        XCTAssertEqual(preview["operation"] as? String, "a37a039c-0b1a-5761-803a-43d1a3df9e48")
        let raw = try Data(contentsOf: a.appendingPathComponent(preview["path"] as! String))
        XCTAssertEqual(digest(raw), preview["sha256"] as? String)
        XCTAssertEqual(digest(raw), "2b06bbace8c812328f31e942d9d68c1c40ab1560e885fe9a40bd4adc16bec65a")
    }
    func testRenameRetainsHistoryAndConcurrentOldPathEditConflicts() throws {
        _ = try engine.replicationCommit(a, writes: [write(a, "A.md", nil), write(a, "New.md", note("a", "renamed"))])
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.appendingPathComponent("A.md").path))
        _ = try engine.replicationCommit(b, writes: [write(b, "A.md", note("a", "stale"))])
        try deliver(b, a)
        XCTAssertEqual(try engine.replicationReconcile(a)["blocked_paths"] as? [String], ["A.md", "New.md"])
    }
    func testAssetsHoldEntireOperationUntilDelivered() throws {
        let raw = Data("original source".utf8), hash = digest(Data("original source".utf8))
        let relative = "Sources/assets/" + hash + ".txt"
        try atomic(a.appendingPathComponent(relative), raw)
        _ = try engine.replicationCommit(a, writes: [write(a, "A.md", note("a", "[[" + relative + "]]")), write(a, "B.md", note("b", "batch"))])
        try deliver(a, b)
        XCTAssertEqual(try engine.replicationReconcile(b)["status"] as? String, "pending")
        XCTAssertEqual(try String(contentsOf: b.appendingPathComponent("B.md")), note("b", "original B"))
        try atomic(b.appendingPathComponent(relative), raw)
        XCTAssertEqual(try engine.replicationReconcile(b)["status"] as? String, "ready")
        XCTAssertEqual(try String(contentsOf: b.appendingPathComponent("B.md")), note("b", "batch"))
    }
    func testCanonicalGenesisPathHashMatchesPython() throws {
        let files = ["a10": "ten", "a2": "two", "A": "upper", "a": "lower", "é": "accent", "😀": "emoji", "Z": "last", "/": "slash", "control": "line\u{2028}paragraph\u{2029}tab\t"]
        XCTAssertEqual(digest(try canonical(files)), "1968b2021f6c765b581b0f824eb3e39f96946944a546f3443ae900c0e93feb54")
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

}
