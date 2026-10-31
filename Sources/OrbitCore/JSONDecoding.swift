import Foundation

/// Decode command fields with the same UTF-8/string/number rules as native MCP.
/// Retain the original Data for validation, approvals, retries, and model evidence.
public func decodeJSON(_ data: Data) throws -> Any {
  try OrderedJSON.parse(data).value
}

/// Decode an evidence object for inspection while retaining opaque original keys.
/// Serialize returned objects with canonical(_:), not Foundation JSONSerialization.
public func decodeEvidenceObject(_ data: Data) throws -> JSONObject {
  try losslessJSONObject(OrderedJSON.parse(data))
}
