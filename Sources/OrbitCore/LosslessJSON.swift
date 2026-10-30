import Foundation

// A private typed value distinguishes internal provenance from a user field with
// the same spelling. The original user field, if any, remains in the ordered tree.
private let losslessJSONKey = "\u{0}OrbitCore.ordered-json"
private final class LosslessJSONSource {
    let original: OrderedJSON
    init(_ original: OrderedJSON) { self.original = original }
}

func losslessJSONObject(_ original: OrderedJSON) throws -> JSONObject {
    guard var object = original.value as? JSONObject else { throw OrbitError("Expected JSON object") }
    object[losslessJSONKey] = LosslessJSONSource(original)
    return object
}

func isInternalJSONField(_ key: String, in object: JSONObject) -> Bool {
    byteEqual(key,losslessJSONKey) && object[key] is LosslessJSONSource
}

func orderedJSONObject(_ object: JSONObject) -> OrderedJSON? {
    guard let source = object[losslessJSONKey] as? LosslessJSONSource else { return nil }
    return preservingJSON(source.original, current:object).sortedTree()
}

private func preservingJSON(_ old: OrderedJSON, current: Any) -> OrderedJSON {
    if let current = current as? JSONObject, case let .object(pairs) = old {
        let baseline = old.value as! JSONObject
        var result: [(String,OrderedJSON)] = []
        for (key,previous) in pairs {
            if isInternalJSONField(key,in:current) {
                // Preserve an actual user field shadowed by internal provenance.
                result.append((key,previous)); continue
            }
            guard let value = current[key] else { continue }
            if equivalentJSON(value,baseline[key]) { result.append((key,previous)) }
            else { result.append((key,preservingJSON(previous,current:value))) }
        }
        for (key,value) in current where !isInternalJSONField(key,in:current) && !pairs.contains(where:{ byteEqual($0.0,key) }) {
            result.append((key,OrderedJSON.sorted(value)))
        }
        return .object(result)
    }
    if let current = current as? [Any], case let .array(values) = old {
        return .array(current.enumerated().map { index,value in
            index < values.count ? preservingJSON(values[index],current:value) : OrderedJSON.sorted(value)
        })
    }
    return OrderedJSON.sorted(current)
}

private func equivalentJSON(_ current: Any, _ baseline: Any?) -> Bool {
    guard let baseline else { return false }
    return (try? OrderedJSON.sorted(current).rendered(pretty:false)) == (try? OrderedJSON.sorted(baseline).rendered(pretty:false))
}

extension OrderedJSON {
    func sortedTree() -> OrderedJSON {
        switch self {
        case let .object(pairs):
            return .object(pairs.sorted { $0.0.unicodeScalars.lexicographicallyPrecedes($1.0.unicodeScalars) }.map { ($0.0,$0.1.sortedTree()) })
        case let .array(values): return .array(values.map { $0.sortedTree() })
        case .scalar: return self
        }
    }
}
