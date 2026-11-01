import Foundation

/// Experimental read-only projection. It is neither a sync replica nor write authority.
/// Queries use retained bytes and never promise current provider coverage.
public final class OrbitRetrievalSnapshot: Sendable {
  public struct Line: Codable, Equatable, Sendable {
    public let number: Int
    public let text: String
  }
  public struct Evidence: Codable, Sendable {
    public let path: String
    public let noteID: String?
    public let title: String
    public let sha256: String
    public let heads: [String]
    public let section: String
    public let lines: [Line]
    public let passageComplete: Bool
  }
  public struct Result: Codable, Sendable {
    public let orbitID: String
    public let snapshotID: String
    public let capturedAt: String
    public let freshness: String
    public let capturedCoverage: String
    public let excludedPaths: [String]
    public let totalMatchingNotes: Int
    public let truncated: Bool
    public let evidence: [Evidence]
  }
  struct Document: Codable, Sendable {
    let path: String
    let bytes: Data
    let sha256: String
    let heads: [String]
  }
  struct Archive: Codable, Sendable {
    let schema: Int
    let orbitID: String
    let snapshotID: String
    let capturedAt: String
    let coverage: String
    let excludedPaths: [String]
    let documents: [Document]
  }
  private struct IndexedPassage: Sendable {
    let document: Int
    let passage: OrbitPassage
    let frequencies: [String: Int]
    let sectionTerms: Set<String>
    let length: Int
  }
  private let archive: Archive
  private let passages: [IndexedPassage]
  private let postings: [String: [Int]]
  private let titles: [String]
  private let names: [[String]]
  private let projects: [String]
  private let noteIDs: [String?]
  public var orbitID: String { archive.orbitID }
  public var snapshotID: String { archive.snapshotID }
  public var noteCount: Int { archive.documents.count }

  init(archive: Archive) throws {
    guard archive.schema == 1, UUID(uuidString: archive.orbitID) != nil,
      UUID(uuidString: archive.snapshotID) != nil,
      ["complete", "partial"].contains(archive.coverage),
      Set(archive.documents.map { OrbitByteString($0.path) }).count == archive.documents.count
    else { throw OrbitError("Invalid retrieval snapshot") }
    var passages: [IndexedPassage] = []
    var postings: [String: [Int]] = [:]
    var titles: [String] = [], names: [[String]] = [], projects: [String] = []
    var noteIDs: [String?] = []
    for (index, document) in archive.documents.enumerated() {
      guard digest(document.bytes) == document.sha256,
        var text = String(data: document.bytes, encoding: .utf8),
        ePublic(document.path), !document.path.hasPrefix("/"),
        !document.path.split(separator: "/").contains(".."),
        document.path.lowercased().hasSuffix(".md"),
        !document.path.hasPrefix("Sources/assets/")
      else { throw OrbitError("Invalid retrieval snapshot source") }
      if text.hasPrefix("\u{feff}") { text.removeFirst() }
      let meta = metadata(text)
      let title = meta["title"] as? String
        ?? eMatches("^#\\s+(.+)$", text, [.anchorsMatchLines]).first?[1]
        ?? document.path
      titles.append(title)
      names.append(([title] + strings(meta["aliases"])).map(casefold))
      projects.append(eString(meta["project"]))
      noteIDs.append(meta["id"] as? String)
      let noteSections = notePassages(text)
      func content(_ passage: OrbitPassage) -> String {
        var fence: String?
        var lines: [String] = []
        for line in eLines(passage.body) {
          let marker = eMatches("^\\s{0,3}(`{3,}|~{3,})", line).first?.dropFirst().first
          if let marker {
            if fence == nil { fence = marker }
            else if marker.first == fence?.first && marker.count >= (fence?.count ?? 0) { fence = nil }
          } else if fence == nil && !eMatches("^#{1,6}\\s+", line).isEmpty { continue }
          lines.append(line)
        }
        return lines.joined(separator: "\n")
      }
      let hasContent = noteSections.contains { !content($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      let nameTerms = Set(Self.terms(([title] + strings(meta["aliases"])).joined(separator: " ")))
      for passage in noteSections {
        let body = content(passage)
        if hasContent && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
        let terms = Self.terms(body)
        let sectionTerms = Set(Self.terms(passage.section))
        let frequencies = Dictionary(terms.map { ($0, 1) }, uniquingKeysWith: +)
        for term in Set(frequencies.keys).union(nameTerms).union(sectionTerms) { postings[term, default: []].append(passages.count) }
        passages.append(IndexedPassage(document: index, passage: passage,
          frequencies: frequencies, sectionTerms: sectionTerms, length: terms.count))
      }
    }
    self.archive = archive
    self.passages = passages
    self.postings = postings
    self.titles = titles
    self.names = names
    self.projects = projects
    self.noteIDs = noteIDs
  }

  private static func terms(_ text: String) -> [String] {
    let questionWords: Set<String> = ["can", "could", "would", "should", "do", "does", "did", "please"]
    return tokens(text).filter { !questionWords.contains($0) }
  }

  /// Bounds serialized UTF-8 evidence bytes, not model tokens. Hosts must apply their tokenizer.
  /// An explicit path allows a pinned-note read without inventing query relevance.
  public func retrieve(
    query: String, limit: Int = 3, scope: String? = nil, path: String? = nil,
    maximumBytes: Int = 12_000
  ) throws -> Result {
    try Task.checkCancellation()
    let terms = Set(Self.terms(query))
    let exact = casefold(query.trimmingCharacters(in: .whitespacesAndNewlines))
    var candidates = Set(terms.flatMap { postings[$0] ?? [] })
    let exactDocuments = Set(names.indices.filter { !exact.isEmpty && names[$0].contains(exact) })
    for index in passages.indices where exactDocuments.contains(passages[index].document)
      || (path != nil && archive.documents[passages[index].document].path == path)
    { candidates.insert(index) }
    var winners: [Int: (Int, Double)] = [:]
    for index in candidates.sorted() {
      try Task.checkCancellation()
      let passage = passages[index]
      let document = archive.documents[passage.document]
      if let path, document.path != path { continue }
      if let scope, document.path != scope, projects[passage.document] != scope,
        !document.path.hasPrefix(scope.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/")
      { continue }
      var score = 0.0
      for term in terms {
        let frequency = Double(passage.frequencies[term] ?? 0)
        let df = Double(postings[term]?.count ?? 0)
        let idf = log(1 + (Double(passages.count) - df + 0.5) / (df + 0.5))
        score += idf * frequency / (frequency + 0.5 + Double(passage.length) / 100)
        if passage.sectionTerms.contains(term) { score += idf * 0.2 }
      }
      if exactDocuments.contains(passage.document) { score += 100 }
      if winners[passage.document] == nil || score > winners[passage.document]!.1 {
        winners[passage.document] = (index, score)
      }
    }
    let ranked = winners.values.sorted {
      if $0.1 != $1.1 { return $0.1 > $1.1 }
      return archive.documents[passages[$0.0].document].path
        < archive.documents[passages[$1.0].document].path
    }
    func result(_ evidence: [Evidence], _ truncated: Bool) -> Result {
      Result(orbitID: archive.orbitID, snapshotID: archive.snapshotID,
        capturedAt: archive.capturedAt, freshness: "snapshot-not-current-provider",
        capturedCoverage: archive.coverage, excludedPaths: archive.excludedPaths,
        totalMatchingNotes: ranked.count, truncated: truncated, evidence: evidence)
    }
    let budget = max(512, min(maximumBytes, 64_000))
    guard try JSONEncoder().encode(result([], true)).count <= budget else {
      throw OrbitError("Retrieval budget cannot contain snapshot coverage")
    }
    var evidence: [Evidence] = []
    var truncated = ranked.count > max(1, min(limit, 100))
    for (index, _) in ranked.prefix(max(1, min(limit, 100))) {
      let entry = passages[index]
      let document = archive.documents[entry.document]
      let allLines = eLines(entry.passage.body).enumerated().map {
        Line(number: entry.passage.start + $0.offset, text: $0.element)
      }
      var lines: [Line] = []
      func item(_ lines: [Line], complete: Bool) -> Evidence {
        Evidence(path: document.path, noteID: noteIDs[entry.document], title: titles[entry.document],
          sha256: document.sha256, heads: document.heads, section: entry.passage.section,
          lines: lines, passageComplete: complete)
      }
      for line in allLines {
        let candidate = item(lines + [line], complete: false)
        if try JSONEncoder().encode(result(evidence + [candidate], true)).count > budget { break }
        lines.append(line)
      }
      guard lines.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
      else { truncated = true; continue }
      let complete = lines.count == allLines.count
      evidence.append(item(lines, complete: complete))
      if !complete { truncated = true }
    }
    return result(evidence, truncated)
  }

  /// Store only in device-local application storage. Encoding precedes atomic replacement.
  /// This file is a read-only projection, not a synchronized database or durable outbox.
  public func write(to url: URL) throws {
    try Task.checkCancellation()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(archive).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  public convenience init(contentsOf url: URL, expectedOrbitID: String) throws {
    let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
    guard bytes.count <= 128 * 1024 * 1024 else { throw OrbitError("Retrieval snapshot is too large") }
    let archive = try JSONDecoder().decode(Archive.self, from: bytes)
    guard archive.orbitID == expectedOrbitID else { throw OrbitError("Retrieval snapshot identity changed") }
    try self.init(archive: archive)
  }
}

extension OrbitEngine {
  /// Explicitly expensive capture. Existing snapshots are immutable and remain usable
  /// when a later capture fails or provider bytes are unavailable.
  public func captureRetrievalSnapshot(_ root: URL) throws -> OrbitRetrievalSnapshot {
    try withOrbitRuntime(runtime) {
      try withOrbitFileAccess(fileAccess) {
        try coherent(root) { sync in
          let orbitID = try identity(root)
          let inventory = try retrievalInventory(root)
          let heads = sync["heads"] as? JSONObject ?? [:]
          var documents: [OrbitRetrievalSnapshot.Document] = []
          var size = 0
          for (path, _) in inventory where path != "ORBIT.md" && ePublic(path) {
            try Task.checkCancellation()
            let bytes = try readData(safe(root, path))
            size += bytes.count
            guard size <= 64 * 1024 * 1024 else { throw OrbitError("Retrieval snapshot is too large") }
            guard let text = String(data: bytes, encoding: .utf8) else { throw OrbitError("Invalid UTF-8") }
            if eString(metadata(text)["type"]) == "schema" { continue }
            documents.append(.init(path: path, bytes: bytes, sha256: digest(bytes), heads: strings(heads[path])))
          }
          for document in documents {
            guard try digest(readData(safe(root, document.path))) == document.sha256 else {
              throw OrbitError("Source changed during retrieval snapshot capture")
            }
          }
          let finalInventory = try retrievalInventory(root)
          let signatures = { (items: [(String, String)]) in
            Dictionary(uniqueKeysWithValues: items.map { (OrbitByteString($0.0), $0.1) })
          }
          guard signatures(inventory) == signatures(finalInventory) else {
            throw OrbitError("Source inventory changed during retrieval snapshot capture")
          }
          if !sync.isEmpty {
            try validateRetrievalSnapshotRevisions(root, documents: documents, expected: sync)
          }
          guard try identity(root) == orbitID else { throw OrbitError("Orbit identity changed") }
          let excluded = strings(sync["blocked_paths"])
          return try OrbitRetrievalSnapshot(archive: .init(schema: 1, orbitID: orbitID,
            snapshotID: newUUID(), capturedAt: now(),
            coverage: sync.isEmpty || eString(sync["status"]) == "ready" ? "complete" : "partial",
            excludedPaths: excluded, documents: documents))
        }
      }
    }
  }
}
