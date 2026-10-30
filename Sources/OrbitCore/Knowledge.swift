import CoreFoundation
import Foundation

private let integrationStages = ["captured", "extracted", "integrated", "verified"]
extension OrbitEngine {
  func knowledgeRelations(_ root: URL, target: String? = nil) throws -> JSONObject {
    let notes = try readableNotes(root)
    let table = identities(notes)
    var selected: String? = nil
    var result: [JSONObject] = []
    if let target, !target.isEmpty {
      let matches = resolve(target, table: table)
      guard matches.count == 1 else { throw OrbitError("Relation target must resolve uniquely") }
      selected = matches[0]
    }
    let pattern =
      "^\\s*-\\s+(supports|contradicts|supersedes|depends[-_]on|derived[-_]from|related[-_]to|relates_to|applies_to|part_of|learned_from|informed_by)\\s+\\[\\[([^\\]]+)\\]\\]\\s*[—–-]\\s*(?:(asserted|inferred):\\s*)?(\\S.*)$"
    for note in notes {
      var fence: Character? = nil
      var section = ""
      for (index, line) in eLines(eString(note["text"])).enumerated() {
        if let marker = eMatches("^\\s*(`{3,}|~{3,})", line).first?[1].first {
          if fence == nil { fence = marker } else if fence == marker { fence = nil }
          continue
        }
        if fence != nil { continue }
        if let heading = eMatches("^#{1,6}\\s+(.+?)\\s*#*$", line).first {
          section = heading[1].lowercased()
        }
        guard let match = eMatches(pattern, line).first else { continue }
        let kind = match[1]
        let link = match[2]
        let evidence = match[4]
        let basis =
          match[3].isEmpty
          ? section == "possible connections"
            && !eMatches("\\binferred\\b", evidence, [.caseInsensitive]).isEmpty
            ? "inferred" : "recorded" : match[3]
        let destinations = resolve(
          link.components(separatedBy: "|")[0].components(separatedBy: "#")[0].trimmingCharacters(
            in: .whitespacesAndNewlines), table: table)
        if let selected, selected != eString(note["path"]), !destinations.contains(selected) {
          continue
        }
        result.append([
          "source": note["path"] ?? "",
          "target": destinations.count == 1 ? destinations[0] as Any : NSNull(), "link": link,
          "type": kind, "basis": basis, "evidence": evidence, "line": index + 1,
          "sha256": note["sha256"] ?? "",
          "resolution": destinations.count == 1
            ? "resolved" : destinations.isEmpty ? "missing" : "ambiguous",
        ])
      }
    }
    return [
      "relations": result, "total": result.count,
      "hint": "Relations are recorded claims, not independently established facts.",
    ]
  }
  func knowledgeRecordPath(_ root: URL, sha: String) throws -> URL {
    guard !eMatches("^[0-9a-f]{64}$", sha).isEmpty else {
      throw OrbitError("source_sha256 must be a SHA-256 digest")
    }
    return try safe(root, ".orbit/integrations/" + sha + ".json")
  }
  func knowledgeCheckSource(_ root: URL, record: JSONObject) throws {
    let path = eString(record["source_path"])
    guard path.hasPrefix("Sources/assets/"),
      try digest(readData(safe(root, path))) == eString(record["source_sha256"])
    else { throw OrbitError("Integration source is missing or changed") }
  }
  func knowledgeValidateRecord(_ root: URL, record: JSONObject, path: URL) throws -> JSONObject {
    guard eInt(record["schema"]) == 1, integrationStages.contains(eString(record["stage"])),
      eInt(record["version"]) >= 1,
      let versionNumber = record["version"] as? NSNumber,
      CFGetTypeID(versionNumber) != CFBooleanGetTypeID(),
      !["d", "f"].contains(String(cString: versionNumber.objCType))
    else { throw OrbitError("Invalid integration schema, stage, or version") }
    guard try knowledgeRecordPath(root, sha: eString(record["source_sha256"])) == path else {
      throw OrbitError("Integration source identity does not match filename")
    }
    guard let source = record["source_path"] as? String, source.hasPrefix("Sources/assets/") else {
      throw OrbitError("Invalid integration source path")
    }
    _ = try safe(root, source)
    guard let coverage = record["coverage"] as? JSONObject,
      ["unknown", "full", "partial"].contains(eString(coverage["status"])),
      coverage["description"] is String
    else { throw OrbitError("Invalid integration coverage") }
    for key in ["deferred", "errors"] {
      guard record[key] is [String] else { throw OrbitError(key + " must be a list of strings") }
    }
    for key in ["notes", "extraction"] {
      guard let evidence = (record[key] ?? []) as? [JSONObject] else {
        throw OrbitError(key + " must be a list of evidence records")
      }
      for item in evidence {
        guard let path = item["path"] as? String, let hash = item["sha256"] as? String,
          !eMatches("^[0-9a-f]{64}$", hash).isEmpty
        else { throw OrbitError("Invalid " + key + " path or sha256") }
        let target = try safe(root, path)
        guard target.pathExtension.lowercased() == "md", ePublic(path) else {
          throw OrbitError("Integration evidence must be public Markdown")
        }
      }
    }
    guard let operations = (record["operations"] ?? []) as? [String],
      operations.allSatisfy({ !eMatches("^[a-f0-9-]{36}$", $0).isEmpty })
    else { throw OrbitError("Invalid integration operations") }
    guard record["verification"] is [Any] else {
      throw OrbitError("Integration verification must be a list")
    }
    return record
  }
  func knowledgeLoadRecord(_ root: URL, path: URL) throws -> JSONObject {
    do { return try knowledgeValidateRecord(root, record: readJSON(path), path: path) } catch let
      error as OrbitError
    { throw error } catch is CancellationError { throw CancellationError() } catch {
      throw OrbitError(
        "Cannot read integration record " + path.lastPathComponent + ": "
          + String(describing: error))
    }
  }
  func knowledgeInitCapture(_ root: URL, receipt: JSONObject) throws -> JSONObject {
    let path = try knowledgeRecordPath(root, sha: eString(receipt["sha256"]))
    return try withLock(root) {
      try migrationEnsureWritable(root)
      if replicationEnabled(root),
        strings(try replicationReconcile(root)["blocked_paths"]).contains(
          try eRelative(path, root: root))
      {
        throw OrbitError("Source integration has conflicting revisions; inspect orbit_sync history")
      }
      if try eExists(path) {
        let record = try knowledgeLoadRecord(root, path: path)
        try knowledgeCheckSource(root, record: record)
        return record
      }
      let record: JSONObject = [
        "schema": 1, "source_sha256": receipt["sha256"] ?? "", "source_path": receipt["path"] ?? "",
        "version": 1, "stage": "captured", "coverage": ["status": "unknown", "description": ""],
        "extraction": [], "notes": [], "operation": NSNull(), "operations": [], "verification": [],
        "deferred": [], "errors": [], "updated": now(),
      ]
      try knowledgeCheckSource(root, record: record)
      _ = try knowledgeSaveRecord(root, path: path, value: record)
      return record
    }
  }
  func knowledgeSaveRecord(_ root: URL, path: URL, value: JSONObject, controls: JSONObject = [:])
    throws -> JSONObject?
  {
    if !replicationEnabled(root) {
      try atomic(path, knowledgeEncodeRecord(value, path: path, controls: controls))
      return nil
    }
    var write: JSONObject = [
      "path": try eRelative(path, root: root),
      "before": try eExists(path) ? try eText(path) as Any : NSNull(),
      "after": String(
        data: try knowledgeEncodeRecord(value, path: path, controls: controls), encoding: .utf8)!,
      "reason": "Update source integration evidence",
    ]
    for field in ["expected_heads", "observations"] {
      if let value = controls[field] { write[field] = value }
    }
    return try replicationCommit(
      root, writes: [write], requestID: controls["request_id"] as? String,
      requestDigest: controls.isEmpty ? nil : try requestDigest(controls), dryRun: false)
  }
  func knowledgeIntegration(_ root: URL, record: JSONObject? = nil) throws -> JSONObject {
    guard let record else {
      var records: [JSONObject] = []
      var errors: [JSONObject] = []
      let folder = try safe(root, ".orbit/integrations")
      let sync = replicationEnabled(root) ? try replicationInspect(root) : [:]
      for path in try eChildren(folder, suffix: ".json") {
        try Task.checkCancellation()
        let relative = try eRelative(path, root: root)
        do {
          if strings(sync["blocked_paths"]).contains(relative) {
            errors.append([
              "kind": "integration-conflict", "path": relative,
              "hint": "Use orbit_sync history and explicitly resolve the preserved versions.",
            ])
            continue
          }
          var entry = try knowledgeLoadRecord(root, path: safe(root, relative))
          if !sync.isEmpty { entry["heads"] = (sync["heads"] as? JSONObject)?[relative] ?? [] }
          records.append(entry)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          errors.append([
            "kind": "malformed-integration", "path": relative, "error": String(describing: error),
          ])
        }
      }
      return ["records": records, "total": records.count, "errors": errors]
    }
    let path = try knowledgeRecordPath(root, sha: eString(record["source_sha256"]))
    let allowed = Set([
      "source_sha256", "expected_version", "stage", "coverage", "extraction", "notes", "operation",
      "operations", "verification", "deferred", "errors", "request_id", "expected_heads",
      "observations",
    ])
    guard Set(record.keys).isSubset(of: allowed) else {
      throw OrbitError("Unknown integration update fields")
    }
    return try withLock(root) {
      try migrationEnsureWritable(root)
      if replicationEnabled(root) {
        if let requestID = record["request_id"] as? String,
          let receipt = try replicationRetry(
            root, requestID: requestID, requestDigest: try requestDigest(record))
        {
          return receipt
        }
        _ = try replicationReconcile(root)
      }
      guard try eExists(path) else { throw OrbitError("Capture the source before integration") }
      let current = try knowledgeLoadRecord(root, path: path)
      try knowledgeCheckSource(root, record: current)
      let updates = record.filter {
        !["source_sha256", "expected_version", "request_id", "expected_heads", "observations"]
          .contains($0.key)
      }
      let unchanged = updates.allSatisfy { eEqual(current[$0.key], $0.value) }
      guard unchanged || eEqual(record["expected_version"], current["version"]) else {
        throw OrbitError("Integration version conflict; read the latest record")
      }
      var candidate = current.merging(updates, uniquingKeysWith: { $1 })
      _ = try knowledgeValidateRecord(root, record: candidate, path: path)
      let stage = eString(candidate["stage"])
      let oldStage = eString(current["stage"])
      guard let step = integrationStages.firstIndex(of: stage),
        let previousStep = integrationStages.firstIndex(of: oldStage),
        step == previousStep || step == previousStep + 1
      else { throw OrbitError("Integration stages must advance one step at a time") }
      for key in ["deferred", "errors"] {
        guard candidate[key] is [String] else {
          throw OrbitError(key + " must be a list of strings")
        }
      }
      if stage != "captured" {
        let coverage = candidate["coverage"] as? JSONObject ?? [:]
        guard ["full", "partial"].contains(eString(coverage["status"])),
          let description = coverage["description"] as? String,
          !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw OrbitError("Extraction needs full/partial coverage with an explanation") }
        guard let extraction = candidate["extraction"] as? [JSONObject], !extraction.isEmpty else {
          throw OrbitError("Extraction requires saved note path and sha256 evidence")
        }
        for evidence in extraction {
          guard let path = evidence["path"] as? String, let hash = evidence["sha256"] as? String,
            try eString(read(root, path: path, count: 1)["sha256"]) == hash
          else { throw OrbitError("Extraction evidence is invalid or changed") }
        }
      }
      if ["integrated", "verified"].contains(stage) {
        guard let notes = candidate["notes"] as? [JSONObject], !notes.isEmpty else {
          throw OrbitError("Integration requires affected notes")
        }
        var operations = strings(candidate["operations"])
        if operations.isEmpty, !eString(candidate["operation"]).isEmpty {
          operations = [eString(candidate["operation"])]
        }
        if updates["operation"] != nil && updates["operations"] == nil {
          operations = [eString(updates["operation"])]
        }
        guard !operations.isEmpty,
          operations.allSatisfy({ !eMatches("^[a-f0-9-]{36}$", $0).isEmpty })
        else { throw OrbitError("Integration requires committed operations") }
        var committed: [String: String] = [:]
        for operation in operations {
          var journalPath = try safe(root, ".orbit/operations/" + operation + ".json")
          if try !eExists(journalPath) {
            journalPath = try safe(root, ".orbit/migrations/" + operation + ".json")
          }
          let journal =
            try eExists(journalPath)
            ? try readJSON(journalPath) : try replicationOperation(root, id: operation)
          guard eString(journal["status"]) == "committed" else {
            throw OrbitError("Integration operation is not committed")
          }
          for write in eObjects(journal["writes"]) {
            if let content = write["after"] as? String {
              committed[eString(write["path"])] = digest(Data(content.utf8))
            }
          }
        }
        candidate["operations"] = operations
        guard notes.allSatisfy({ $0["path"] is String && $0["sha256"] is String }) else {
          throw OrbitError("Affected notes require path and sha256")
        }
        guard Set(notes.map { eString($0["path"]) }).count == notes.count else {
          throw OrbitError("Affected notes must be unique")
        }
        for note in notes {
          let path = eString(note["path"])
          let hash = eString(note["sha256"])
          let live = try read(root, path: path, count: 1)
          guard eString(live["sha256"]) == hash, committed[path] == hash else {
            throw OrbitError("Integrated note does not match committed operation and live content")
          }
        }
      }
      if stage == "verified" {
        guard let checks = candidate["verification"] as? [JSONObject], !checks.isEmpty else {
          throw OrbitError("Verification requires recall queries and expected paths")
        }
        var verified = Set<String>()
        let expected = Set(eObjects(candidate["notes"]).map { eString($0["path"]) })
        for check in checks {
          guard let query = check["query"] as? String,
            !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let paths = check["paths"] as? [String], !paths.isEmpty
          else { throw OrbitError("Verification needs a query and expected paths") }
          let found = Set(
            eObjects(try search(root, query: query, limit: 8)["results"]).map {
              eString($0["path"])
            })
          guard Set(paths).isSubset(of: found.intersection(expected)) else {
            throw OrbitError("Recall verification did not find expected integrated notes")
          }
          verified.formUnion(paths)
        }
        guard verified == expected else {
          throw OrbitError("Recall verification must cover all affected notes")
        }
        if var migration = candidate["migration"] as? JSONObject,
          eBool(migration["verification_stale"])
        {
          migration["verification_stale"] = false
          candidate["migration"] = migration
        }
      }
      if unchanged && record["expected_heads"] == nil && strings(record["observations"]).isEmpty {
        return current
      }
      candidate["version"] = eInt(candidate["version"]) + 1
      candidate["updated"] = now()
      if let receipt = try knowledgeSaveRecord(root, path: path, value: candidate, controls: record)
      {
        candidate["receipt"] = receipt
      }
      return candidate
    }
  }
  func knowledgeMaintain(_ root: URL, limit: Int = 20) throws -> JSONObject {
    let notes = try scan(root)
    var flags = try issues(notes, root: root).map { value -> JSONObject in
      var value = value
      value["priority"] = 1
      return value
    }
    for relation in eObjects(try knowledgeRelations(root)["relations"])
    where eString(relation["resolution"]) != "resolved" {
      flags.append([
        "kind": "unresolved-relation", "path": relation["source"] ?? "",
        "line": relation["line"] ?? 0, "priority": 1,
      ])
    }
    let integrations = try knowledgeIntegration(root)
    flags += eObjects(integrations["errors"]).map { value in
      var value = value
      value["priority"] = 1
      return value
    }
    for record in eObjects(integrations["records"]) {
      do { try knowledgeCheckSource(root, record: record) } catch is CancellationError {
        throw CancellationError()
      } catch {
        flags.append([
          "kind": "integration-source-changed", "source_sha256": record["source_sha256"] ?? "",
          "priority": 1,
        ])
      }
      if eString(record["stage"]) != "verified"
        || eString((record["coverage"] as? JSONObject)?["status"]) != "full"
        || !strings(record["deferred"]).isEmpty || !strings(record["errors"]).isEmpty
      {
        flags.append([
          "kind": "incomplete-integration", "source_sha256": record["source_sha256"] ?? "",
          "stage": record["stage"] ?? "", "coverage": record["coverage"] ?? [:], "priority": 2,
        ])
      }
      for role in ["notes", "extraction"] {
        for note in eObjects(record[role]) {
          var changed = true
          do {
            changed =
              try eString(read(root, path: eString(note["path"]), count: 1)["sha256"])
              != eString(note["sha256"])
          } catch is CancellationError { throw CancellationError() } catch {}
          if changed {
            flags.append([
              "kind": "integration-evidence-changed", "evidence_role": role,
              "path": note["path"] ?? "", "source_sha256": record["source_sha256"] ?? "",
              "priority": 1,
            ])
          }
        }
      }
    }
    for note in notes {
      let meta = note["meta"] as? JSONObject ?? [:]
      if !eString(meta["repository"]).isEmpty && eString(meta["revision"]).isEmpty
        && eString(meta["observed"]).isEmpty
      {
        flags.append(["kind": "missing-code-provenance", "path": note["path"] ?? "", "priority": 3])
      }
    }
    flags.sort { a, b in
      if eInt(a["priority"]) != eInt(b["priority"]) {
        return eInt(a["priority"]) < eInt(b["priority"])
      }
      if eString(a["path"]) != eString(b["path"]) { return eString(a["path"]) < eString(b["path"]) }
      return eString(a["kind"]) < eString(b["kind"])
    }
    return [
      "total": flags.count, "candidates": Array(flags.prefix(max(1, min(limit, 100)))),
      "written": false,
      "hint":
        "Mechanical signals only. Repository freshness and contradictions require source inspection.",
    ]
  }
}

private func knowledgeEncodeRecord(_ value: JSONObject, path: URL, controls: JSONObject) throws
  -> Data
{
  let old: OrderedJSON? = try eExists(path) ? try OrderedJSON.parse(readData(path)) : nil
  let request = Thread.current.threadDictionary["orbit.orderedRequest"] as? OrderedJSON
  let initialKeys = [
    "schema", "source_sha256", "source_path", "version", "stage", "coverage", "extraction", "notes",
    "operation", "operations", "verification", "deferred", "errors", "updated",
  ]
  func shape(_ value: Any, old: OrderedJSON?) -> OrderedJSON {
    if let object = value as? JSONObject {
      var keys: [String] = []
      if let old, case .object(let pairs) = old {
        keys = pairs.map { $0.0 }.filter { object[$0] != nil }
      }
      keys += object.keys.filter { !keys.contains($0) }.sorted()
      return .object(keys.map { ($0, shape(object[$0]!, old: old?[$0])) })
    }
    if let array = value as? [Any] {
      let previous: [OrderedJSON]
      if let old, case .array(let values) = old { previous = values } else { previous = [] }
      return .array(
        array.enumerated().map {
          shape($0.element, old: $0.offset < previous.count ? previous[$0.offset] : nil)
        })
    }
    return .scalar(value)
  }
  var keys: [String]
  if let old, case .object(let pairs) = old {
    keys = pairs.map { $0.0 }.filter { value[$0] != nil }
  } else {
    keys = initialKeys.filter { value[$0] != nil }
  }
  keys += value.keys.filter { !isInternalJSONField($0,in:value) && !keys.contains($0) }.sorted()
  let ordered = OrderedJSON.object(
    keys.map { key in
      if let previous = old?[key] {
        if key == "migration", let migration = value[key] as? JSONObject,
           migration["verification_stale"] as? Bool == false {
          return (key,previous.setting("verification_stale",.scalar(false)))
        }
        if !initialKeys.contains(key) || (controls[key] == nil && !["version","updated","operations"].contains(key)) {
          return (key,previous)
        }
      }
      if controls[key] != nil, let incoming = request?[key] {
        return (key, shape(value[key]!, old: incoming))
      }
      if old == nil && key == "coverage", let coverage = value[key] as? JSONObject {
        return (
          key,
          .object(
            ["status", "description"].compactMap { name in
              coverage[name].map { (name, OrderedJSON.sorted($0)) }
            })
        )
      }
      return (key, shape(value[key]!, old: old?[key]))
    })
  return Data((try ordered.rendered(pretty: true) + "\n").utf8)
}
