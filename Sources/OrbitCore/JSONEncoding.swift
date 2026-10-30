import Foundation

indirect enum OrderedJSON {
    case object([(String, OrderedJSON)])
    case array([OrderedJSON])
    case scalar(Any)

    static func parse(_ data: Data) throws -> OrderedJSON {
        var parser = Parser(bytes:Array(data)); let value = try parser.value(); parser.space()
        guard parser.index == parser.bytes.count else { throw OrbitError("Invalid JSON") }; return value
    }
    subscript(_ key: String) -> OrderedJSON? {
        guard case let .object(pairs) = self else { return nil }; return pairs.first { $0.0 == key }?.1
    }
    func rendered(pretty: Bool, level: Int = 0) throws -> String {
        let padding = String(repeating:" ",count:level * 2), next = String(repeating:" ",count:(level + 1) * 2)
        switch self {
        case let .scalar(value):
            let data = try JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed,.withoutEscapingSlashes])
            return String(decoding:data,as:UTF8.self)
        case let .array(values):
            if values.isEmpty { return "[]" }
            let body = try values.map { try $0.rendered(pretty:pretty,level:level+1) }
            return pretty ? "[\n" + body.map { next + $0 }.joined(separator:",\n") + "\n" + padding + "]" : "[" + body.joined(separator:",") + "]"
        case let .object(pairs):
            if pairs.isEmpty { return "{}" }
            let body = try pairs.map { key,value in try OrderedJSON.scalar(key).rendered(pretty:false) + (pretty ? ": ":":") + value.rendered(pretty:pretty,level:level+1) }
            return pretty ? "{\n" + body.map { next + $0 }.joined(separator:",\n") + "\n" + padding + "}" : "{" + body.joined(separator:",") + "}"
        }
    }
    static func sorted(_ value: Any) -> OrderedJSON {
        if let object = value as? JSONObject { return .object(object.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }.map { ($0, sorted(object[$0]!)) }) }
        if let array = value as? [Any] { return .array(array.map(sorted)) }
        return .scalar(value)
    }
    struct Parser {
        let bytes:[UInt8]; var index = 0
        mutating func space() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
        mutating func value() throws -> OrderedJSON {
            space(); guard index < bytes.count else { throw OrbitError("Invalid JSON") }
            if bytes[index] == 123 {
                index += 1; space(); var pairs:[(String,OrderedJSON)] = []
                if index < bytes.count && bytes[index] == 125 { index += 1; return .object(pairs) }
                while true {
                    guard let key = try atom() as? String else { throw OrbitError("Invalid JSON key") }
                    space(); guard index < bytes.count && bytes[index] == 58 else { throw OrbitError("Invalid JSON") }; index += 1
                    let v = try value()
                    if let i = pairs.firstIndex(where:{$0.0 == key}) { pairs[i].1 = v } else { pairs.append((key,v)) }
                    space(); guard index < bytes.count else { throw OrbitError("Invalid JSON") }
                    let c = bytes[index]; index += 1
                    if c == 125 { return .object(pairs) }; guard c == 44 else { throw OrbitError("Invalid JSON") }; space()
                }
            }
            if bytes[index] == 91 {
                index += 1; space(); var values:[OrderedJSON] = []
                if index < bytes.count && bytes[index] == 93 { index += 1; return .array(values) }
                while true {
                    values.append(try value()); space(); guard index < bytes.count else { throw OrbitError("Invalid JSON") }
                    let c = bytes[index]; index += 1
                    if c == 93 { return .array(values) }; guard c == 44 else { throw OrbitError("Invalid JSON") }
                }
            }
            return .scalar(try atom())
        }
        mutating func atom() throws -> Any {
            space(); let start = index
            guard index < bytes.count else { throw OrbitError("Invalid JSON") }
            if bytes[index] == 34 {
                index += 1; var escaped = false
                while index < bytes.count {
                    let c = bytes[index]; index += 1
                    if !escaped && c == 34 { break }
                    if !escaped && c == 92 { escaped = true } else { escaped = false }
                }
            } else {
                while index < bytes.count && ![9,10,13,32,44,93,125,58].contains(bytes[index]) { index += 1 }
            }
            guard index > start else { throw OrbitError("Invalid JSON") }
            return try JSONSerialization.jsonObject(with:Data(bytes[start..<index]),options:.fragmentsAllowed)
        }
    }
}

func withOrderedPlan<T>(_ request: Data, planPath: [String], body: () throws -> T) throws -> T {
    let parsed = try OrderedJSON.parse(request)
    var arguments: OrderedJSON? = parsed
    for key in planPath.dropLast() { arguments = arguments?[key] }
    var node = arguments?[planPath.last ?? "plan"]
    if node == nil { node = arguments?["record"] }
    let storage = Thread.current.threadDictionary, key = "orbit.requestDigest"
    let previous = storage[key]
    let previousRequest = storage["orbit.orderedRequest"]
    if let arguments { storage["orbit.orderedRequest"] = arguments["record"] ?? arguments }
    if let node { storage[key] = digest(Data((try node.rendered(pretty:true) + "\n").utf8)) }
    defer {
        if let previous { storage[key] = previous } else { storage.removeObject(forKey:key) }
        if let previousRequest { storage["orbit.orderedRequest"] = previousRequest } else { storage.removeObject(forKey:"orbit.orderedRequest") }
    }
    return try body()
}
public func requestDigest(_ plan: JSONObject) throws -> String {
    if let value = Thread.current.threadDictionary["orbit.requestDigest"] as? String { return value }
    return try digest(encode(plan))
}

extension OrbitEngine {
    public func execute(_ action: String, argumentsJSON: Data) throws -> JSONObject {
        guard let arguments = try JSONSerialization.jsonObject(with:argumentsJSON) as? JSONObject else { throw OrbitError("arguments: expected object") }
        return try withOrderedPlan(argumentsJSON,planPath:["plan"]) { try execute(action,arguments:arguments) }
    }
}
extension OrbitMCPServer {
    public func handle(data: Data) throws -> JSONObject? {
        let value = try JSONSerialization.jsonObject(with:data,options:.fragmentsAllowed)
        return try withOrderedPlan(data,planPath:["params","arguments","plan"]) { handle(value) }
    }
}
