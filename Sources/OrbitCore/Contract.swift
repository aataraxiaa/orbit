import Foundation
import CoreFoundation

public enum OrbitContract {
    public static let version = "1"
    public static var document: JSONObject {
        get throws {
            guard let url = Bundle.module.url(forResource: "contract", withExtension: "json") else { throw OrbitError("Missing tool contract") }
            return try readJSON(url)
        }
    }
    public static var tools: [JSONObject] { get throws { try document["tools"] as! [JSONObject] } }
    public static var instructions: String {
        get throws {
            let base = try document["instructions"] as! String
            let workflows = try workflowDocument["workflows"] as! JSONObject
            return base + "\n\nShared workflow instructions v1\n\n" + ["orbit-save", "orbit-recall"].map { (workflows[$0] as! JSONObject)["instructions"] as! String }.joined(separator:"\n\n")
        }
    }
    public static var workflowDocument: JSONObject {
        get throws {
            guard let url = Bundle.module.url(forResource:"workflows",withExtension:"json") else { throw OrbitError("Missing workflow instructions") }
            return try readJSON(url)
        }
    }
    public static func validate(action: String, arguments: JSONObject) throws {
        guard let tool = try tools.first(where: { $0["name"] as? String == "orbit_" + action }) else { throw OrbitError("Unknown tool") }
        try validateValue(arguments,schema: tool["inputSchema"] as! JSONObject,path:"arguments")
        for key in ["vault", "source"] + (action == "setup" ? ["path"] : []) {
            if let path = arguments[key] as? String, !(path as NSString).expandingTildeInPath.hasPrefix("/") { throw OrbitError("\(key): absolute path required") }
        }
        if action == "recover", arguments["rollback"] as? Bool == true, arguments["abandon"] as? Bool == true { throw OrbitError("Choose rollback or abandon, not both") }
        if action == "sync", arguments["action"] as? String == "history", arguments["path"] == nil { throw OrbitError("History requires a note or integration path") }
    }
    static func validateValue(_ value: Any,schema: JSONObject,path: String) throws {
        let types = schema["type"] as? [String] ?? [schema["type"] as! String]
        let actual: String
        if value is NSNull { actual = "null" }
        else if value is JSONObject { actual = "object" }
        else if value is [Any] { actual = "array" }
        else if value is String { actual = "string" }
        else if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { actual = "boolean" }
            else if String(cString: n.objCType) == "d" || String(cString:n.objCType) == "f" { actual = "number" }
            else { actual = "integer" }
        } else { actual = "unknown" }
        guard types.contains(actual) else { throw OrbitError("\(path): expected " + types.joined(separator:" or ")) }
        if let values = schema["enum"] as? [Any], !values.contains(where: { NSObjectEqual($0,value) }) { throw OrbitError("\(path): unsupported value") }
        switch actual {
        case "object":
            let object = value as! JSONObject, properties = schema["properties"] as! JSONObject
            let missing = Set(schema["required"] as? [String] ?? []).subtracting(object.keys).sorted(), unknown = Set(object.keys).subtracting(properties.keys).sorted()
            if !missing.isEmpty || !unknown.isEmpty { throw OrbitError("\(path): missing fields \(pythonList(missing)); unknown fields \(pythonList(unknown))") }
            for (key,item) in object { try validateValue(item,schema:properties[key] as! JSONObject,path:path + "." + key) }
        case "array":
            let array = value as! [Any]
            guard array.count >= schema["minItems"] as? Int ?? 0, array.count <= schema["maxItems"] as? Int ?? 1000 else { throw OrbitError("\(path): invalid number of items") }
            for item in array { try validateValue(item,schema:schema["items"] as! JSONObject,path:path + "[]") }
        case "string":
            let text = value as! String
            guard text.trimmingCharacters(in:.whitespacesAndNewlines).unicodeScalars.count >= schema["minLength"] as? Int ?? 0 else { throw OrbitError("\(path): nonempty string required") }
            if let pattern = schema["pattern"] as? String, text.range(of:"\\A(?:" + pattern + ")\\z",options:.regularExpression) == nil { throw OrbitError("\(path): invalid format") }
        case "integer":
            let n = (value as! NSNumber).int64Value
            if n < (schema["minimum"] as? NSNumber)?.int64Value ?? n || n > (schema["maximum"] as? NSNumber)?.int64Value ?? n { throw OrbitError("\(path): outside supported range") }
        default: break
        }
    }
}
func NSObjectEqual(_ a:Any,_ b:Any)->Bool { (a as? NSObject)?.isEqual(b) ?? false }
func pythonList(_ values:[String])->String { "[" + values.map { "'" + $0 + "'" }.joined(separator:", ") + "]" }

public struct OrbitMCPServer {
    public let engine: OrbitEngine
    public init(engine: OrbitEngine) { self.engine = engine }
    public func handle(_ value: Any) -> JSONObject? {
        func rpcError(_ id: Any,_ code: Int,_ message: String)->JSONObject { ["jsonrpc":"2.0","id":id,"error":["code":code,"message":message]] }
        guard let message = value as? JSONObject, message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else { return rpcError(NSNull(),-32600,"Invalid Request") }
        let id = message["id"] ?? NSNull()
        if message["id"] != nil {
            if !(id is String) {
                guard let n = id as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !["d","f"].contains(String(cString:n.objCType)) else { return rpcError(NSNull(),-32600,"Invalid request id") }
            }
        } else { return nil }
        guard let params = message["params"] as? JSONObject ?? (message["params"] == nil ? [:] : nil) else { return rpcError(id,-32602,"Params must be an object") }
        let result: JSONObject
        switch method {
        case "initialize":
            guard let offered = params["protocolVersion"] as? String, params["capabilities"] is JSONObject, params["clientInfo"] is JSONObject else { return rpcError(id,-32602,"Initialize requires protocolVersion, capabilities and clientInfo") }
            do {
                let protocols = try OrbitContract.document["protocols"] as! [String]
                result = ["protocolVersion":protocols.contains(offered) ? offered:protocols.last!,"capabilities":["tools":["listChanged":false]],"serverInfo":["name":"orbit","version":OrbitEngine.packageVersion],"instructions":try OrbitContract.instructions]
            } catch { return rpcError(id,-32603,String(describing:error)) }
        case "ping": result = [:]
        case "tools/list":
            guard Set(params.keys).subtracting(["_meta","cursor"]).isEmpty, params["cursor"] == nil || params["cursor"] is NSNull || params["cursor"] as? String == "" else { return rpcError(id,-32602,"Unsupported tool list parameters or cursor") }
            do { result = ["tools":try OrbitContract.tools] } catch { return rpcError(id,-32603,String(describing:error)) }
        case "tools/call":
            guard let name = params["name"] as? String, name.hasPrefix("orbit_"), let specs = try? OrbitContract.tools, specs.contains(where:{$0["name"] as? String == name}) else { return rpcError(id,-32602,"Unknown tool") }
            guard Set(params.keys).subtracting(["name","arguments","_meta"]).isEmpty else { return rpcError(id,-32602,"Unknown tool call fields") }
            let args: JSONObject
            guard let parsed = params["arguments"] as? JSONObject ?? (params["arguments"] == nil ? [:]:nil) else { return rpcError(id,-32602,"arguments: expected object") }; args = parsed
            let action = String(name.dropFirst(6))
            do { try OrbitContract.validate(action:action,arguments:args) } catch { return rpcError(id,-32602,String(describing:error)) }
            do {
                let response = try engine.execute(action,arguments:args)
                result = ["content":[["type":"text","text":String(data:try canonical(response),encoding:.utf8)!]],"isError":false]
            } catch {
                result = ["content":[["type":"text","text":String(data:(try? canonical(["error":String(describing:error)])) ?? Data(),encoding:.utf8)!]],"isError":true]
            }
        default: return rpcError(id,-32601,"Method not found")
        }
        return ["jsonrpc":"2.0","id":id,"result":result]
    }
}
