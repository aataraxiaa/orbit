import Foundation
import XCTest
@testable import OrbitCore

final class UnicodeSchemaMigrationTests: XCTestCase {
    private func replay(_ name: String) throws -> (URL, OrbitEngine, JSONObject) {
        let fixture = try readJSON(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/compatibility/" + name + ".json"))
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-unicode-schemas-" + UUID().uuidString)
        let root = base.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        for (path, text) in fixture["inputs"] as! [String: String] { try atomic(safe(root, path), Data(text.utf8)) }
        return (root, OrbitEngine(configURL: base.appendingPathComponent("config"), cacheURL: base.appendingPathComponent("cache"), stateURL: base.appendingPathComponent("state")), fixture)
    }

    func testByteDistinctCustomSchemaTypesEnforceTheirOwnContracts() throws {
        let (root, engine, _) = try replay("unicode-schemas")
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/compatibility/unicode-schemas.json")
        let checks = try OrderedJSON.parse(readData(fixtureURL))["checks"]!
        for (label, kind) in [("all", Optional<String>.none), ("composed", Optional("café")), ("decomposed", Optional("cafe\u{301}"))] {
            let report = try engine.schemaCheck(root, noteType: kind)
            XCTAssertEqual(try canonical(report), Data(try checks[label]!.sortedTree().rendered(pretty: false).utf8), label)
        }
        let report = try OrderedJSON.parse(canonical(engine.schemaCheck(root)))
        guard case let .object(definitions)? = report["definitions"] else { return XCTFail("Expected lossless schema definitions") }
        let types = Set(definitions.map { OrbitByteString($0.0) })
        XCTAssertTrue(types.contains(OrbitByteString("café")))
        XCTAssertTrue(types.contains(OrbitByteString("cafe\u{301}")))
        XCTAssertEqual(types.count, 9)
    }

    func testHeadingsCasefoldWithoutUnicodeNormalization() {
        let headings = schemaHeadings("# CAFÉ\n# Straße\n# Σς\n")
        XCTAssertTrue(headings.contains(OrbitByteString("café")))
        XCTAssertFalse(headings.contains(OrbitByteString("cafe\u{301}")))
        XCTAssertTrue(headings.contains(OrbitByteString("strasse")))
        XCTAssertTrue(headings.contains(OrbitByteString("σσ")))
    }

    func testUnicodeProjectIDsSelectDifferentMigrationDestinations() throws {
        let (root, engine, fixture) = try replay("unicode-project-migration")
        let expected = fixture["plan"] as! JSONObject
        let plan = try engine.migrate(root, targetVersion: "0.5.0")
        XCTAssertEqual(plan["plan_id"] as? String, expected["plan_id"] as? String)
        _ = try engine.migrate(root, action: "apply", targetVersion: "0.5.0", planID: plan["plan_id"] as? String)
        for write in fixture["writes"] as! [JSONObject] {
            let url = try safe(root, write["path"] as! String)
            if let text = write["after"] as? String { XCTAssertEqual(try Data(contentsOf: url), Data(text.utf8), write["path"] as! String) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
        }
        let first = try readString(safe(root, "Projects/First Project/Decisions/DecisionA.md"))
        let second = try readString(safe(root, "Projects/Second Project/Decisions/DecisionB.md"))
        XCTAssertTrue(first.contains("[[Projects/First Project/Overview]]"))
        XCTAssertTrue(second.contains("[[Projects/Second Project/Overview]]"))
    }
}
