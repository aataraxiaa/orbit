import Foundation

/// Trusted desktop launch locations, separate from the validated tool contract.
public enum OrbitLaunchConfiguration {
  public static func environment(
    arguments: [String], base: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> [String: String] {
    let options = ["--config": "ORBIT_CONFIG", "--cache": "ORBIT_CACHE", "--state": "ORBIT_STATE"]
    var result = base
    var seen: Set<String> = []
    var index = 0
    while index < arguments.count {
      let flag = arguments[index]
      guard let key = options[flag], seen.insert(flag).inserted, index + 1 < arguments.count else {
        throw OrbitError("Expected unique --config, --cache or --state with an absolute path")
      }
      let path = (arguments[index + 1] as NSString).expandingTildeInPath
      guard path.hasPrefix("/") else { throw OrbitError(flag + ": absolute path required") }
      result[key] = path
      index += 2
    }
    return result
  }
}
