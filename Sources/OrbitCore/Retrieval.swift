import CSQLite
import Darwin
import Foundation

struct RetrievalError: Error, CustomStringConvertible {
  let description: String
  let code: Int32
  init(_ message: String, _ code: Int32 = 0) {
    description = message
    self.code = code
  }
}
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private final class SearchDB {
  var pointer: OpaquePointer?
  init(_ url: URL) throws {
    let code = sqlite3_open(url.path, &pointer)
    guard code == SQLITE_OK else {
      let message =
        pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open search cache"
      if pointer != nil { sqlite3_close(pointer) }
      pointer = nil
      throw RetrievalError(message, code)
    }
    sqlite3_busy_timeout(pointer, 3000)
    chmod(url.path, 0o600)
  }
  deinit { close() }
  func close() {
    if pointer != nil {
      sqlite3_close(pointer)
      pointer = nil
    }
  }
  func execute(_ sql: String, _ values: [Any] = []) throws { _ = try query(sql, values) }
  func script(_ sql: String) throws {
    let code = sqlite3_exec(pointer, sql, nil, nil, nil)
    if code != SQLITE_OK { throw RetrievalError(String(cString: sqlite3_errmsg(pointer)), code) }
  }
  func query(_ sql: String, _ values: [Any] = []) throws -> [JSONObject] {
    var statement: OpaquePointer?
    let code = sqlite3_prepare_v2(pointer, sql, -1, &statement, nil)
    guard code == SQLITE_OK else {
      throw RetrievalError(String(cString: sqlite3_errmsg(pointer)), code)
    }
    defer { sqlite3_finalize(statement) }
    for (index, value) in values.enumerated() {
      let result: Int32
      if let value = value as? String {
        result = sqlite3_bind_text(statement, Int32(index + 1), value, -1, sqliteTransient)
      } else if value is NSNull {
        result = sqlite3_bind_null(statement, Int32(index + 1))
      } else if let value = value as? Double {
        result = sqlite3_bind_double(statement, Int32(index + 1), value)
      } else {
        result = sqlite3_bind_int64(statement, Int32(index + 1), Int64(eInt(value)))
      }
      guard result == SQLITE_OK else {
        throw RetrievalError(String(cString: sqlite3_errmsg(pointer)), result)
      }
    }
    var result: [JSONObject] = []
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else {
        throw RetrievalError(String(cString: sqlite3_errmsg(pointer)), step)
      }
      var row: JSONObject = [:]
      for column in 0..<sqlite3_column_count(statement) {
        let name = String(cString: sqlite3_column_name(statement, column))
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, column)
        case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, column))
        default: row[name] = NSNull()
        }
      }
      result.append(row)
    }
    return result
  }
  var rowID: Int { Int(sqlite3_last_insert_rowid(pointer)) }
}
struct OrbitPassage {
  let start: Int
  let end: Int
  let section: String
  let body: String
}
func notePassages(_ text: String) -> [OrbitPassage] {
  let lines = eLines(text)
  var start = 0
  var heading: [String] = []
  var fence: String? = nil
  var size = 0
  var result: [OrbitPassage] = []
  if lines.first?.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")) == "---",
    let end = lines.dropFirst().firstIndex(of: "---")
  {
    start = end + 1
  }
  var begin = start
  if start < lines.count {
    for i in start..<lines.count {
      let line = lines[i]
      let marker = eMatches("^\\s{0,3}(`{3,}|~{3,})", line).first?.dropFirst().first
      let title = fence == nil ? eMatches("^(#{1,6})\\s+(.+)", line).first : nil
      if let title {
        if i > begin, lines[begin..<i].contains(where: { !$0.isEmpty }) {
          result.append(
            OrbitPassage(
              start: begin + 1, end: i, section: heading.joined(separator: " / "),
              body: lines[begin..<i].joined(separator: "\n")))
        }
        let depth = title[1].count
        heading = Array(heading.prefix(depth - 1)) + [title[2]]
        begin = i
        size = 0
      }
      if let marker {
        if fence == nil {
          fence = marker
        } else if marker.first == fence?.first && marker.count >= (fence?.count ?? 0) {
          fence = nil
        }
      }
      size += line.unicodeScalars.count + 1
      if fence == nil && line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && size >= 1800
      {
        result.append(
          OrbitPassage(
            start: begin + 1, end: i + 1, section: heading.joined(separator: " / "),
            body: lines[begin...i].joined(separator: "\n")))
        begin = i + 1
        size = 0
      }
    }
  }
  if begin < lines.count, lines[begin...].contains(where: { !$0.isEmpty }) {
    result.append(
      OrbitPassage(
        start: begin + 1, end: lines.count, section: heading.joined(separator: " / "),
        body: lines[begin...].joined(separator: "\n")))
  }
  return result
}

extension OrbitEngine {
  func retrievalCachePath(_ root: URL) throws -> URL {
    let identity = eString(try readJSON(safe(root, ".orbit/vault.json"))["id"])
    let key = digest(Data((root.resolvingSymlinksInPath().path + "\0" + identity).utf8))
    let directory = cacheURL.resolvingSymlinksInPath()
    if directory.path == root.path || directory.path.hasPrefix(root.path + "/") {
      throw RetrievalError("Search cache must be outside the vault")
    }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent(key + ".sqlite3")
    if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
      throw RetrievalError("Search cache must not be a symlink")
    }
    return url
  }
  func retrievalInventory(_ root: URL) throws -> [(String, String)] {
    let blocked =
      replicationEnabled(root) ? Set(strings(try replicationInspect(root)["blocked_paths"])) : []
    var result: [(String, String)] = []
    func walk(_ folder: URL, _ prefix: String) throws {
      if !prefix.isEmpty { _ = try safe(root, prefix) }
      let children = try FileManager.default.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
      ).sorted { $0.lastPathComponent < $1.lastPathComponent }
      let dirs = try children.filter {
        try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
      }
      let files = children.filter { !dirs.contains($0) }
      for child in files {
        let name = child.lastPathComponent
        let path = prefix.isEmpty ? name : prefix + "/" + name
        guard !blocked.contains(path), name.lowercased().hasSuffix(".md"),
          !path.hasPrefix("Sources/assets/")
        else { continue }
        var info = stat()
        guard lstat(child.path, &info) == 0 else { throw RetrievalError("Cannot inspect " + path) }
        if info.st_mode & S_IFMT != S_IFREG { continue }
        let signature: [Any] = [
          Int64(info.st_dev), Int64(info.st_ino), Int64(info.st_size),
          Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
          Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec),
        ]
        let bytes = try JSONSerialization.data(
          withJSONObject: signature, options: [.fragmentsAllowed])
        let value = String(data: bytes, encoding: .utf8)!.replacingOccurrences(of: ",", with: ", ")
        result.append((path, value))
      }
      for child in dirs where !child.lastPathComponent.hasPrefix(".") {
        if (try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true {
          try walk(
            child, prefix.isEmpty ? child.lastPathComponent : prefix + "/" + child.lastPathComponent
          )
        }
      }
    }
    try walk(root, "")
    return result
  }
  func retrievalRefresh(_ root: URL, rebuild: Bool = false) throws -> JSONObject {
    do { return try retrievalRefreshChecked(root, rebuild: rebuild) } catch let error
      as RetrievalError
    { throw error } catch let error as OrbitError { throw error } catch {
      throw RetrievalError(String(describing: error))
    }
  }
  private func retrievalRefreshChecked(_ root: URL, rebuild: Bool) throws -> JSONObject {
    let path = try retrievalCachePath(root)
    var db: SearchDB
    var rebuild = rebuild
    do {
      db = try SearchDB(path)
      let version = eInt(try db.query("PRAGMA user_version").first?["user_version"])
      if version != 0 && version != 4 { rebuild = true }
    } catch let error as RetrievalError {
      guard [SQLITE_CORRUPT, SQLITE_NOTADB].contains(error.code & 0xff) else { throw error }
      if eExists(path) { try FileManager.default.removeItem(at: path) }
      db = try SearchDB(path)
    }
    if rebuild {
      try db.script(
        "DROP TABLE IF EXISTS search; DROP TABLE IF EXISTS passages; DROP TABLE IF EXISTS notes;")
    }
    try db.script(
      """
      CREATE TABLE IF NOT EXISTS notes(path TEXT PRIMARY KEY, signature TEXT, sha256 TEXT, identity TEXT, title TEXT, aliases TEXT, project TEXT, status TEXT, note_type TEXT, summary TEXT, schema_version TEXT, observed TEXT, topics TEXT);
      CREATE INDEX IF NOT EXISTS note_kind ON notes(note_type,status,project);
      CREATE TABLE IF NOT EXISTS passages(id INTEGER PRIMARY KEY, path TEXT, start INTEGER,end INTEGER,section TEXT,body TEXT);
      CREATE INDEX IF NOT EXISTS passage_path ON passages(path);
      CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(title,aliases,section,body,summary,tokenize='porter unicode61');
      PRAGMA user_version=4;
      """)
    let inventory = try retrievalInventory(root)
    let current = Dictionary(uniqueKeysWithValues: inventory)
    let stored = Dictionary(
      uniqueKeysWithValues: try db.query("SELECT path,signature FROM notes").map {
        (eString($0["path"]), eString($0["signature"]))
      })
    let changed = inventory.map { $0.0 }.filter { current[$0] != stored[$0] }
    let removed = Set(stored.keys).subtracting(current.keys)
    try db.execute("BEGIN")
    do {
      for path in changed + removed.sorted() {
        try db.execute(
          "DELETE FROM search WHERE rowid IN (SELECT id FROM passages WHERE path=?)", [path])
        try db.execute("DELETE FROM passages WHERE path=?", [path])
        try db.execute("DELETE FROM notes WHERE path=?", [path])
      }
      for path in changed {
        let raw = try Data(contentsOf: safe(root, path))
        guard var text = String(data: raw, encoding: .utf8) else {
          throw OrbitError("Invalid UTF-8")
        }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        let meta = metadata(text)
        let title =
          !truthy(meta["title"])
          ? eMatches("^#\\s+(.+)$", text, [.anchorsMatchLines]).first?[1]
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
          : pyString(meta["title"]!)
        let aliases = strings(meta["aliases"])
        let summary = pyString(meta["summary"] ?? "")
        try db.execute(
          "INSERT INTO notes VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
          [
            path, current[path] ?? "", digest(raw), pyString(meta["id"] ?? ""), title,
            eJSON(aliases).trimmingCharacters(in: .whitespacesAndNewlines),
            pyString(meta["project"] ?? ""), pyString(meta["status"] ?? "current"),
            pyString(meta["type"] ?? ""), summary,
            pyString(meta["schema_version"] ?? ""), pyString(meta["observed"] ?? ""),
            eJSON(strings(meta["topics"])).trimmingCharacters(in: .whitespacesAndNewlines),
          ])
        for passage in notePassages(text) {
          try db.execute(
            "INSERT INTO passages(path,start,end,section,body) VALUES(?,?,?,?,?)",
            [path, passage.start, passage.end, passage.section, passage.body])
          let id = db.rowID
          try db.execute(
            "INSERT INTO search(rowid,title,aliases,section,body,summary) VALUES(?,?,?,?,?,?)",
            [id, title, aliases.joined(separator: " "), passage.section, passage.body, summary])
        }
      }
      try db.execute("COMMIT")
    } catch {
      try? db.execute("ROLLBACK")
      throw error
    }
    return [
      "mode": "sqlite-fts5-passages", "cache": path.path, "notes": current.count,
      "passages": eInt(try db.query("SELECT count(*) AS count FROM passages").first?["count"]),
      "inventoried": current.count, "reparsed": changed.count, "deleted": removed.count,
    ]
  }
  func retrievalCatalog(
    _ root: URL, scope: String? = nil, limit: Int = 50, offset: Int = 0, noteType: String? = nil,
    status: String? = nil
  ) throws -> JSONObject {
    let freshness = try retrievalRefresh(root)
    let db = try SearchDB(URL(fileURLWithPath: eString(freshness["cache"])))
    var sql = "FROM notes WHERE path NOT IN ('ORBIT.md')"
    var params: [Any] = []
    if let noteType {
      sql += " AND note_type=?"
      params.append(noteType)
    } else {
      sql += " AND note_type!='schema'"
    }
    if let status {
      sql += " AND status=?"
      params.append(status)
    }
    if let scope {
      let prefix = scope.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
      sql +=
        " AND (project=? OR path=? OR substr(path,1,?)=? OR EXISTS (SELECT 1 FROM json_each(notes.topics) WHERE value=?))"
      params += [scope, scope, prefix.unicodeScalars.count, prefix, scope]
    }
    let total = eInt(try db.query("SELECT count(*) AS count " + sql, params).first?["count"])
    let offset = max(0, offset)
    let rows = try db.query(
      "SELECT * " + sql + " ORDER BY note_type!='map',lower(title),path LIMIT ? OFFSET ?",
      params + [max(1, min(limit, 200)), offset])
    let entries: [JSONObject] = rows.map { r in
      [
        "id": eString(r["identity"]).isEmpty ? NSNull() : r["identity"]!, "path": r["path"] ?? "",
        "title": r["title"] ?? "", "type": r["note_type"] ?? "", "status": r["status"] ?? "",
        "summary": r["summary"] ?? "",
        "project": eString(r["project"]).isEmpty ? NSNull() : r["project"]!,
        "topics": (try? JSONSerialization.jsonObject(with: Data(eString(r["topics"]).utf8))) ?? [],
        "schema_version": eString(r["schema_version"]).isEmpty ? NSNull() : r["schema_version"]!,
        "observed": eString(r["observed"]).isEmpty ? NSNull() : r["observed"]!,
      ]
    }
    return [
      "total": total, "entries": entries, "offset": offset, "more": offset + entries.count < total,
      "markdown": "# Knowledge catalog\n\n"
        + entries.map {
          "- [[" + eString($0["path"]) + "|" + eString($0["title"]) + "]] — "
            + eString($0["summary"])
        }.joined(separator: "\n") + "\n", "written": false, "freshness": freshness,
    ]
  }
  func retrievalSearch(
    _ root: URL, query: String, limit: Int = 8, scope: String? = nil, noteType: String? = nil,
    status: String? = nil
  ) throws -> JSONObject {
    do {
      return try retrievalSearchChecked(
        root, query: query, limit: limit, scope: scope, noteType: noteType, status: status)
    } catch let error as RetrievalError { throw error } catch let error as OrbitError {
      throw error
    } catch { throw RetrievalError(String(describing: error)) }
  }
  private func retrievalSearchChecked(
    _ root: URL, query: String, limit: Int = 8, scope: String? = nil, noteType: String? = nil,
    status: String? = nil
  ) throws -> JSONObject {
    var terms: [String] = []
    for token in tokens(query) where !terms.contains(token) { terms.append(token) }
    var freshness = try retrievalRefresh(root)
    if terms.isEmpty {
      return [
        "mode": "sqlite-fts5-passages", "total": 0, "results": [], "freshness": freshness,
        "coverage": ["state": "complete", "semantic": false, "truncated": false],
      ]
    }
    let match = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(
      separator: " OR ")
    let bounded = max(1, min(limit, 100))
    var selected: [JSONObject] = []
    var overview: [String: JSONObject] = [:]
    var best = Set<String>()
    func aliases(_ row: JSONObject) -> [String] {
      (try? JSONSerialization.jsonObject(with: Data(eString(row["aliases"]).utf8))) as? [String]
        ?? []
    }
    func ordering(_ a: JSONObject, _ b: JSONObject) -> Bool {
      let exactA = ([eString(a["title"])] + aliases(a)).map { casefold($0) }.contains(
        casefold(query).trimmingCharacters(in: .whitespacesAndNewlines))
      let exactB = ([eString(b["title"])] + aliases(b)).map { casefold($0) }.contains(
        casefold(query).trimmingCharacters(in: .whitespacesAndNewlines))
      if exactA != exactB { return exactA }
      let rankA = a["rank"] as? Double ?? 0
      let rankB = b["rank"] as? Double ?? 0
      return rankA == rankB ? eString(a["path"]) < eString(b["path"]) : rankA < rankB
    }
    for attempt in 0..<2 {
      let db = try SearchDB(URL(fileURLWithPath: eString(freshness["cache"])))
      try db.execute("BEGIN")
      var sql =
        "SELECT n.*,p.start,p.end,p.section,p.id AS passage_id,bm25(search,5,4,2,1,3) AS rank FROM search JOIN passages p ON p.id=search.rowid JOIN notes n ON n.path=p.path WHERE search MATCH ? AND n.path NOT IN ('ORBIT.md')"
      var params: [Any] = [match]
      if let noteType {
        sql += " AND n.note_type=?"
        params.append(noteType)
      } else {
        sql += " AND n.note_type!='schema'"
      }
      if let status {
        sql += " AND n.status=?"
        params.append(status)
      }
      if let scope {
        let prefix = scope.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
        sql += " AND (n.project=? OR n.path=? OR substr(n.path,1,?)=?)"
        params += [scope, scope, prefix.unicodeScalars.count, prefix]
      }
      best = []
      selected = []
      overview = [:]
      for row in try db.query(sql + " ORDER BY rank,n.path,p.start", params) {
        let path = eString(row["path"])
        if best.contains(path) { continue }
        best.insert(path)
        selected.append(row)
        selected.sort(by: ordering)
        if selected.count > bounded { selected.removeLast() }
      }
      for index in selected.indices {
        let path = eString(selected[index]["path"])
        selected[index]["body"] =
          try db.query("SELECT body FROM passages WHERE id=?", [selected[index]["passage_id"] ?? 0])
          .first?["body"] ?? ""
        if let opening = try db.query(
          "SELECT * FROM passages WHERE path=? ORDER BY start LIMIT 1", [path]
        ).first {
          overview[path] = opening
        }
      }
      db.close()
      let stale = try selected.contains {
        try digest(Data(contentsOf: safe(root, eString($0["path"])))) != eString($0["sha256"])
      }
      if !stale { break }
      if attempt == 1 {
        throw RetrievalError("Retrieved evidence changed repeatedly; retry against current files")
      }
      freshness = try retrievalRefresh(root, rebuild: true)
    }
    var result: JSONObject = [
      "mode": "sqlite-fts5-passages", "total": best.count, "results": [JSONObject](),
      "freshness": freshness,
      "coverage": ["state": "complete", "semantic": false, "truncated": false],
      "hint":
        "Read evidence and adjacent qualifications before answering. Lexical retrieval has no semantic matching.",
    ]
    var results: [JSONObject] = []
    var truncated = false
    for row in selected {
      let path = eString(row["path"])
      let start = eInt(row["start"])
      var excerpts: [Int: JSONObject] = [start: row]
      if let opening = overview[path] { excerpts[eInt(opening["start"])] = opening }
      let matchTokens = Set(
        tokens(
          eString(row["body"]) + " " + eString(row["title"]) + " " + eString(row["summary"]) + " "
            + aliases(row).joined(separator: " ")))
      var candidate: JSONObject = [
        "path": path, "title": row["title"] ?? "",
        "id": eString(row["identity"]).isEmpty ? NSNull() : row["identity"]!,
        "project": eString(row["project"]).isEmpty ? NSNull() : row["project"]!,
        "status": row["status"] ?? "", "type": row["note_type"] ?? "",
        "schema_version": eString(row["schema_version"]).isEmpty
          ? NSNull() : row["schema_version"]!,
        "observed": eString(row["observed"]).isEmpty ? NSNull() : row["observed"]!,
        "sha256": row["sha256"] ?? "", "summary": row["summary"] ?? "",
        "score": -(row["rank"] as? Double ?? 0),
        "matched": terms.filter { matchTokens.contains($0) }, "start": excerpts.keys.min() ?? start,
        "end": excerpts.values.map { eInt($0["end"]) }.max() ?? 0, "section": row["section"] ?? "",
        "snippets": [JSONObject](),
      ]
      results.append(candidate)
      result["results"] = results
      if eJSON(result).unicodeScalars.count > 12000 {
        results.removeLast()
        truncated = true
        break
      }
      var snippets: [JSONObject] = []
      var exhausted = false
      for excerpt in excerpts.sorted(by: { $0.key < $1.key }).map({ $0.value }) {
        for (offset, line) in eLines(eString(excerpt["body"])).enumerated() {
          snippets.append(["line": eInt(excerpt["start"]) + offset, "text": line])
          candidate["snippets"] = snippets
          results[results.count - 1] = candidate
          result["results"] = results
          if eJSON(result).unicodeScalars.count > 12000 {
            snippets.removeLast()
            candidate["snippets"] = snippets
            results[results.count - 1] = candidate
            truncated = true
            exhausted = true
            break
          }
        }
        if exhausted { break }
      }
      if exhausted { break }
    }
    result["results"] = results
    result["coverage"] = ["state": "complete", "semantic": false, "truncated": truncated]
    return result
  }
}
