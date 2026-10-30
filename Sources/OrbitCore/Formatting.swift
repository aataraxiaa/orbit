import CryptoKit
import Foundation

private let formattingRequired = ["id", "title", "type", "summary"]
private let formattingBreaks = CharacterSet(
  charactersIn: "\n\r\u{B}\u{C}\u{1C}\u{1D}\u{1E}\u{85}\u{2028}\u{2029}\0")

func formattingScalar(_ input: String) throws -> String {
  let value = schemaTrim(input)
  var parsed: String
  if value.hasPrefix("\"") {
    guard let object = try? OrderedJSON.parse(Data(value.utf8)).value, let text = object as? String
    else { throw OrbitError("Required metadata must use a supported single-line string") }
    parsed = text
  } else if value.hasPrefix("'") {
    guard value.count >= 2, value.hasSuffix("'"), !value.dropFirst().dropLast().contains("'") else {
      throw OrbitError("Required metadata must use a supported single-line string")
    }
    parsed = String(value.dropFirst().dropLast())
  } else {
    guard !value.isEmpty, !"[]{}&*!|>@`%#?:,-".contains(value.first!), !value.contains(" #"),
      !value.contains(": "),
      !["null", "~", "true", "false", "yes", "no", "on", "off"].contains(value.lowercased()),
      schemaMatches(#"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$"#, value).isEmpty
    else { throw OrbitError("Required metadata must use a supported nonempty string") }
    parsed = value
  }
  guard !schemaTrim(parsed).isEmpty, parsed.rangeOfCharacter(from: formattingBreaks) == nil else {
    throw OrbitError("Required metadata must use a supported nonempty single-line string")
  }
  return parsed
}

struct FormattingHeader {
  let bom: String
  let frontmatter: String
  let body: String
  let fields: [String: String]
  let newline: String
}

func formattingHeader(_ raw: Data) throws -> FormattingHeader {
  guard String(data: raw, encoding: .utf8) != nil else {
    throw OrbitError("Note is not valid UTF-8")
  }
  var text = String(decoding: raw, as: UTF8.self)
  let bom = text.hasPrefix("\u{FEFF}") ? "\u{FEFF}" : ""
  if !bom.isEmpty { text.removeFirst() }
  let lines = schemaLines(text, keepingEnds: true)
  let newline = schemaMatches("\\r\\n|\\n|\\r", text).first?.first ?? "\n"
  func stripEnding(_ text: String) -> String {
    String(
      String.UnicodeScalarView(
        text.unicodeScalars.reversed().drop(while: { $0 == "\n" || $0 == "\r" }).reversed()))
  }
  guard let first = lines.first, stripEnding(first) == "---" else {
    if let first = lines.first, schemaTrim(first) == "---" {
      throw OrbitError("Ambiguous frontmatter delimiter")
    }
    return FormattingHeader(bom: bom, frontmatter: "", body: text, fields: [:], newline: newline)
  }
  if first == "---" { throw OrbitError("Unclosed frontmatter") }
  var fields: [String: String] = [:]
  var seen: Set<String> = []
  var current: String?
  for index in lines.indices.dropFirst() {
    let content = stripEnding(lines[index])
    if content == "---" {
      return FormattingHeader(
        bom: bom, frontmatter: lines[...index].joined(), body: lines.dropFirst(index + 1).joined(),
        fields: fields, newline: newline)
    }
    if schemaTrim(content).isEmpty || schemaTrim(content).hasPrefix("#") { continue }
    if content.first?.isWhitespace == true {
      guard let current, !formattingRequired.contains(current) else {
        throw OrbitError("Unsupported continuation in required metadata")
      }
      continue
    }
    guard let match = schemaMatches(#"^([A-Za-z_][\w-]*):(?:[ \t]+(.*)|[ \t]*)$"#, content).first
    else { throw OrbitError("Unsupported or malformed top-level frontmatter") }
    current = match[1]
    guard seen.insert(match[1]).inserted else {
      throw OrbitError("Duplicate frontmatter key: " + match[1])
    }
    if formattingRequired.contains(match[1]) { fields[match[1]] = try formattingScalar(match[2]) }
  }
  throw OrbitError("Unclosed frontmatter")
}

func formattingUUID5(_ namespace: UUID, _ name: String) -> String {
  var tuple = namespace.uuid
  var input = withUnsafeBytes(of: &tuple) { Data($0) }
  input.append(Data(name.utf8))
  var bytes = Array(Insecure.SHA1.hash(data: input).prefix(16))
  bytes[6] = (bytes[6] & 15) | 80
  bytes[8] = (bytes[8] & 63) | 128
  let hex = bytes.map { String(format: "%02x", $0) }.joined()
  return [
    String(hex.prefix(8)), String(hex.dropFirst(8).prefix(4)), String(hex.dropFirst(12).prefix(4)),
    String(hex.dropFirst(16).prefix(4)), String(hex.suffix(12)),
  ].joined(separator: "-")
}

extension OrbitEngine {
  func formattingPrepare(_ root: URL, plan: JSONObject) throws -> (JSONObject, [JSONObject]) {
    guard Set(plan.keys).isSubset(of: ["changes", "request_id"]),
      let inputChanges = plan["changes"] as? [JSONObject], (1...50).contains(inputChanges.count)
    else { throw OrbitError("Format plan requires 1 to 50 changes") }
    guard let id = try readJSON(safe(root, ".orbit/vault.json"))["id"] as? String,
      let namespace = UUID(uuidString: id)
    else { throw OrbitError("Invalid Orbit identity") }
    var changes: [JSONObject] = []
    var receipts: [JSONObject] = []
    var seen: Set<String> = []
    for change in inputChanges {
      guard
        Set(change.keys).isSubset(of: [
          "path", "expected_sha256", "metadata", "expected_heads", "observations",
        ]), Set(["path", "expected_sha256", "metadata"]).isSubset(of: Set(change.keys))
      else {
        throw OrbitError("Each format change requires only path, expected_sha256 and metadata")
      }
      guard let path = change["path"] as? String else {
        throw OrbitError("Format path must be a string")
      }
      let target = try safe(root, path)
      guard path.split(separator: "/").joined(separator: "/") == path,
        !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }),
        target.pathExtension == "md", path != "ORBIT.md", !path.hasPrefix("Sources/assets/")
      else {
        throw OrbitError("Format requires public .md note paths, not configuration or assets")
      }
      guard seen.insert(path).inserted else { throw OrbitError("Duplicate target in format plan") }
      var isDirectory: ObjCBool = false
      guard try fileExists(atPath: target.path, isDirectory: &isDirectory), !isDirectory.boolValue
      else { throw OrbitError(path + ": formatting requires an existing note") }
      let raw = try readData(target)
      guard change["expected_sha256"] as? String == digest(raw) else {
        throw OrbitError(path + ": conflict; read the latest note and supply its SHA-256")
      }
      guard let supplied = change["metadata"] as? JSONObject,
        Set(supplied.keys).isSubset(of: ["title", "type", "summary"])
      else { throw OrbitError("Format metadata accepts only title, type and summary") }
      for value in supplied.values {
        guard let text = value as? String, !schemaTrim(text).isEmpty,
          text.rangeOfCharacter(from: formattingBreaks) == nil
        else { throw OrbitError("Format metadata values must be nonempty single-line strings") }
      }
      let header = try formattingHeader(raw)
      var additions: [String: String] = [:]
      var inserted = ""
      for key in formattingRequired {
        if let existing = header.fields[key] {
          if let supplied = supplied[key] as? String, !eEqual(supplied, existing) {
            throw OrbitError(path + ": preserve existing " + key)
          }
        } else if key == "id" {
          additions[key] = formattingUUID5(namespace, path)
        } else if let text = supplied[key] as? String {
          additions[key] = text
        } else {
          throw OrbitError(path + ": supply missing " + key + " based on the note")
        }
        if let value = additions[key] {
          inserted +=
            key + ": " + String(
              data: try JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              encoding: .utf8)! + header.newline
        }
      }
      let after: String
      if additions.isEmpty {
        after = String(decoding: raw, as: UTF8.self)
      } else if !header.frontmatter.isEmpty {
        let first = schemaLines(header.frontmatter, keepingEnds: true)[0]
        after =
          header.bom + first + inserted + String(header.frontmatter.dropFirst(first.count))
          + header.body
      } else {
        after =
          header.bom + "---" + header.newline + inserted + "---" + header.newline + header.body
      }
      receipts.append([
        "path": path, "added": additions, "before_sha256": digest(raw),
        "after_sha256": digest(Data(after.utf8)), "body_sha256": digest(Data(header.body.utf8)),
      ])
      var output: JSONObject = [
        "path": path, "expected_sha256": change["expected_sha256"]!, "content": after,
        "reason": "Add absent Orbit metadata; preserve existing bytes",
      ]
      for key in ["expected_heads", "observations"] {
        if let value = change[key] { output[key] = value }
      }
      changes.append(output)
    }
    return (["summary": "Format existing notes in place", "changes": changes], receipts)
  }

  func formatNotes(_ root: URL, plan: JSONObject, dryRun: Bool = true) throws -> JSONObject {
    try apply(root, plan: plan, dryRun: dryRun, formatMetadata: true)
  }
}
