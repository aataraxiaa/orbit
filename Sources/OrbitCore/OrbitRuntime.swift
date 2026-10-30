import Foundation

/// Clock and identity providers for reproducible compatibility checks.
public final class OrbitRuntime {
  let clock: () -> String
  let uuid: () -> String
  public init(
    clock: @escaping () -> String = systemNow,
    uuid: @escaping () -> String = { UUID().uuidString.lowercased() }
  ) {
    self.clock = clock
    self.uuid = uuid
  }
}
func withOrbitRuntime<T>(_ runtime: OrbitRuntime, body: () throws -> T) rethrows -> T {
  let storage = Thread.current.threadDictionary
  let key = "orbit.runtime"
  let previous = storage[key]
  storage[key] = runtime
  defer { if let previous { storage[key] = previous } else { storage.removeObject(forKey: key) } }
  return try body()
}
public func now() -> String {
  (Thread.current.threadDictionary["orbit.runtime"] as? OrbitRuntime)?.clock() ?? systemNow()
}
public func newUUID() -> String {
  (Thread.current.threadDictionary["orbit.runtime"] as? OrbitRuntime)?.uuid()
    ?? UUID().uuidString.lowercased()
}
