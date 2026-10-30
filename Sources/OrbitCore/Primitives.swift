import Foundation
import CryptoKit
import CoreFoundation
import Darwin

public typealias JSONObject = [String: Any]

public struct OrbitError: Error, LocalizedError, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

public func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
public func systemNow() -> String {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date()).replacingOccurrences(of: "Z", with: "+00:00")
}
public func canonical(_ value: Any) throws -> Data {
    Data(try OrderedJSON.sorted(value).rendered(pretty: false).utf8)
}
public func encode(_ value: Any) throws -> Data {
    Data((try OrderedJSON.sorted(value).rendered(pretty: true) + "\n").utf8)
}
public func readJSON(_ url: URL) throws -> JSONObject {
    guard let result = try OrderedJSON.parse(readData(url)).value as? JSONObject else { throw OrbitError("Expected JSON object") }
    return result
}
public func atomic(_ url: URL, _ data: Data) throws {
    try coordinatedFile(url, mode: .write) { try atomicCoordinated($0, data) }
}
private func atomicCoordinated(_ url: URL, _ data: Data) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var name = Array(url.deletingLastPathComponent().appendingPathComponent(".orbit-XXXXXX").path.utf8CString)
    let fd = mkstemp(&name)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let temp = String(cString: name)
    defer { close(fd); unlink(temp) }
    try data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if n < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            offset += n
        }
    }
    guard fsync(fd) == 0, rename(temp, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
public func syncParent(_ url: URL) throws {
    try coordinatedFile(url.deletingLastPathComponent(), mode: .write) { try syncParentCoordinated($0) }
}
private func syncParentCoordinated(_ url: URL) throws {
    let fd = open(url.path, O_RDONLY)
    guard fd >= 0 else { throw POSIXError(.EIO) }; defer { close(fd) }
    guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
}
public func safe(_ root: URL, _ relative: String) throws -> URL {
    let components = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !relative.isEmpty, !relative.hasPrefix("/"), !components.contains(".."), !relative.contains("\\") else { throw OrbitError("Expected an Orbit-relative path without traversal") }
    let candidate = URL(fileURLWithPath: lexicalPath(root.appendingPathComponent(relative).path))
    let canonicalRoot = realURL(root).path
    let resolved = realURL(candidate).path
    guard resolved == canonicalRoot || resolved.hasPrefix(canonicalRoot + "/") else { throw OrbitError("Path escapes Orbit folder (including symlinks)") }
    var cursor = root
    for part in components {
        cursor.appendPathComponent(part)
        if try fileIsSymbolicLink(cursor) { throw OrbitError("Symlink paths are not supported") }
    }
    return candidate
}
func matchGroups(_ pattern: String, _ text: String, options: NSRegularExpression.Options = []) -> [[String]] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
    return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { m in
        (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
    }
}
func replaced(_ text: String, _ pattern: String, _ replacement: String, options: NSRegularExpression.Options = []) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
    return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
}
func pyString(_ value: Any) -> String {
    if value is NSNull { return "None" }
    if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "True" : "False" }
    return String(describing: value)
}
func truthy(_ value: Any?) -> Bool {
    guard let value, !(value is NSNull) else { return false }
    if let s = value as? String { return !s.isEmpty }
    if let a = value as? [Any] { return !a.isEmpty }
    if let d = value as? JSONObject { return !d.isEmpty }
    if let n = value as? NSNumber { return n.doubleValue != 0 }
    return true
}
public func scalar(_ value: String) -> Any {
    let s = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if let data = s.data(using: .utf8), let v = try? OrderedJSON.parse(data).value { return v }
    return s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
}
public func metadata(_ text: String) -> JSONObject {
    let clean = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
    let lines = clean.components(separatedBy: .newlines)
    guard lines.first == "---" else { return [:] }
    var result: JSONObject = [:]; var key: String?
    for line in lines.dropFirst() {
        if line == "---" { break }
        if let m = matchGroups("^([\\w-]+):\\s*(.*)$", line).first {
            key = m[1]; let value = m[2]
            result[m[1]] = value.isEmpty ? [Any]() : scalar(value)
            if value.hasPrefix("["), !(result[m[1]] is [Any]) {
                result[m[1]] = value.dropFirst().dropLast().split(separator: ",").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { scalar(String($0)) }
            }
        } else if let key, !matchGroups("^\\s+-\\s+", line).isEmpty, var values = result[key] as? [Any] {
            values.append(scalar(replaced(line, "^\\s+-\\s+", ""))); result[key] = values
        }
    }
    return result
}
public func metadataBlockPairs(_ text: String) -> [(String,String)] {
    let clean = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
    let lines = matchGroups("[^\\n]*\\n|[^\\n]+$", clean).map { $0[0] }
    guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return [] }
    var result: [(String,String)] = []; var index: Int?
    for line in lines.dropFirst() {
        if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" { break }
        if let m = matchGroups("^([^\\s#][^:]*):", line).first {
            if let existing = result.firstIndex(where:{ byteEqual($0.0,m[1]) }) { result[existing].1 = line; index = existing }
            else { result.append((m[1],line)); index = result.count - 1 }
        } else if let index { result[index].1 += line }
    }
    return result
}
public func metadataBlocks(_ text: String) -> [String:String] {
    Dictionary(metadataBlockPairs(text),uniquingKeysWith:{ _,new in new })
}

public func strings(_ value: Any?) -> [String] {
    if let a = value as? [Any] { return a.map(pyString) }
    return truthy(value) ? [pyString(value!)] : []
}
public func links(_ text: String) -> [String] {
    let clean = replaced(text, "```.*?```|~~~.*?~~~", "", options: .dotMatchesLineSeparators)
    var result: [String] = []
    for m in matchGroups("\\[\\[([^\\]\\n]+)\\]\\]", clean) {
        let s = m[1].components(separatedBy: "|")[0].components(separatedBy: "#")[0].trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty && !result.contains(s) { result.append(s) }
    }
    return result
}
func casefold(_ text: String) -> String { text.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
public func scan(_ inputRoot: URL) throws -> [JSONObject] {
    let root = realURL(inputRoot)
    let fm = FileManager.default
    var notes: [JSONObject] = []
    func walk(_ directory: URL) throws {
        let entries = try directoryContents(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).sorted { $0.lastPathComponent.unicodeScalars.lexicographicallyPrecedes($1.lastPathComponent.unicodeScalars) }
        let files = try entries.filter { try fileResourceValues($0, forKeys: [.isDirectoryKey]).isDirectory != true }
        let directories = try entries.filter { try fileResourceValues($0, forKeys: [.isDirectoryKey]).isDirectory == true }
        for p in files + directories {
            let values = try fileResourceValues(p, forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                if !p.lastPathComponent.hasPrefix(".") { try walk(p) }; continue
            }
            let relative = String(p.path.dropFirst(root.path.count + 1))
            guard p.pathExtension.lowercased() == "md", !relative.hasPrefix("Sources/assets/") else { continue }
            let raw = try readData( p)
            guard var text = String(data: raw, encoding: .utf8) else { throw OrbitError("Cannot index \(relative): invalid UTF-8") }
            if text.hasPrefix("\u{feff}") { text.removeFirst() }
            let meta = metadata(text)
            let title: String = truthy(meta["title"]) ? pyString(meta["title"]!) : matchGroups("^#\\s+(.+)$", text, options: .anchorsMatchLines).first?[1] ?? p.deletingPathExtension().lastPathComponent
            notes.append(["path": relative, "title": title, "aliases": strings(meta["aliases"]), "id": meta["id"] ?? NSNull(), "type": meta["type"] ?? NSNull(), "status": meta["status"] ?? "current", "sha256": digest(raw), "text": text, "links": links(text), "meta": meta])
        }
    }
    try walk(root); return notes
}
public func identities(_ notes: [JSONObject]) -> NoteIdentityTable {
    var table: NoteIdentityTable = [:]
    for n in notes {
        guard let path = n["path"] as? String else { continue }
        let u = URL(fileURLWithPath: path)
        let keys: [Any] = [path, u.deletingPathExtension().path.hasPrefix("/") ? String(u.deletingPathExtension().path.suffix(path.count - (u.pathExtension.isEmpty ? 0 : u.pathExtension.count + 1))) : u.deletingPathExtension().path, u.deletingPathExtension().lastPathComponent, n["title"] ?? "", n["id"] ?? ""] + (n["aliases"] as? [Any] ?? [])
        for key in keys where truthy(key) { table[OrbitByteString(casefold(pyString(key))), default: []].insert(path) }
    }
    return table
}
public func resolve(_ target: String, table: NoteIdentityTable) -> [String] { (table[OrbitByteString(casefold(target))] ?? []).sorted() }
public func tokens(_ text: String) -> [String] {
    let stop = Set("a an and are as at be by for from how i in is it my of on or that the this to was we what when why with you your".split(separator: " ").map(String.init))
    return matchGroups("[\\p{L}\\p{N}]+", casefold(text)).map { $0[0] }.filter { !stop.contains($0) }
}

func realURL(_ url: URL) -> URL {
    var path = lexicalPath(url.path), suffix:[String] = []
    while true {
        if let pointer = realpath(path,nil) {
            let resolved = String(cString:pointer); free(pointer)
            return URL(fileURLWithPath:([resolved] + suffix.reversed()).joined(separator:"/"))
        }
        if path == "/" || path.isEmpty { return url }
        suffix.append((path as NSString).lastPathComponent)
        path = (path as NSString).deletingLastPathComponent
    }
}
