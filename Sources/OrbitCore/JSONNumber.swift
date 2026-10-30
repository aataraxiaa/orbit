import CoreFoundation
import Foundation

/// Retains Python's arbitrary-precision integer semantics for opaque JSON fields.
struct JSONBigInteger: CustomStringConvertible {
  let description: String
}

func byteEqual(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }

func pythonNumber(_ value: Any) -> String? {
  if let large = value as? JSONBigInteger { return large.description }
  guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
    return nil
  }
  let type = String(cString: number.objCType)
  if !["d", "f"].contains(type) { return number.stringValue }
  let value = number.doubleValue
  guard value.isFinite else { return nil }
  var result = String(value).lowercased()
  if let exponent = result.firstIndex(of: "e") {
    let mantissa = String(result[..<exponent])
    let power = Int(result[result.index(after: exponent)...])!
    let normalized = mantissa.hasSuffix(".0") ? String(mantissa.dropLast(2)) : mantissa
    result = normalized + "e" + (power < 0 ? "-" : "+") + String(format: "%02d", abs(power))
  }
  return result
}

func parsedJSONNumber(_ token: String) throws -> Any {
  guard
    token.range(
      of: #"\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z"#, options: .regularExpression)
      != nil
  else { throw OrbitError("Invalid JSON number") }
  if !token.contains(".") && !token.contains("e") && !token.contains("E") {
    if let value = Int64(token) { return NSNumber(value: value) }
    if let value = UInt64(token) { return NSNumber(value: value) }
    return JSONBigInteger(description: token)
  }
  guard let value = Double(token), value.isFinite else { throw OrbitError("Invalid JSON number") }
  return NSNumber(value: value)
}
