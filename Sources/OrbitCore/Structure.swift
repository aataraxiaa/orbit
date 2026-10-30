import Foundation
import CoreFoundation

let orbitDirectories = ["Projects", "Knowledge", "People", "Sources", "Schemas", "Maps"]

func schemaMatches(_ pattern: String, _ text: String, options: NSRegularExpression.Options = []) -> [[String]] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
        (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
    }
}

func schemaLines(_ text: String, keepingEnds: Bool = false) -> [String] {
    let ns = text as NSString
    let regex = try! NSRegularExpression(pattern: "[^\\n\\r\\u000B\\u000C\\u001C-\\u001E\\u0085\\u2028\\u2029]*(?:\\r\\n|[\\n\\r\\u000B\\u000C\\u001C-\\u001E\\u0085\\u2028\\u2029]|$)")
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
        guard m.range.length > 0 else { return nil }
        let line = ns.substring(with: m.range)
        return keepingEnds ? line : line.trimmingCharacters(in: CharacterSet(charactersIn: "\n\r\u{B}\u{C}\u{1C}\u{1D}\u{1E}\u{85}\u{2028}\u{2029}"))
    }
}

func schemaInteger(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), !["f", "d"].contains(String(cString: number.objCType)) else { return nil }
    return number.intValue
}

func schemaTrim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
func schemaFold(_ text: String) -> String { text.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
func schemaExists(_ url: URL) throws -> Bool { try fileExists(atPath: url.path) }

extension OrbitEngine {
    func schemaTemplates() throws -> [String: String] {
        guard let directory = Bundle.module.url(forResource: "Schemas", withExtension: nil) else { throw OrbitError("Missing bundled note schemas") }
        var result: [String: String] = [:]
        for path in try directoryContents(at: directory, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) where path.pathExtension == "md" {
            result["Schemas/" + path.lastPathComponent] = try readString( path, encoding: .utf8)
        }
        return result
    }

    func schemaCustom(_ root: URL) throws -> [String: String] {
        let directory = try safe(root, "Schemas")
        guard try schemaExists(directory) else { return [:] }
        var result: [String: String] = [:]
        for path in try directoryContents(at: directory, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) where path.pathExtension == "md" {
            let relative = "Schemas/" + path.lastPathComponent
            result[relative] = try readString( safe(root, relative), encoding: .utf8).trimmingPrefixBOM()
        }
        return result
    }

    func schemaBootstrap(_ root: URL) throws -> [String: String] {
        let existing = Set(try schemaCustom(root).values.compactMap { metadata($0)["schema_for"] as? String })
        var result: [String: String] = [:]
        for (path, text) in try schemaTemplates() {
            if try !schemaExists(try safe(root, path)), let type = metadata(text)["schema_for"] as? String, !existing.contains(type) { result[path] = text }
        }
        return result
    }

    private func schemaDefinitions(_ root: URL, notes: [JSONObject], resolvingPaths: Set<String>) throws -> ([String: JSONObject], [JSONObject]) {
        if replicationEnabled(root) {
            let blocked = Set((try replicationInspect(root)["blocked_paths"] as? [String] ?? []).filter { ($0 as NSString).deletingLastPathComponent == "Schemas" }).subtracting(resolvingPaths)
            if !blocked.isEmpty { throw OrbitError("Resolve conflicting or incomplete schemas before using definitions: " + blocked.sorted().joined(separator: ", ")) }
        }
        let defaults = try schemaTemplates()
        var custom = try schemaCustom(root)
        for note in notes {
            guard let path = note["path"] as? String, (path as NSString).deletingLastPathComponent == "Schemas", (path as NSString).pathExtension.lowercased() == "md", let text = note["text"] as? String else { continue }
            custom[path] = text
        }
        var definitions: [String: JSONObject] = [:]
        var findings: [JSONObject] = []
        var customTypes: [String: [String]] = [:]
        for (path, text) in custom { if let kind = metadata(text)["schema_for"] as? String { customTypes[kind, default: []].append(path) } }
        for (kind, paths) in customTypes where paths.count > 1 {
            for path in paths.sorted() { findings.append(schemaFinding(path, path, "error", "Duplicate schema_for \(kind): " + paths.sorted().joined(separator: ", "))) }
        }
        for (path, text) in defaults.merging(custom, uniquingKeysWith: { _, new in new }).sorted(by: { $0.key < $1.key }) {
            let meta = metadata(text)
            let kind = meta["schema_for"] as? String
            if custom[path] == nil, let kind, customTypes[kind] != nil { continue }
            var invalid: [String] = []
            for field in ["id", "title", "summary", "schema_for"] {
                if let value = meta[field] as? String, !schemaTrim(value).isEmpty {} else { invalid.append(field + " must be a nonempty string") }
            }
            if meta["type"] as? String != "schema" { invalid.append("type must be schema") }
            if let version = schemaInteger(meta["schema_version"]), version >= 1 {} else { invalid.append("schema_version must be a positive integer") }
            if !["warn", "strict"].contains(meta["validation"] as? String ?? "") { invalid.append("validation must be warn or strict") }
            for field in ["required_fields", "required_sections"] {
                if let values = meta[field] as? [String], values.allSatisfy({ !schemaTrim($0).isEmpty }) {} else { invalid.append(field + " must be a list of nonempty strings") }
            }
            let lines = schemaLines(text.trimmingPrefixBOM())
            if lines.first != "---" || !lines.dropFirst().contains("---") { invalid.append("schema must have closed frontmatter") }
            if invalid.isEmpty, let kind, (customTypes[kind]?.count ?? 0) <= 1 {
                definitions[kind] = meta.merging(["path": path], uniquingKeysWith: { old, _ in old })
            } else { findings += invalid.map { schemaFinding(path, path, "error", $0) } }
        }
        return (definitions, findings)
    }

    func schemaWarnings(_ root: URL, notes: [JSONObject], resolvingPaths: Set<String> = []) throws -> [JSONObject] {
        let (definitions, base) = try schemaDefinitions(root, notes: notes, resolvingPaths: resolvingPaths)
        var findings = base
        for note in notes {
            let meta = note["meta"] as? JSONObject ?? [:]
            guard let kind = meta["type"] as? String, let schema = definitions[kind] else { continue }
            let severity = schema["validation"] as? String == "strict" ? "error" : "warning"
            var messages: [String] = []
            for field in schema["required_fields"] as? [String] ?? [] {
                let value = meta[field]
                if value == nil || value is NSNull || ((value as? [Any])?.isEmpty == true) || (value as? String).map({ schemaTrim($0).isEmpty }) == true { messages.append("Missing required field: " + field) }
            }
            if let value = meta["schema_version"], !(value is NSNull), schemaInteger(value) == nil || schemaInteger(value) != schemaInteger(schema["schema_version"]) { messages.append("schema_version must match \(schemaInteger(schema["schema_version"]) ?? 0)") }
            let headings = schemaHeadings(note["text"] as? String ?? "")
            for section in schema["required_sections"] as? [String] ?? [] where !headings.contains(schemaFold(section)) { messages.append("Missing required section: " + section) }
            findings += messages.map { schemaFinding(note["path"] as? String ?? "", schema["path"] as? String ?? "", severity, $0) }
        }
        return findings
    }

    func schemaCheck(_ root: URL, noteType: String? = nil) throws -> JSONObject {
        let notes = try scan(root)
        var (definitions, _) = try schemaDefinitions(root, notes: notes, resolvingPaths: [])
        var findings = try schemaWarnings(root, notes: notes)
        if let noteType {
            definitions = definitions.filter { $0.key == noteType }
            let paths = Set(notes.filter { ($0["meta"] as? JSONObject)?["type"] as? String == noteType }.compactMap { $0["path"] as? String })
            findings = findings.filter { paths.contains($0["path"] as? String ?? "") || $0["path"] as? String == $0["schema"] as? String }
        }
        return ["data_format": 3, "definitions": definitions, "warnings": findings]
    }
}

func schemaFinding(_ path: String, _ schema: String, _ severity: String, _ message: String) -> JSONObject { ["path": path, "schema": schema, "severity": severity, "message": message] }
func schemaHeadings(_ text: String) -> Set<String> {
    var result: Set<String> = [], fence: String?
    for line in schemaLines(text) {
        if let marker = schemaMatches(#"^\s{0,3}(`{3,}|~{3,})"#, line).first?[1] {
            if fence == nil { fence = marker } else if marker.first == fence?.first, marker.count >= (fence?.count ?? 0) { fence = nil }
            continue
        }
        if fence == nil, let heading = schemaMatches(#"^#{1,6}\s+(.+?)\s*#*$"#, line).first?[1] { result.insert(schemaFold(schemaTrim(heading))) }
    }
    return result
}

extension String { func trimmingPrefixBOM() -> String { String(drop(while: { $0 == "\u{FEFF}" })) } }
