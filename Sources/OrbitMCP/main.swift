import Foundation
import OrbitCore

let launchEnvironment: [String: String]
do {
  launchEnvironment = try OrbitLaunchConfiguration.environment(
    arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
  FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
  exit(2)
}
let server = OrbitMCPServer(engine: OrbitEngine(environment: launchEnvironment))
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
