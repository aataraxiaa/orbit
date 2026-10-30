import Foundation
import OrbitCore

// Development-only deterministic driver. Never included by package_swift.py.
let locations = OrbitEngine()
var sequence: UInt64 = 0
let runtime = OrbitRuntime(
  clock: { "2026-10-30T12:00:00.000000+00:00" },
  uuid: {
    sequence += 1
    return String(format: "00000000-0000-4000-8000-%012llx", sequence)
  })
let engine = OrbitEngine(
  configURL: locations.configURL, cacheURL: locations.cacheURL, stateURL: locations.stateURL,
  runtime: runtime)
let server = OrbitMCPServer(engine: engine)
let limit = 8 * 1024 * 1024
var buffer = Data()
func emit(_ response: JSONObject) {
  if var data = try? canonical(response) {
    data.append(10)
    FileHandle.standardOutput.write(data)
  }
}
var oversized = false
while true {
  let chunk = FileHandle.standardInput.availableData
  if chunk.isEmpty { break }
  buffer.append(chunk)
  while let newline = buffer.firstIndex(of: 10) {
    let line = buffer.prefix(through: newline)
    buffer.removeSubrange(...newline)
    if line.count > limit {
      oversized = true
      break
    }
    do { if let result = try server.handle(data: Data(line)) { emit(result) } } catch {
      emit(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
    }
  }
  if oversized || buffer.count > limit {
    emit([
      "jsonrpc": "2.0", "id": NSNull(),
      "error": ["code": -32600, "message": "Request exceeds 8 MiB limit"],
    ])
    oversized = true
    break
  }
}
if !oversized && !buffer.isEmpty {
  do { if let result = try server.handle(data: buffer) { emit(result) } } catch {
    emit(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
  }
}
