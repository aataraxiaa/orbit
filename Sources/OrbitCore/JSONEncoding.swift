import Foundation

indirect enum OrderedJSON {
    case object([(String, OrderedJSON)])
    case array([OrderedJSON])
    case scalar(Any)

    static func parse(_ data: Data) throws -> OrderedJSON {
        var parser = Parser(bytes:Array(data)); let value = try parser.value(); parser.space()
        guard parser.index == parser.bytes.count else { throw OrbitError("Invalid JSON") }; return value
    }
    var value: Any {
        switch self {
        case let .object(pairs): return Dictionary(pairs.map { ($0.0, $0.1.value) }, uniquingKeysWith: { _, new in new })
        case let .array(values): return values.map { $0.value }
        case let .scalar(value): return value
        }
    }
    subscript(_ key: String) -> OrderedJSON? {
        guard case let .object(pairs) = self else { return nil }; return pairs.first { byteEqual($0.0, key) }?.1
    }
    func rendered(pretty: Bool, level: Int = 0) throws -> String {
        let padding = String(repeating:" ",count:level * 2), next = String(repeating:" ",count:(level + 1) * 2)
        switch self {
        case let .scalar(value):
            if let number = pythonNumber(value) { return number }
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
        if let object = value as? JSONObject, let preserved = orderedJSONObject(object) { return preserved }
        if let object = value as? JSONObject { return .object(object.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }.map { ($0, sorted(object[$0]!)) }) }
        if let array = value as? [Any] { return .array(array.map(sorted)) }
        return .scalar(value)
    }
    struct Parser {
        let bytes:[UInt8]; var index = 0
        mutating func space() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
        mutating func value(depth: Int = 0) throws -> OrderedJSON {
            guard depth < 1000 else { throw OrbitError("JSON nesting exceeds supported limit") }
            space(); guard index < bytes.count else { throw OrbitError("Invalid JSON") }
            if bytes[index] == 123 {
                index += 1; space(); var pairs:[(String,OrderedJSON)] = []
                if index < bytes.count && bytes[index] == 125 { index += 1; return .object(pairs) }
                while true {
                    guard let key = try atom() as? String else { throw OrbitError("Invalid JSON key") }
                    space(); guard index < bytes.count && bytes[index] == 58 else { throw OrbitError("Invalid JSON") }; index += 1
                    let v = try value(depth:depth+1)
                    if let i = pairs.firstIndex(where:{byteEqual($0.0, key)}) { pairs[i].1 = v } else { pairs.append((key,v)) }
                    space(); guard index < bytes.count else { throw OrbitError("Invalid JSON") }
                    let c = bytes[index]; index += 1
                    if c == 125 { return .object(pairs) }; guard c == 44 else { throw OrbitError("Invalid JSON") }; space()
                }
            }
            if bytes[index] == 91 {
                index += 1; space(); var values:[OrderedJSON] = []
                if index < bytes.count && bytes[index] == 93 { index += 1; return .array(values) }
                while true {
                    values.append(try value(depth:depth+1)); space(); guard index < bytes.count else { throw OrbitError("Invalid JSON") }
                    let c = bytes[index]; index += 1
                    if c == 93 { return .array(values) }; guard c == 44 else { throw OrbitError("Invalid JSON") }
                }
            }
            return .scalar(try atom())
        }
        func decodeString(_ token: [UInt8]) throws -> String {
            guard token.count >= 2, token.last == 34 else { throw OrbitError("Invalid JSON string") }
            var output: [UInt8] = [], cursor = 1
            func hex(_ offset: Int) throws -> UInt32 {
                guard offset + 4 <= token.count - 1,
                      let value = UInt32(String(decoding:token[offset..<offset+4],as:UTF8.self),radix:16) else { throw OrbitError("Invalid JSON Unicode escape") }
                return value
            }
            while cursor < token.count - 1 {
                let c = token[cursor]; cursor += 1
                if c == 92 {
                    guard cursor < token.count - 1 else { throw OrbitError("Invalid JSON escape") }
                    let escape = token[cursor]; cursor += 1
                    switch escape {
                    case 34,47,92: output.append(escape)
                    case 98: output.append(8)
                    case 102: output.append(12)
                    case 110: output.append(10)
                    case 114: output.append(13)
                    case 116: output.append(9)
                    case 117:
                        var code = try hex(cursor); cursor += 4
                        if (0xD800...0xDBFF).contains(code) {
                            guard cursor + 6 <= token.count - 1, token[cursor] == 92, token[cursor+1] == 117 else { throw OrbitError("Invalid surrogate pair") }
                            let low = try hex(cursor+2)
                            guard (0xDC00...0xDFFF).contains(low) else { throw OrbitError("Invalid surrogate pair") }
                            code = 0x10000 + ((code-0xD800) << 10) + low - 0xDC00; cursor += 6
                        }
                        guard let scalar = UnicodeScalar(code) else { throw OrbitError("Invalid Unicode scalar") }
                        output += String(scalar).utf8
                    default: throw OrbitError("Invalid JSON escape")
                    }
                } else {
                    guard c >= 32, c != 34 else { throw OrbitError("Invalid JSON string") }
                    output.append(c)
                }
            }
            guard String(data:Data(output),encoding:.utf8) != nil else { throw OrbitError("Invalid UTF-8") }
            return String(decoding:output,as:UTF8.self)
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
            if bytes[start] == 34 { return try decodeString(Array(bytes[start..<index])) }
            let token = String(decoding:bytes[start..<index],as:UTF8.self)
            switch token {
            case "true": return true
            case "false": return false
            case "null": return NSNull()
            default: return try parsedJSONNumber(token)
            }
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
        guard let arguments = try OrderedJSON.parse(argumentsJSON).value as? JSONObject else { throw OrbitError("arguments: expected object") }
        return try withOrderedPlan(argumentsJSON,planPath:["plan"]) { try execute(action,arguments:arguments) }
    }
}
extension OrbitMCPServer {
    public func handle(data: Data) throws -> JSONObject? {
        let value = try OrderedJSON.parse(data).value
        return try withOrderedPlan(data,planPath:["params","arguments","plan"]) { handle(value) }
    }
}


extension OrderedJSON {
    func setting(_ key: String, _ value: OrderedJSON) -> OrderedJSON {
        guard case .object(var pairs) = self else { return self }
        if let i = pairs.firstIndex(where:{ byteEqual($0.0,key) }) { pairs[i].1 = value }
        else { pairs.append((key,value)) }
        return .object(pairs)
    }
    func removing(_ key: String) -> OrderedJSON {
        guard case .object(let pairs) = self else { return self }
        return .object(pairs.filter { !byteEqual($0.0,key) })
    }
    func renamed(_ key: String, to newKey: String) -> OrderedJSON {
        guard case .object(let pairs) = self else { return self }
        return .object(pairs.map { (byteEqual($0.0,key) ? newKey : $0.0, $0.1) })
    }
    func encoded() throws -> Data { Data((try rendered(pretty:true) + "\n").utf8) }
}
