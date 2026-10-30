import Foundation
import XCTest
@testable import OrbitCore

final class FormattingMigrationTests: XCTestCase {
    private func fixture(_ name: String) throws -> JSONObject {
        try readJSON(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/compatibility/" + name + ".json"))
    }

    private func replay(_ name: String) throws -> (URL, OrbitEngine, JSONObject) {
        let fixture = try fixture(name)
        let (root, engine) = try workspace()
        for (path, text) in fixture["inputs"] as! [String: String] { try put(root, path, text) }
        return (root, engine, fixture)
    }
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

    func testSchemaIntegersRejectBooleanAndFloatingPointValues() {
        XCTAssertNil(schemaInteger(true))
        XCTAssertNil(schemaInteger(1.0))
        XCTAssertNil(schemaInteger(2.5))
        XCTAssertEqual(schemaInteger(1), 1)
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

    func testQuotedMetadataPreservesLeadingBOMInsideString() throws {
        XCTAssertEqual(try formattingScalar("\"\u{FEFF}Existing title\""), "\u{FEFF}Existing title")
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
        let fixtureNote = (fixture["inputs"] as! [String: String])["Knowledge/Exact.md"]!
        XCTAssertEqual(fixtureNote.unicodeScalars.first?.value, 0xFEFF, "Fixture JSON must preserve a BOM inside note content")
        for (path, text) in fixture["inputs"] as! [String: String] { try put(root, path, text) }
        let noteBytes = try Data(contentsOf: safe(root, "Knowledge/Exact.md"))
        XCTAssertEqual(Array(noteBytes.prefix(3)), [0xEF, 0xBB, 0xBF], "Replay must preserve raw BOM bytes")
        let preserved = try migrationRead(root, "Knowledge/Exact.md")!
        XCTAssertEqual(preserved.unicodeScalars.first?.value, 0xFEFF, "Migration snapshots must preserve BOM bytes")
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

    func testMigrationStalePlanRefusesAndPreservesAllBytes() throws {
        for name in ["migration-format1", "migration-format2"] {
            let (root, engine, _) = try replay(name)
            let target = name == "migration-format1" ? "0.5.0" : "0.6.0"
            let plan = try engine.migrate(root, targetVersion: target)
            try put(root, "new.txt", "new user bytes")
            let before = try engine.migrationSnapshot(root)
            XCTAssertThrowsError(try engine.migrate(root, action: "apply", targetVersion: target, planID: plan["plan_id"] as? String)) { error in
                XCTAssertTrue(String(describing: error).contains("stale"))
            }
            XCTAssertEqual(try engine.migrationSnapshot(root), before)
        }
    }

    func testFormatThreeMigrationResumesAfterSeedAndRefusesChangedHistory() throws {
        for resolution in ["resume", "rollback", "changed", "history"] {
            let (root, engine, _) = try replay("migration-format2")
            let baseline = try engine.migrationSnapshot(root)
            let plan = try engine.migrate(root)
            let accepted = try engine.migrate(root, action: "apply", planID: plan["plan_id"] as? String)
            let operation = accepted["operation"] as! String
            let journal = try safe(root, ".orbit/migrations/" + operation + ".json")
            var record = try readJSON(journal)
            record["status"] = "prepared"
            try atomic(journal, encode(record))
            let beforeMarker = (record["writes"] as! [JSONObject])[0]["before"] as! String
            try put(root, ".orbit/vault.json", beforeMarker)
            XCTAssertEqual(try engine.migrationStatus(root)["pending"] as? [String], [operation])
            XCTAssertThrowsError(try engine.migrationEnsureWritable(root))
            if resolution == "changed" || resolution == "history" {
                if resolution == "changed" { try put(root, "Knowledge/Exact.md", "New external bytes") }
                else { try put(root, ".orbit/commits/unrelated.json", "{}") }
                let before = try engine.migrationSnapshot(root)
                XCTAssertThrowsError(try engine.migrate(root, action: "rollback", operation: operation)) { error in XCTAssertTrue(String(describing: error).contains("conflict")) }
                XCTAssertEqual(try engine.migrationSnapshot(root), before)
            } else {
                let result = try engine.migrate(root, action: resolution, operation: operation)
                XCTAssertEqual(result["status"] as? String, resolution == "rollback" ? "rolled-back" : "committed")
                if resolution == "rollback" { XCTAssertEqual(try engine.migrationSnapshot(root), baseline) }
                else {
                    let resumed = try engine.migrationSnapshot(root)
                    _ = try engine.migrate(root, action: "resume", operation: operation)
                    XCTAssertEqual(try engine.migrationSnapshot(root), resumed)
                }
            }
        }
    }

    func testInterruptedRollbackResumesBackwardAndPreservesBackup() throws {
        let (root, engine, _) = try replay("migration-format2")
        let baseline = try engine.migrationSnapshot(root)
        let plan = try engine.migrate(root)
        let accepted = try engine.migrate(root, action: "apply", planID: plan["plan_id"] as? String)
        let operation = accepted["operation"] as! String
        let journal = try safe(root, ".orbit/migrations/" + operation + ".json")
        var record = try readJSON(journal)
        record["status"] = "prepared"; record["direction"] = "rollback"
        try atomic(journal, encode(record))
        try put(root, ".orbit/vault.json", (record["writes"] as! [JSONObject])[0]["before"] as! String)
        let result = try engine.migrate(root, action: "resume", operation: operation)
        XCTAssertEqual(result["status"] as? String, "rolled-back")
        XCTAssertEqual(try engine.migrationSnapshot(root), baseline)
        let final = try readJSON(journal)
        XCTAssertEqual(final["status"] as? String, "rolled-back")
        XCTAssertNotNil(final["files"])
        XCTAssertNotNil(final["inputs"])
    }

    func testLegacyMigrationRecoveryRefusesHumanEditsAndRestoresExactBackup() throws {
        for resolution in ["resume", "rollback", "changed"] {
            let (root, engine, fixture) = try replay("migration-format1")
            let baseline = try engine.migrationSnapshot(root)
            let plan = try engine.migrate(root, targetVersion: "0.5.0")
            let result = try engine.migrate(root, action: "apply", targetVersion: "0.5.0", planID: plan["plan_id"] as? String)
            let operation = result["operation"] as! String
            let journal = try safe(root, ".orbit/migrations/" + operation + ".json")
            var record = try readJSON(journal)
            record["status"] = "prepared"
            try atomic(journal, encode(record))
            let writes = record["writes"] as! [JSONObject]
            for write in writes.suffix(3) {
                let path = write["path"] as! String
                if let text = write["before"] as? String { try put(root, path, text) }
                else if try schemaExists(safe(root, path)) { try FileManager.default.removeItem(at: safe(root, path)) }
            }
            if resolution == "changed" {
                try put(root, "Projects/Garden/Overview.md", "Human edit after interruption")
                let before = try engine.migrationSnapshot(root)
                XCTAssertThrowsError(try engine.migrate(root, action: "resume", targetVersion: "0.5.0", operation: operation))
                XCTAssertEqual(try engine.migrationSnapshot(root), before)
            } else {
                _ = try engine.migrate(root, action: resolution, targetVersion: "0.5.0", operation: operation)
                if resolution == "rollback" { XCTAssertEqual(try engine.migrationSnapshot(root), baseline) }
                else {
                    for write in fixture["writes"] as! [JSONObject] {
                        let url = try safe(root, write["path"] as! String)
                        if let text = write["after"] as? String { XCTAssertEqual(try Data(contentsOf: url), Data(text.utf8)) }
                        else { XCTAssertFalse(try schemaExists(url)) }
                    }
                }
                XCTAssertNotNil(try readJSON(journal)["backup_manifest"])
            }
        }
    }

    func testFormattingCannotBypassStrictSchemaValidation() throws {
        let (root, engine) = try workspace()
        try marker(root, format: 2)
        for (path, text) in try engine.schemaBootstrap(root) { try put(root, path, text) }
        let url = try safe(root, "Schemas/Concept.md")
        let original = try String(contentsOf: url, encoding: .utf8)
        try put(root, "Schemas/Concept.md", original.replacingOccurrences(of: "validation: \"warn\"", with: "validation: \"strict\"").replacingOccurrences(of: "required_sections: []", with: "required_sections: [\"Evidence\"]"))
        let raw = Data("Incomplete concept".utf8)
        try atomic(safe(root, "draft.md"), raw)
        let plan: JSONObject = ["changes": [["path": "draft.md", "expected_sha256": digest(raw), "metadata": ["title": "Draft", "type": "concept", "summary": "Draft concept"]]]]
        XCTAssertThrowsError(try engine.formatNotes(root, plan: plan, dryRun: false)) { error in XCTAssertTrue(String(describing: error).contains("Schema validation failed")) }
        XCTAssertEqual(try Data(contentsOf: safe(root, "draft.md")), raw)
    }

    func testConflictedSchemaUsesSameRefusalAsPython() throws {
        let (root, engine, fixture) = try replay("schema-conflict")
        XCTAssertThrowsError(try engine.schemaCheck(root)) { error in
            XCTAssertEqual(String(describing: error), fixture["expected_error"] as? String)
        }
        let snapshot = try engine.migrationSnapshot(root)
        let draft = "---\nid: draft\ntitle: Draft\ntype: concept\nsummary: Draft knowledge\n---\n# Draft\n"
        XCTAssertThrowsError(try engine.apply(root, plan: ["changes": [["path": "Knowledge/Draft.md", "expected_sha256": NSNull(), "content": draft, "reason": "Save with unknown schema"]]], dryRun: false))
        XCTAssertEqual(try engine.migrationSnapshot(root), snapshot)
    }

    func testInterruptedRecoveryMatchesFrozenPythonRequestsAndSnapshots() throws {
        let cases = try fixture("migration-recovery")["cases"] as! [JSONObject]
        for item in cases {
            let (root, engine) = try workspace()
            for (path, text) in item["inputs"] as! [String: String] { try put(root, path, text) }
            let request = item["request"] as! JSONObject, expected = item["expected"] as! JSONObject
            if let error = expected["error"] as? String {
                XCTAssertThrowsError(try engine.migrate(root, action: request["action"] as! String, targetVersion: request["target_version"] as? String, operation: request["operation"] as? String), item["name"] as? String ?? "") { actual in
                    XCTAssertEqual(String(describing: actual), error)
                }
            } else {
                let result = try engine.migrate(root, action: request["action"] as! String, targetVersion: request["target_version"] as? String, operation: request["operation"] as? String)
                XCTAssertEqual(result["status"] as? String, expected["status"] as? String)
                XCTAssertEqual(result["verified"] as? Bool, expected["verified"] as? Bool)
            }
            XCTAssertEqual(try engine.migrationSnapshot(root), expected["snapshot"] as? [String: String], item["name"] as? String ?? "")
        }
    }

    func testCorruptRecoveryJournalRefusesBeforeTouchingNotes() throws {
        for format in [1, 2, 3] {
            let (root, engine) = try workspace()
            try marker(root, format: format)
            try put(root, "unchanged.md", "User-owned bytes")
            let operation = "a8f00000-0000-4000-8000-000000000001"
            let record: JSONObject = ["id": operation, "status": "prepared", "target_format": format == 3 ? 3 : 2, "writes": [["path": "unchanged.md", "before": 17, "after": "Replacement"]], "inputs": JSONObject(), "files": JSONObject()]
            try atomic(safe(root, ".orbit/migrations/" + operation + ".json"), encode(record))
            let snapshot = try engine.migrationSnapshot(root)
            XCTAssertThrowsError(try engine.migrate(root, action: "resume", targetVersion: format == 3 ? "0.6.0" : "0.5.0", operation: operation))
            XCTAssertEqual(try engine.migrationSnapshot(root), snapshot)
        }
    }
}
