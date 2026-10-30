import Foundation
import XCTest
@testable import OrbitCore

final class FormattingMigrationTests: XCTestCase {
    private func workspace() throws -> (URL, OrbitEngine) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-migration-tests-" + UUID().uuidString)
        let root = base.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (root, OrbitEngine(configURL: base.appendingPathComponent("config.json"), cacheURL: base.appendingPathComponent("cache"), stateURL: base.appendingPathComponent("state")))
    }

    private func put(_ root: URL, _ path: String, _ text: String) throws { try atomic(safe(root, path), Data(text.utf8)) }
    private func marker(_ root: URL, format: Int) throws {
        try atomic(safe(root, ".orbit/vault.json"), encode(["schema": 1, "id": "e72e3fac-7ccf-4b0f-814f-7ddde9350b9a", "data_format": format, "orbit_version": "0.5.0", "custom": ["retain": true]]))
    }

    func testUUID5MatchesPythonNamespaceAlgorithm() {
        XCTAssertEqual(formattingUUID5(UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!, "python.org"), "886313e1-3b8a-5372-9b90-0c9aee199e5d")
    }

    func testFormattingPreservesExactBodyBytesAndStableIDs() throws {
        let (root, engine) = try workspace()
        try marker(root, format: 1)
        for body in ["", "# Plain", "# Plain\r\n\r\nBody\r\n", "# Mixed\r\nA\nB\rC", "\u{FEFF}# BOM\n"] {
            try put(root, "plain.md", body)
            let plan: JSONObject = ["changes": [["path": "plain.md", "expected_sha256": digest(Data(body.utf8)), "metadata": ["title": "Existing notes", "type": "concept", "summary": "Notes already written."]]]]
            let (output, receipts) = try engine.formattingPrepare(root, plan: plan)
            let after = ((output["changes"] as! [JSONObject])[0]["content"] as! String)
            XCTAssertEqual(try Data(contentsOf: safe(root, "plain.md")), Data(body.utf8))
            XCTAssertTrue(after.hasSuffix(body.trimmingPrefixBOM()))
            XCTAssertEqual(after.hasPrefix("\u{FEFF}"), body.hasPrefix("\u{FEFF}"))
            XCTAssertEqual(receipts[0]["body_sha256"] as? String, digest(Data(body.trimmingPrefixBOM().utf8)))
            XCTAssertEqual(receipts[0]["after_sha256"] as? String, digest(Data(after.utf8)))
            XCTAssertEqual(metadata(after)["id"] as? String, formattingUUID5(UUID(uuidString: "e72e3fac-7ccf-4b0f-814f-7ddde9350b9a")!, "plain.md"))
            try put(root, "plain.md", after)
            let rerun: JSONObject = ["changes": [["path": "plain.md", "expected_sha256": digest(Data(after.utf8)), "metadata": JSONObject()]]]
            let (second, secondReceipts) = try engine.formattingPrepare(root, plan: rerun)
            XCTAssertEqual((second["changes"] as! [JSONObject])[0]["content"] as? String, after)
            XCTAssertTrue((secondReceipts[0]["added"] as! [String: String]).isEmpty)
        }
    }

    func testFormattingPreservesUnknownBlocksAndMixedHeaderEndings() throws {
        let header = "---\r\nid: stable-user-id\ncustom:\r\n  nested:\n    - one\r\n    - two\ntext: |\r\n  many lines\n  title: is opaque\r\nlist:\n  - nested: value\r\n---"
        let raw = Data(("\u{FEFF}" + header + "\r\n# Body\nNo final newline").utf8)
        let result = try formattingHeader(raw)
        XCTAssertEqual(result.bom, "\u{FEFF}")
        XCTAssertEqual(result.frontmatter, header + "\r\n")
        XCTAssertEqual(result.body, "# Body\nNo final newline")
        XCTAssertEqual(result.fields, ["id": "stable-user-id"])
        XCTAssertEqual(result.newline, "\r\n")
    }

    func testAmbiguousHeadersRefuse() {
        let invalid = ["---\ntitle: x", "---", "--- \ntitle: x\n---\n", "---\ntitle: []\n---\n", "---\nid: null\n---\n", "---\nsummary: |\n  text\n---\n", "---\ncustom: x\ncustom: y\n---\n", "---\ntitle: x\n  continuation\n---\n", "---\n\"title\": x\n---\n", "---\ntitle: false\n---\n", "---\nid: 123\n---\n", "---\ntitle: \"broken\n---\n", "---\ntitle: [broken\n---\n", "---\ntitle: \n---\n", "---\ntitle: x # inline comment\n---\n"]
        for input in invalid { XCTAssertThrowsError(try formattingHeader(Data(input.utf8)), input) }
    }

    func testRequiredMetadataRejectsEveryLineSeparator() throws {
        for separator in ["\n", "\r", "\u{B}", "\u{C}", "\u{1C}", "\u{1D}", "\u{1E}", "\u{85}", "\u{2028}", "\u{2029}", "\0"] {
            let string = "Alpha" + separator + "Beta"
            let quoted = String(data: try JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed]), encoding: .utf8)!
            XCTAssertThrowsError(try formattingScalar(quoted))
        }
    }

    func testFormattingRefusesChangedAndUnsafeTargets() throws {
        let (root, engine) = try workspace()
        try marker(root, format: 1)
        try put(root, "plain.md", "Original")
        let change: JSONObject = ["path": "plain.md", "expected_sha256": digest(Data("Original".utf8)), "metadata": ["title": "Title", "type": "concept", "summary": "Summary"]]
        try put(root, "plain.md", "Human edit")
        XCTAssertThrowsError(try engine.formattingPrepare(root, plan: ["changes": [change]]))
        for path in ["../outside.md", "/outside.md", "ORBIT.md", ".orbit/private.md", "Sources/assets/original.md", "./plain.md", "plain.txt"] {
            var changed = change; changed["path"] = path
            XCTAssertThrowsError(try engine.formattingPrepare(root, plan: ["changes": [changed]]), path)
        }
        XCTAssertEqual(try String(contentsOf: safe(root, "plain.md"), encoding: .utf8), "Human edit")
    }

    func testSchemaDefaultsAndCustomStrictValidation() throws {
        let (root, engine) = try workspace()
        try marker(root, format: 2)
        let templates = try engine.schemaBootstrap(root)
        XCTAssertEqual(templates.count, 7)
        for (path, text) in templates { try put(root, path, text) }
        XCTAssertTrue(try engine.schemaBootstrap(root).isEmpty)
        var concept = try String(contentsOf: safe(root, "Schemas/Concept.md"), encoding: .utf8)
        concept = concept.replacingOccurrences(of: "validation: \"warn\"", with: "validation: \"strict\"").replacingOccurrences(of: "required_sections: []", with: "required_sections: [\"Evidence\"]")
        try put(root, "Schemas/Concept.md", concept)
        let note: JSONObject = ["path": "Knowledge/Draft.md", "text": "# Draft\n", "meta": ["type": "concept"]]
        let warnings = try engine.schemaWarnings(root, notes: [note])
        XCTAssertTrue(warnings.contains { $0["message"] as? String == "Missing required section: Evidence" && $0["severity"] as? String == "error" })
    }

    func testFencedHeadingsDoNotSatisfySchema() {
        XCTAssertEqual(schemaHeadings("# Real\n```md\n## Fake\n```\n### End ###\n"), Set(["real", "end"]))
    }

    func testDuplicateSchemaTypesRefuseDefinitions() throws {
        let (root, engine) = try workspace()
        try marker(root, format: 2)
        for (path, text) in try engine.schemaBootstrap(root) { try put(root, path, text) }
        try put(root, "Schemas/Duplicate.md", String(contentsOf: safe(root, "Schemas/Concept.md"), encoding: .utf8))
        let report = try engine.schemaCheck(root)
        let findings = report["warnings"] as! [JSONObject]
        XCTAssertEqual(findings.filter { ($0["message"] as? String)?.hasPrefix("Duplicate schema_for concept:") == true }.count, 2)
    }

    func testMigrationRewritesLinksPreservesCodeAndMetadata() throws {
        let mapping = ["Project.md": "Projects/Garden/Overview.md", "Decision.md": "Projects/Garden/Decisions/Decision.md", "Asset.pdf": "Asset.pdf"]
        let identities: [String: Set<String>] = ["project": ["Project.md"], "decision": ["Decision.md"]]
        let input = "---\nid: stable\n---\n# Decision\n[[Project#Context|Garden]]\n[Project](Project.md#Context)\n[Asset](Asset.pdf)\n`[[Project]]`\n```md\n[[Project]]\n```\n"
        let output = try migrationRewrite(input, old: "Decision.md", new: mapping["Decision.md"]!, mapping: mapping, identities: identities)
        XCTAssertTrue(output.hasPrefix("---\nid: stable\n---\n"))
        XCTAssertTrue(output.contains("[[Projects/Garden/Overview#Context|Garden]]"))
        XCTAssertTrue(output.contains("[Project](../Overview.md#Context)"))
        XCTAssertTrue(output.contains("[Asset](../../../Asset.pdf)"))
        XCTAssertTrue(output.contains("`[[Project]]`"))
        XCTAssertTrue(output.contains("```md\n[[Project]]\n```"))
    }

    func testMigrationRefusesMetadataRewritingAndAmbiguousLinks() {
        let mapping = ["old.md": "Knowledge/old.md"]
        XCTAssertThrowsError(try migrationRewrite("---\ncustom: old.md\n---\nBody", old: "old.md", new: "Knowledge/old.md", mapping: mapping, identities: [:]))
        XCTAssertThrowsError(try migrationRewrite("[[duplicate]]", old: "old.md", new: "Knowledge/old.md", mapping: mapping, identities: ["duplicate": ["a.md", "b.md"]]))
        XCTAssertThrowsError(try migrationRewrite("<a href='old.md'>Old</a>", old: "old.md", new: "Knowledge/old.md", mapping: mapping, identities: [:]))
    }

    func testFormatTwoToThreeExactBytesRepeatRollbackAndConflicts() throws {
        let (root, engine) = try workspace()
        try marker(root, format: 2)
        for (path, text) in try engine.schemaBootstrap(root) { try put(root, path, text) }
        let exact = "\u{FEFF}---\r\nid: exact\r\ntitle: Exact\r\ntype: knowledge\r\nsummary: Original\r\ncustom:\r\n  nested: yes\r\n---\r\nBody\r\n"
        try put(root, "Knowledge/Exact.md", exact)
        try atomic(safe(root, "Sources/assets/original.bin"), Data([0, 255, 1]))
        let before = try engine.migrationSnapshot(root)
        let plan = try engine.migrate(root)
        XCTAssertEqual(try engine.migrationSnapshot(root), before)
        let result = try engine.migrate(root, action: "apply", planID: plan["plan_id"] as? String)
        XCTAssertEqual(result["verified"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: safe(root, "Knowledge/Exact.md")), Data(exact.utf8))
        XCTAssertEqual(schemaInteger(try readJSON(safe(root, ".orbit/vault.json"))["data_format"]), 3)
        XCTAssertEqual(try engine.migrate(root)["status"] as? String, "unchanged")
        try put(root, "Knowledge/Exact.md", "Human change")
        let changed = try engine.migrationSnapshot(root)
        XCTAssertThrowsError(try engine.migrate(root, action: "rollback", operation: result["operation"] as? String))
        XCTAssertEqual(try engine.migrationSnapshot(root), changed)
        try put(root, "Knowledge/Exact.md", exact)
        _ = try engine.migrate(root, action: "rollback", operation: result["operation"] as? String)
        XCTAssertEqual(try engine.migrationSnapshot(root), before)
        _ = try engine.migrate(root, action: "rollback", operation: result["operation"] as? String)
        XCTAssertEqual(try engine.migrationSnapshot(root), before)
    }

    func testFormatOneRequiresExplicitRouteAndFutureFormatsRefuse() throws {
        let (root, engine) = try workspace()
        try marker(root, format: 1)
        XCTAssertThrowsError(try engine.migrate(root))
        try marker(root, format: 4)
        XCTAssertThrowsError(try engine.migrationEnsureWritable(root))
        try atomic(safe(root, ".orbit/vault.json"), encode(["id": UUID().uuidString, "data_format": 2, "orbit_version": "10.0.0"]))
        XCTAssertThrowsError(try engine.migrationEnsureWritable(root))
    }

    func testFormatTwoMigrationMatchesFrozenPythonPlanHashesAndMarkerBytes() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/compatibility/migration-format2.json")
        let fixture = try readJSON(fixtureURL)
        let (root, engine) = try workspace()
        for (path, text) in fixture["inputs"] as! [String: String] { try put(root, path, text) }
        let expected = fixture["plan"] as! JSONObject
        let plan = try engine.migrate(root)
        XCTAssertEqual(plan["plan_id"] as? String, expected["plan_id"] as? String)
        let result = try engine.migrate(root, action: "apply", planID: plan["plan_id"] as? String)
        XCTAssertEqual(result["verified"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: safe(root, ".orbit/vault.json")), Data((fixture["marker_after"] as! String).utf8))
        let seedHistory = fixture["seed_history"] as! [String: String]
        for (path, hash) in seedHistory { XCTAssertEqual(digest(try Data(contentsOf: safe(root, path))), hash) }
    }

    func testFormatOneMigrationMatchesPythonLinkRewritingAndExactBackups() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/compatibility/migration-format1.json")
        let fixture = try readJSON(fixtureURL)
        let (root, engine) = try workspace()
        for (path, text) in fixture["inputs"] as! [String: String] { try put(root, path, text) }
        let snapshot = try engine.migrationSnapshot(root)
        let expected = fixture["plan"] as! JSONObject
        let plan = try engine.migrate(root, targetVersion: "0.5.0")
        XCTAssertEqual(plan["plan_id"] as? String, expected["plan_id"] as? String)
        XCTAssertEqual(try engine.migrationSnapshot(root), snapshot)
        let result = try engine.migrate(root, action: "apply", targetVersion: "0.5.0", planID: plan["plan_id"] as? String)
        for write in fixture["writes"] as! [JSONObject] {
            let url = try safe(root, write["path"] as! String)
            if let text = write["after"] as? String { XCTAssertEqual(try Data(contentsOf: url), Data(text.utf8)) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
        }
        _ = try engine.migrate(root, action: "rollback", targetVersion: "0.5.0", operation: result["operation"] as? String)
        XCTAssertEqual(try engine.migrationSnapshot(root), snapshot)
    }
}
