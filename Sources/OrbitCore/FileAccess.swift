import Darwin
import Foundation

public enum OrbitFileAccessMode: Sendable, Equatable { case read, write, delete }

/// The native host holds its folder bookmark lease around engine execution and
/// coordinates each accessor. The URL passed to the body is the provider's URL.
public protocol OrbitFileAccess {
  func coordinate(_ url: URL, mode: OrbitFileAccessMode, body: (URL) throws -> Void) throws
}

public struct LocalOrbitFileAccess: OrbitFileAccess {
  public init() {}
  public func coordinate(_ url: URL, mode: OrbitFileAccessMode, body: (URL) throws -> Void) throws {
    try body(url)
  }
}

private final class OrbitAccessScope: NSObject {
  let access: any OrbitFileAccess
  init(_ access: any OrbitFileAccess) { self.access = access }
}

func withOrbitFileAccess<T>(_ access: any OrbitFileAccess, body: () throws -> T) throws -> T {
  let storage = Thread.current.threadDictionary
  let key = "orbit.fileAccess"
  let previous = storage[key]
  storage[key] = OrbitAccessScope(access)
  defer {
    if let previous { storage[key] = previous } else { storage.removeObject(forKey: key) }
  }
  return try body()
}

func coordinatedFile<T>(_ url: URL, mode: OrbitFileAccessMode, body: (URL) throws -> T) throws -> T
{
  if Task.isCancelled { throw CancellationError() }
  let access =
    (Thread.current.threadDictionary["orbit.fileAccess"] as? OrbitAccessScope)?.access
    ?? LocalOrbitFileAccess()
  var result: Result<T, Error>?
  try access.coordinate(url, mode: mode) { accessorURL in
    guard result == nil else {
      throw OrbitError("File coordinator invoked an accessor more than once")
    }
    do { result = .success(try body(accessorURL)) } catch {
      result = .failure(error)
      throw error
    }
  }
  guard let result else { throw OrbitError("File coordinator did not grant access") }
  return try result.get()
}

public func readData(_ url: URL) throws -> Data {
  try coordinatedFile(url, mode: .read) { try Data(contentsOf: $0) }
}

func readString(_ url: URL, encoding: String.Encoding = .utf8) throws -> String {
  let data = try readData(url)
  guard let value = String(data: data, encoding: encoding) else {
    throw OrbitError("Invalid text encoding: " + url.path)
  }
  return value
}

func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>? = nil) throws
  -> Bool
{
  try coordinatedFile(URL(fileURLWithPath: path), mode: .read) {
    FileManager.default.fileExists(atPath: $0.path, isDirectory: isDirectory)
  }
}

func fileResourceValues(_ url: URL, forKeys keys: Set<URLResourceKey>) throws -> URLResourceValues {
  try coordinatedFile(url, mode: .read) { try $0.resourceValues(forKeys: keys) }
}

func fileAttributes(atPath path: String) throws -> [FileAttributeKey: Any] {
  try coordinatedFile(URL(fileURLWithPath: path), mode: .read) {
    try FileManager.default.attributesOfItem(atPath: $0.path)
  }
}

func directoryContents(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?) throws
  -> [URL]
{
  try coordinatedFile(url, mode: .read) {
    try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: keys)
  }
}

func createDirectory(
  at url: URL, withIntermediateDirectories intermediates: Bool,
  attributes: [FileAttributeKey: Any]? = nil
) throws {
  try coordinatedFile(url, mode: .write) {
    try FileManager.default.createDirectory(
      at: $0, withIntermediateDirectories: intermediates, attributes: attributes)
  }
}

func removeFile(at url: URL) throws {
  try coordinatedFile(url, mode: .delete) { try FileManager.default.removeItem(at: $0) }
}

func writeData(_ value: Data, to url: URL) throws {
  try coordinatedFile(url, mode: .write) { try value.write(to: $0) }
}

func writableFile(atPath path: String) throws -> Bool {
  try coordinatedFile(URL(fileURLWithPath: path), mode: .read) {
    FileManager.default.isWritableFile(atPath: $0.path)
  }
}

func openFile(_ url: URL, flags: Int32, permissions: mode_t = 0o600) throws -> Int32 {
  let writing = flags & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC) != 0
  return try coordinatedFile(url, mode: writing ? .write : .read) {
    Darwin.open($0.path, flags, permissions)
  }
}

func fileLStat(_ url: URL) throws -> stat? {
  try coordinatedFile(url, mode: .read) {
    var info = stat()
    if Darwin.lstat($0.path, &info) == 0 { return info }
    if errno == ENOENT || errno == ENOTDIR { return nil }
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}

func fileIsSymbolicLink(_ url: URL) throws -> Bool {
  guard let info = try fileLStat(url) else { return false }
  return info.st_mode & S_IFMT == S_IFLNK
}
