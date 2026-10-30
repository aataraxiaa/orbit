import Foundation
import XCTest
@testable import OrbitCore

final class PreservationTests: XCTestCase {
    func workspace() throws -> (URL,OrbitEngine) {
        let base = realURL(FileManager.default.temporaryDirectory.appendingPathComponent("orbit-preservation-" + UUID().uuidString))
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:base) }
        return (base,OrbitEngine(configURL:base.appendingPathComponent("config.json"),cacheURL:base.appendingPathComponent("cache"),stateURL:base.appendingPathComponent("state")))
    }
    func testOrderedJSONRetainsByteDistinctKeysAndPythonNumbers() throws {
        let input = Data("{\"café\":1,\"cafe\\u0301\":2,\"float\":1.0,\"zero\":-0.0,\"exp\":1e-5,\"huge\":1234567890123456789012345678901234567890}".utf8)
        let parsed = try OrderedJSON.parse(input)
        XCTAssertEqual(try parsed.rendered(pretty:false),"{\"café\":1,\"café\":2,\"float\":1.0,\"zero\":-0.0,\"exp\":1e-05,\"huge\":1234567890123456789012345678901234567890}")
        XCTAssertEqual(parsed["café"]?.value as? Int,1)
        XCTAssertEqual(parsed["cafe\u{301}"]?.value as? Int,2)
    }
    func testNumericSerializationMatchesFrozenPythonValues() throws {
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/compatibility/json-numbers.json")
        for item in try readJSON(url)["cases"] as! [JSONObject] {
            let input = item["input"] as! String
            XCTAssertEqual(try OrderedJSON.parse(Data(input.utf8)).rendered(pretty:false),item["output"] as? String,input)
        }
    }
    func testOpaqueMigrationMatchesFrozenPythonBytesAndPlan() throws {
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/compatibility/opaque-metadata.json")
        let fixture = try readJSON(url)
        let (base,engine) = try workspace(); let root = base.appendingPathComponent("folder")
        for (path,text) in fixture["inputs"] as! [String:String] { try atomic(safe(root,path),Data(text.utf8)) }
        let plan = try engine.migrate(root)
        XCTAssertEqual(plan["plan_id"] as? String,(fixture["plan"] as! JSONObject)["plan_id"] as? String)
        _ = try engine.migrate(root,action:"apply",planID:plan["plan_id"] as? String)
        XCTAssertEqual(try readData(safe(root,".orbit/vault.json")),Data((fixture["marker_after"] as! String).utf8))
        for (path,hash) in fixture["seed_history"] as! [String:String] { XCTAssertEqual(digest(try readData(safe(root,path))),hash) }
    }
    func testMigrationPreservesUnknownByteDistinctKeysAndNumericTypes() throws {
        let (base,engine) = try workspace(); let root = base.appendingPathComponent("folder")
        _ = try engine.execute("setup",arguments:["path":root.path,"name":"Test","create":true])
        let marker = try safe(root,".orbit/vault.json")
        let before = try OrderedJSON.parse(readData(marker)).setting("data_format",.scalar(2)).setting("orbit_version",.scalar("0.5.0"))
            .setting("café",.scalar(1)).setting("cafe\u{301}",.scalar(2)).setting("unknown",try OrderedJSON.parse(Data("{\"value\":1.0,\"zero\":-0.0,\"big\":1234567890123456789012345678901234567890}".utf8)))
        try atomic(marker,before.encoded()); try FileManager.default.removeItem(at:root.appendingPathComponent(".orbit/commits"))
        let plan = try engine.migrate(root)
        _ = try engine.migrate(root,action:"apply",planID:plan["plan_id"] as? String)
        let after = try OrderedJSON.parse(readData(marker))
        XCTAssertEqual(try after["unknown"]?.rendered(pretty:false),try before["unknown"]?.rendered(pretty:false))
        XCTAssertEqual(after["café"]?.value as? Int,1); XCTAssertEqual(after["cafe\u{301}"]?.value as? Int,2)
    }
    func testRegistryRenameAndSetupPreserveOpaqueFields() throws {
        let (base,engine) = try workspace(); let root = base.appendingPathComponent("folder")
        _ = try engine.execute("setup",arguments:["path":root.path,"name":"Test","create":true])
        let opaque = try OrderedJSON.parse(Data("{\"café\":1,\"cafe\\u0301\":2,\"number\":1.0}".utf8))
        var config = try OrderedJSON.parse(readData(engine.configURL)).setting("opaque",opaque)
        config = config.setting("café",.scalar(1)).setting("cafe\u{301}",.scalar(2))
        try atomic(engine.configURL,config.encoded())
        _ = try engine.execute("rename",arguments:["orbit":"Test","name":"Renamed"])
        let after = try OrderedJSON.parse(readData(engine.configURL))
        XCTAssertEqual(try after["opaque"]?.rendered(pretty:false),try opaque.rendered(pretty:false))
        XCTAssertEqual(after["café"]?.value as? Int,1); XCTAssertEqual(after["cafe\u{301}"]?.value as? Int,2)
        _ = try engine.execute("setup",arguments:["path":base.appendingPathComponent("second").path,"name":"Second","create":true])
        let second = try OrderedJSON.parse(readData(engine.configURL))
        XCTAssertEqual(try second["opaque"]?.rendered(pretty:false),try opaque.rendered(pretty:false))
        XCTAssertEqual(second["café"]?.value as? Int,1); XCTAssertEqual(second["cafe\u{301}"]?.value as? Int,2)
    }
    func testInitializingMarkerPreservesOpaqueFields() throws {
        let (base,engine) = try workspace(); let root = base.appendingPathComponent("folder")
        _ = try engine.execute("setup",arguments:["path":root.path,"name":"Test","create":true])
        let marker = try safe(root,".orbit/vault.json")
        let value = try OrderedJSON.parse(readData(marker)).setting("initializing",.scalar(true)).setting("café",.scalar(1)).setting("cafe\u{301}",.scalar(2)).setting("number",try OrderedJSON.parse(Data("1.0".utf8)))
        try atomic(marker,value.encoded())
        _ = try engine.execute("setup",arguments:["path":root.path,"name":"Test"])
        let after = try OrderedJSON.parse(readData(marker))
        XCTAssertNil(after["initializing"])
        XCTAssertEqual(after["café"]?.value as? Int,1); XCTAssertEqual(after["cafe\u{301}"]?.value as? Int,2)
        XCTAssertEqual(try after["number"]?.rendered(pretty:false),"1.0")
    }
    func testUnknownMetadataPairsMustRemainVerbatim() throws {
        let (base,engine) = try workspace(); let root = base.appendingPathComponent("folder")
        _ = try engine.execute("setup",arguments:["path":root.path,"name":"Test","create":true])
        let original = "---\nid: a\ntitle: A\ntype: concept\nsummary: Review\ncafé: one\ncafe\u{301}: two\n---\nBody\n"
        let path = "Knowledge/A.md"
        _ = try engine.apply(root,plan:["changes":[["path":path,"content":original,"reason":"fixture","expected_sha256":NSNull()]]])
        let before = try readData(safe(root,path))
        let updated = original.replacingOccurrences(of:"café: one",with:"café: CHANGED")
        XCTAssertThrowsError(try engine.apply(root,plan:["changes":[["path":path,"content":updated,"reason":"fixture","expected_sha256":digest(before)]]]))
        XCTAssertEqual(try readData(safe(root,path)),before)
    }
}
