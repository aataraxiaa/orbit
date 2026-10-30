import XCTest
@testable import OrbitCore

final class ContractTests: XCTestCase {
    func testFrozenToolsAndStrictValidation() throws {
        XCTAssertEqual(try OrbitContract.tools.count, 19)
        XCTAssertThrowsError(try OrbitContract.validate(action:"apply",arguments:["plan":["changes":[]]]))
        XCTAssertThrowsError(try OrbitContract.validate(action:"search",arguments:["query":"term","limit":true]))
        XCTAssertThrowsError(try OrbitContract.validate(action:"setup",arguments:["name":"Test","path":"relative"]))
        XCTAssertThrowsError(try OrbitContract.validate(action:"read",arguments:["path":"A.md","extra":true]))
    }
    func testMetadataAndPaths() throws {
        let text = "---\nid: stable\ntitle: Test\ntype: concept\nsummary: preserved\ncustom:\n  nested: user text\n---\n# Test\n"
        XCTAssertEqual(metadata(text)["id"] as? String,"stable")
        XCTAssertEqual(metadataBlocks(text)["custom"],"custom:\n  nested: user text\n")
        XCTAssertEqual(links("[[A|label]]\n```\n[[ignored]]\n```\n[[B#heading]]"),["A","B"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        XCTAssertThrowsError(try safe(root,"../escape"))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("link"),withDestinationURL:root)
        XCTAssertThrowsError(try safe(root,"link/A.md"))
    }
    func testPythonEncodingAndRawRequestOrder() throws {
        XCTAssertEqual(String(data:try encode(["b":["é"],"a":1]),encoding:.utf8),"{\n  \"a\": 1,\n  \"b\": [\n    \"é\"\n  ]\n}\n")
        let raw = Data("{\"plan\":{\"summary\":\"x\",\"changes\":[]}}".utf8)
        let expected = digest(Data("{\n  \"summary\": \"x\",\n  \"changes\": []\n}\n".utf8))
        try withOrderedPlan(raw,planPath:["plan"]) { XCTAssertEqual(try requestDigest(["summary":"x","changes":[]]),expected) }
    }
}
