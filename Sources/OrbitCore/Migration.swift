import Foundation

private let migrationTarget = "0.6.0"
private let legacyMigrationTarget = "0.5.0"
private let migrationMarker = ".orbit/vault.json"

func migrationRead(_ root: URL, _ path: String) throws -> String? {
    let url = try safe(root, path)
    guard try schemaExists(url) else { return nil }
    let data = try readData( url)
    guard String(data: data, encoding: .utf8) != nil else { throw OrbitError("Invalid UTF-8 in " + path) }
    return String(decoding: data, as: UTF8.self)
}

func migrationEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
    guard let lhs, !(lhs is NSNull) else { return rhs == nil || rhs is NSNull }
    guard let rhs, !(rhs is NSNull) else { return false }
    return (try? canonical(lhs)) == (try? canonical(rhs))
}

func migrationFiles(_ root: URL, _ relative: String) throws -> [URL] {
    let directory = try safe(root, relative)
    guard try schemaExists(directory) else { return [] }
    return try directoryContents(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted(by: { $0.path < $1.path })
}

func migrationRelative(_ url: URL, _ root: URL) -> String { String(url.path.dropFirst(root.path.count + 1)) }

extension OrbitEngine {
    private func migrationJournals(_ root: URL) throws -> [(URL, JSONObject)] {
        try migrationFiles(root, ".orbit/migrations").map { (url: URL) in (url, try readJSON(safe(root, ".orbit/migrations/" + url.lastPathComponent))) }
    }

    func migrationStatus(_ root: URL) throws -> JSONObject {
        let marker = try readJSON(safe(root, migrationMarker))
        return ["data_format": marker["data_format"] ?? 1, "source_version": marker["orbit_version"] ?? "unknown", "target_version": migrationTarget, "pending": try migrationJournals(root).compactMap { $0.1["status"] as? String == "prepared" ? $0.1["id"] as? String : nil }]
    }

    func migrationEnsureWritable(_ root: URL) throws {
        let state = try migrationStatus(root)
        if state["source_version"] as? String != "unknown" {
            guard let release = state["source_version"] as? String, !schemaMatches(#"^\d+\.\d+\.\d+$"#, release).isEmpty else { throw OrbitError("Unsupported recorded Orbit release; inspect the vault version before writing") }
            let version = release.split(separator: ".").compactMap { Int($0) }
            if [0, 6, 0].lexicographicallyPrecedes(version) { throw OrbitError("Vault was written by a newer Orbit release; downgrade is unsupported") }
        }
        guard let format = schemaInteger(state["data_format"]), [1, 2, 3].contains(format) else { throw OrbitError("Unsupported vault data format; update Orbit before writing") }
        if !(state["pending"] as? [String] ?? []).isEmpty { throw OrbitError("Resume or roll back the pending migration before writing") }
    }

    private func migrationOrdinaryPending(_ root: URL) throws {
        for path in try migrationFiles(root, ".orbit/operations") where try readJSON(path)["status"] as? String == "prepared" { throw OrbitError("Recover the pending save operation before migrating") }
    }

    func migrationSnapshot(_ root: URL) throws -> [String: String] { Dictionary(uniqueKeysWithValues: try migrationSnapshotPairs(root)) }

    private func migrationSnapshotPairs(_ root: URL) throws -> [(String, String)] {
        var result: [(String, String)] = []
        func walk(_ directory: URL, prefix: String) throws {
            let entries = try directoryContents(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).sorted(by: { $0.path < $1.path })
            var directories: [URL] = []
            for entry in entries {
                let relative = prefix + entry.lastPathComponent
                let attrs = try fileResourceValues(entry, forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if attrs.isDirectory == true || attrs.isSymbolicLink == true && ((try? fileAttributes(atPath: realURL(entry).path)[.type]) as? FileAttributeType) == .typeDirectory {
                    if entry.lastPathComponent.hasPrefix("."), relative != ".orbit" { continue }
                    _ = try safe(root, relative)
                    directories.append(entry)
                } else {
                    if relative == ".orbit/write.lock" || relative.hasPrefix(".orbit/migrations/") { continue }
                    result.append((relative, digest(try readData( safe(root, relative)))))
                }
            }
            for directory in directories { try walk(directory, prefix: prefix + directory.lastPathComponent + "/") }
        }
        try walk(root, prefix: "")
        return result
    }

    private func migrationDestinations(_ notes: [JSONObject]) throws -> ([String: String], [String]) {
        let projects = notes.filter { $0["type"] as? String == "project" }
        var identities = migrationIdentities(projects)
        for project in projects {
            if let name = (project["meta"] as? JSONObject)?["project"] as? String, !schemaTrim(name).isEmpty, let path = project["path"] as? String { identities[schemaFold(name), default: []].insert(path) }
        }
        var mapping: [String: String] = [:], warnings: [String] = []
        for note in notes {
            let old = note["path"] as? String ?? "", kind = note["type"] as? String
            if old == "ORBIT.md" || kind == nil || kind == "" {
                mapping[old] = old
                if kind == nil || kind == "", old != "ORBIT.md" { warnings.append("Unclassified note preserved: " + old) }
            } else if kind == "project" { mapping[old] = "Projects/" + (try migrationSegment(note["title"] ?? "")) + "/Overview.md" }
            else if kind == "decision" || kind == "session" {
                let names = strings((note["meta"] as? JSONObject)?["project"])
                guard names.count == 1 else { throw OrbitError("A decision/session needs one unambiguous project: " + old) }
                let matches = (identities[schemaFold(names[0])] ?? []).sorted()
                if matches.isEmpty { throw OrbitError("No matching project for " + old + ": " + names[0]) }
                if matches.count > 1 { throw OrbitError("Ambiguous project for " + old + ": " + names[0] + " matches " + matches.joined(separator: ", ")) }
                let owner = projects.first { $0["path"] as? String == matches[0] }!
                mapping[old] = "Projects/" + (try migrationSegment(owner["title"] ?? "")) + "/" + (kind == "decision" ? "Decisions" : "Sessions") + "/" + (old as NSString).lastPathComponent
            } else {
                let folder = ["person": "People", "source": "Sources", "map": "Maps", "schema": "Schemas"][kind ?? ""] ?? "Knowledge"
                mapping[old] = folder + "/" + (old as NSString).lastPathComponent
            }
        }
        return (mapping, warnings)
    }

    private func migrationPrepareLegacy(_ root: URL) throws -> (JSONObject, [JSONObject]) {
        var state = try migrationStatus(root)
        state["target_version"] = legacyMigrationTarget
        try migrationEnsureWritable(root)
        try migrationOrdinaryPending(root)
        let notes = try scan(root)
        if schemaInteger(state["data_format"]) == 2 {
            let missing = try schemaBootstrap(root).keys.sorted()
            guard missing.isEmpty else { throw OrbitError("Format 2 compatibility check failed: missing schemas: " + missing.joined(separator: ", ")) }
            let findings = try schemaWarnings(root, notes: notes)
            guard !findings.contains(where: { $0["severity"] as? String == "error" }) else { throw OrbitError("Format 2 compatibility check failed: strict schema errors: " + (try migrationJSON(findings))) }
            return (state.merging(["status": "unchanged", "compatible": true, "warnings": [String](), "schema_warnings": findings, "changes": [JSONObject]()], uniquingKeysWith: { _, new in new }), [])
        }
        let (mapping, warnings) = try migrationDestinations(notes)
        let files = try migrationSnapshot(root)
        for directory in orbitDirectories {
            let url = try safe(root, directory)
            var isDirectory: ObjCBool = false
            if try fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue { throw OrbitError("Standard folder is occupied by a file: " + directory) }
        }
        var outputs: [String: String] = [:]
        let occupied = Dictionary(files.keys.map { (schemaFold($0), $0) }, uniquingKeysWith: { first, _ in first })
        for old in mapping.keys.sorted() {
            let new = mapping[old]!
            _ = try safe(root, new)
            if let existing = occupied[schemaFold(new)], existing != old { throw OrbitError("Migration destination already exists: " + new) }
            if outputs.keys.contains(where: { schemaFold($0) == schemaFold(new) }) { throw OrbitError("Migration destination collision: " + new) }
            var parent = (new as NSString).deletingLastPathComponent
            while !parent.isEmpty && parent != "." {
                if occupied[schemaFold(parent)] != nil { throw OrbitError("Migration destination parent is a file: " + parent) }
                parent = (parent as NSString).deletingLastPathComponent
            }
            outputs[new] = old
        }
        var desired: [String: Any] = [:]
        let table = migrationIdentities(notes)
        for new in outputs.keys.sorted() {
            let old = outputs[new]!
            desired[new] = try migrationRewrite(migrationRead(root, old) ?? "", old: old, new: new, mapping: mapping, identities: table)
        }
        for old in mapping.keys.sorted() where old != mapping[old] && desired[old] == nil { desired[old] = NSNull() }
        let schemaTypes = Set(desired.compactMap { path, value in (path as NSString).deletingLastPathComponent == "Schemas" ? (value as? String).flatMap { metadata($0)["schema_for"] as? String } : nil })
        for (path, value) in try schemaBootstrap(root) {
            if desired[path] == nil, try !schemaExists(try safe(root, path)), !schemaTypes.contains(metadata(value)["schema_for"] as? String ?? "") { desired[path] = value }
        }
        let projected: [JSONObject] = desired.keys.sorted().compactMap { path in
            guard let text = desired[path] as? String, path.lowercased().hasSuffix(".md") else { return nil }
            let meta = metadata(text)
            return ["path": path, "text": text, "meta": meta, "id": meta["id"] ?? NSNull(), "title": meta["title"] ?? (path as NSString).deletingPathExtension, "aliases": strings(meta["aliases"]), "links": links(text)]
        }
        let errors = try schemaWarnings(root, notes: projected).filter { $0["severity"] as? String == "error" }
        if !errors.isEmpty { throw OrbitError("Migrated schema validation failed: " + (try migrationJSON(errors))) }
        let duplicates = try issues(projected, root: root).filter { $0["kind"] as? String == "duplicate-id" }
        if !duplicates.isEmpty { throw OrbitError("Migration would duplicate note identities: " + (try migrationJSON(duplicates))) }
        let movements: [JSONObject] = notes.compactMap { note in
            guard let old = note["path"] as? String, let new = mapping[old], old != new else { return nil }
            return ["from": old, "to": new]
        }
        for path in files.keys.sorted() where path.hasPrefix(".orbit/integrations/") && path.hasSuffix(".json") {
            var record = try readJSON(safe(root, path))
            let evidence = (record["notes"] as? [JSONObject] ?? []) + (record["extraction"] as? [JSONObject] ?? [])
            let affected = try evidence.contains { item in
                guard let path = item["path"] as? String, let destination = mapping[path] else { return false }
                let original = try migrationRead(root, path)
                return destination != path || !migrationEqual(desired[destination], original)
            }
            if affected {
                var errors = record["errors"] as? [String] ?? []
                errors.append("Migration changed evidence paths/content; previous verification is historical and requires re-verification")
                record["errors"] = errors
                record["migration"] = ["target_version": legacyMigrationTarget, "mapping": movements, "previous_stage": record["stage"] ?? NSNull(), "verification_stale": true]
                var ordered = try OrderedJSON.parse(Data((try migrationRead(root, path)!).utf8))
                ordered = ordered.migrationSetting("errors", .sorted(record["errors"]!))
                ordered = ordered.migrationSetting("migration", .object([("target_version", .scalar(legacyMigrationTarget)), ("mapping", .array(movements.map { .object([("from", .scalar($0["from"]!)), ("to", .scalar($0["to"]!))]) })), ("previous_stage", .sorted(record["stage"] ?? NSNull())), ("verification_stale", .scalar(true))]))
                desired[path] = try migrationOrderedText(ordered)
            }
        }
        let marker = try OrderedJSON.parse(Data((try migrationRead(root, migrationMarker)!).utf8)).migrationSetting("data_format", .scalar(2)).migrationSetting("orbit_version", .scalar(legacyMigrationTarget))
        desired[migrationMarker] = try migrationOrderedText(marker)
        var writes: [JSONObject] = []
        for path in desired.keys.sorted() {
            let before = try migrationRead(root, path)
            if !migrationEqual(before, desired[path]) { writes.append(["path": path, "before": before as Any? ?? NSNull(), "after": desired[path]!]) }
        }
        writes.sort {
            let left = $0["path"] as! String, right = $1["path"] as! String
            if (left == migrationMarker) != (right == migrationMarker) { return left != migrationMarker }
            if ($0["after"] is NSNull) != ($1["after"] is NSNull) { return !($0["after"] is NSNull) }
            return left < right
        }
        let inputs = OrderedJSON.object(try migrationSnapshotPairs(root).map { ($0.0, .scalar($0.1)) })
        let planID = digest(Data(try migrationOrderedText(.object([("inputs", inputs), ("writes", migrationOrderedWrites(writes)), ("target_version", .scalar(legacyMigrationTarget))])).utf8))
        let report = state.merging(["status": "preview", "target_format": 2, "plan_id": planID, "moves": movements, "warnings": warnings, "changes": migrationChanges(writes)], uniquingKeysWith: { _, new in new })
        return (report, writes)
    }

    private func migrationExecuteLegacy(_ root: URL, record input: JSONObject, journal: URL, rollback: Bool = false) throws -> JSONObject {
        try migrationValidateJournal(input, replicated: false)
        var record = input
        let writes = record["writes"] as! [JSONObject]
        for write in writes { try migrationPreflight(root, write) }
        if !rollback { for directory in orbitDirectories { try createDirectory(at: safe(root, directory), withIntermediateDirectories: true) } }
        let direction = rollback ? "rollback" : "forward"
        if record["status"] as? String != "prepared" || (record["direction"] as? String ?? "forward") != direction {
            record["status"] = "prepared"; record["direction"] = direction
            try atomic(journal, encode(record))
        }
        for write in writes.sorted(by: { ($0["path"] as? String == migrationMarker ? 1 : 0) < ($1["path"] as? String == migrationMarker ? 1 : 0) }) {
            try migrationPreflight(root, write)
            let url = try safe(root, write["path"] as! String)
            if let text = write[rollback ? "before" : "after"] as? String { try atomic(url, Data(text.utf8)) }
            else if try schemaExists(url) { try removeFile(at: url) }
        }
        for write in writes where !migrationEqual(try migrationRead(root, write["path"] as! String), write[rollback ? "before" : "after"]) { throw OrbitError("Migration verification conflict: " + (write["path"] as! String)) }
        record["status"] = rollback ? "rolled-back" : "committed"
        try atomic(journal, encode(record))
        return ["status": record["status"]!, "operation": record["id"]!, "backup": ".orbit/migrations/" + journal.lastPathComponent, "verified": true]
    }

    private func migrationPreflight(_ root: URL, _ write: JSONObject) throws {
        let path = write["path"] as! String, current = try migrationRead(root, path)
        if !migrationEqual(current, write["before"]) && !migrationEqual(current, write["after"]) { throw OrbitError("Migration recovery conflict: " + path) }
    }

    private func migrationLegacy(_ root: URL, action: String, targetVersion: String?, planID: String?, operation: String?) throws -> JSONObject {
        guard [1, 2].contains(schemaInteger(try migrationStatus(root)["data_format"]) ?? -1) else { throw OrbitError("Unsupported vault format for legacy migration; downgrade is unsupported") }
        guard targetVersion == nil || targetVersion == legacyMigrationTarget else { throw OrbitError("Unsupported migration target; supported target is " + migrationTarget) }
        if action == "status" { return try migrationStatus(root) }
        if action == "plan" { return try migrationPrepareLegacy(root).0 }
        guard ["apply", "resume", "rollback"].contains(action) else { throw OrbitError("Unknown migration action") }
        return try withLock(root) {
            guard [1, 2].contains(schemaInteger(try migrationStatus(root)["data_format"]) ?? -1) else { throw OrbitError("Unsupported vault data format; update Orbit before migration recovery") }
            if action == "apply" {
                let (report, writes) = try migrationPrepareLegacy(root)
                if report["status"] as? String == "unchanged" { return report }
                guard let planID, planID == report["plan_id"] as? String else { throw OrbitError("Migration preview is missing or stale; run plan again") }
                let id = newUUID(), journal = try safe(root, ".orbit/migrations/" + id + ".json")
                let backup = Dictionary(uniqueKeysWithValues: writes.map { ($0["path"] as! String, ($0["before"] as? String).map { digest(Data($0.utf8)) } as Any? ?? NSNull()) })
                let record: JSONObject = ["id": id, "kind": "migration", "status": "prepared", "created": now(), "plan_id": planID, "source_format": 1, "target_format": 2, "writes": writes, "backup_manifest": backup]
                try atomic(journal, encode(record))
                return try migrationExecuteLegacy(root, record: record, journal: journal)
            }
            guard let operation, !schemaMatches(#"^[a-f0-9-]{36}$"#, operation).isEmpty else { throw OrbitError("A valid migration operation id is required") }
            let journal = try safe(root, ".orbit/migrations/" + operation + ".json")
            guard try schemaExists(journal) else { throw OrbitError("Migration operation not found") }
            let record = try readJSON(journal)
            if record["status"] as? String == "rolled-back", action == "resume" { throw OrbitError("Migration was rolled back; create a new plan") }
            if try migrationJournals(root).contains(where: { $0.1["id"] as? String != operation && $0.1["status"] as? String == "prepared" }) { throw OrbitError("Another migration is pending") }
            try migrationOrdinaryPending(root)
            return try migrationExecuteLegacy(root, record: record, journal: journal, rollback: action == "rollback" || record["direction"] as? String == "rollback")
        }
    }

    private func migrationReplicationFiles(_ root: URL) throws -> [String: String] {
        var files: [String: String] = [:]
        for note in try scan(root) { if let path = note["path"] as? String { files[path] = try migrationRead(root, path) } }
        for path in try migrationFiles(root, ".orbit/integrations") { let relative = ".orbit/integrations/" + path.lastPathComponent; files[relative] = try migrationRead(root, relative) }
        return files
    }

    private func migrationPrepareReplication(_ root: URL) throws -> (JSONObject, JSONObject?) {
        try migrationEnsureWritable(root)
        try migrationOrdinaryPending(root)
        let state = try migrationStatus(root)
        if schemaInteger(state["data_format"]) == 1 { throw OrbitError("First migrate format 1 to 2 with target_version=0.5.0, then plan 0.6.0") }
        if schemaInteger(state["data_format"]) == 3 {
            let report = try replicationInspect(root)
            guard !migrationTruthy(report["invalid"]), !migrationTruthy(report["pending"]), !(try migrationFiles(root, ".orbit/commits")).isEmpty else { throw OrbitError("Format 3 compatibility check failed: incomplete or invalid history") }
            return (state.merging(["status": "unchanged", "target_format": 3, "compatible": true, "changes": [JSONObject](), "warnings": [String]()], uniquingKeysWith: { _, new in new }), nil)
        }
        let findings = try schemaWarnings(root, notes: scan(root))
        guard try schemaBootstrap(root).isEmpty, !findings.contains(where: { $0["severity"] as? String == "error" }) else { throw OrbitError("Format 2 compatibility check failed; repair schemas before migration") }
        let inputs = try migrationSnapshot(root)
        if inputs.keys.contains(where: migrationHistoryPath) { throw OrbitError("Existing history requires inspection before migration") }
        let files = try migrationReplicationFiles(root), before = try migrationRead(root, migrationMarker)!
        let marker = try OrderedJSON.parse(Data(before.utf8)).migrationSetting("data_format", .scalar(3)).migrationSetting("orbit_version", .scalar(migrationTarget))
        let writes: [JSONObject] = [["path": migrationMarker, "before": before, "after": try migrationOrderedText(marker)]]
        let orderedInputs = OrderedJSON.object(try migrationSnapshotPairs(root).map { ($0.0, .scalar($0.1)) })
        var filePaths = try scan(root).compactMap { $0["path"] as? String }
        filePaths += try migrationFiles(root, ".orbit/integrations").map { ".orbit/integrations/" + $0.lastPathComponent }
        let orderedFiles = OrderedJSON.object(filePaths.map { ($0, .scalar(files[$0]!)) })
        let planID = digest(Data(try migrationOrderedText(.object([("inputs", orderedInputs), ("files", orderedFiles), ("writes", migrationOrderedWrites(writes)), ("target", .scalar(migrationTarget))])).utf8))
        let seed = try replicationSeedPreview(root, files: files)
        var history: [String: String] = [:]
        if let path = seed["path"] as? String, let hash = seed["sha256"] as? String { history[path] = hash }
        let record: JSONObject = ["source_format": 2, "target_format": 3, "inputs": inputs, "files": files, "writes": writes, "seed_history": history]
        return (state.merging(["status": "preview", "target_format": 3, "plan_id": planID, "changes": [["path": migrationMarker, "action": "update"], ["path": ".orbit/commits", "action": "seed"]], "warnings": ["Upgrade every participating installation before applying; offline old clients cannot be fenced."], "schema_warnings": findings], uniquingKeysWith: { _, new in new }), record)
    }

    private func migrationExecuteReplication(_ root: URL, record input: JSONObject, journal: URL, rollback requestedRollback: Bool = false) throws -> JSONObject {
        try migrationValidateJournal(input, replicated: true)
        var record = input
        guard let write = (record["writes"] as? [JSONObject])?.first, let baseline = record["inputs"] as? [String: String] else { throw OrbitError("Invalid migration journal") }
        let current = try migrationSnapshot(root), currentHistory = current.filter { migrationHistoryPath($0.key) }
        let expectedHistory = record["seed_history"] as? [String: String]
        for path in Set(current.keys).union(baseline.keys) where !migrationHistoryPath(path) && path != migrationMarker {
            if current[path] != baseline[path] { throw OrbitError("Migration recovery conflict: " + path) }
        }
        try migrationPreflight(root, write)
        let rollback = requestedRollback || record["direction"] as? String == "rollback"
        if let expectedHistory {
            let matches = record["status"] as? String == "prepared" ? currentHistory.allSatisfy { expectedHistory[$0.key] == $0.value } : currentHistory == expectedHistory
            guard matches else { throw OrbitError("Migration recovery conflict: subsequent or changed history") }
        }
        let direction = rollback ? "rollback" : "forward"
        if record["status"] as? String != "prepared" || (record["direction"] as? String ?? "forward") != direction {
            record["status"] = "prepared"; record["direction"] = direction
            try atomic(journal, encode(record))
        }
        if rollback {
            try atomic(safe(root, migrationMarker), Data((write["before"] as! String).utf8))
            for path in currentHistory.keys.sorted() { try removeFile(at: safe(root, path)) }
        } else {
            try replicationSeed(root, files: record["files"] as? [String: String] ?? [:])
            let seeded = try migrationSnapshot(root).filter { migrationHistoryPath($0.key) }
            guard seeded == expectedHistory else { throw OrbitError("Migration recovery conflict: unexpected seed history") }
            try atomic(safe(root, migrationMarker), Data((write["after"] as! String).utf8))
        }
        if !migrationEqual(try migrationRead(root, migrationMarker), write[rollback ? "before" : "after"]) { throw OrbitError("Migration verification conflict: " + migrationMarker) }
        let final = try migrationSnapshot(root)
        for (path, checksum) in baseline where path != migrationMarker && final[path] != checksum { throw OrbitError("Migration verification conflict: " + path) }
        record["status"] = rollback ? "rolled-back" : "committed"
        try atomic(journal, encode(record))
        return ["status": record["status"]!, "operation": record["id"]!, "backup": ".orbit/migrations/" + journal.lastPathComponent, "verified": true, "source_format": 2, "target_format": 3]
    }

    func migrate(_ inputRoot: URL, action: String = "plan", targetVersion: String? = nil, planID: String? = nil, operation: String? = nil) throws -> JSONObject {
        let root = realURL(inputRoot)
        guard targetVersion == nil || [migrationTarget, legacyMigrationTarget].contains(targetVersion!) else { throw OrbitError("Unsupported migration target; supported targets are 0.5.0 and " + migrationTarget) }
        if action == "status" { return try migrationStatus(root) }
        if ["resume", "rollback"].contains(action), let operation, !schemaMatches(#"^[a-f0-9-]{36}$"#, operation).isEmpty {
            let journal = try safe(root, ".orbit/migrations/" + operation + ".json")
            if try schemaExists(journal), schemaInteger(try readJSON(journal)["target_format"]) == 3 {
                return try withLock(root) {
                    let record = try readJSON(journal)
                    if record["status"] as? String == "rolled-back" {
                        if action == "resume" { throw OrbitError("Migration was rolled back; create a new plan") }
                        return ["status": "rolled-back", "operation": operation, "verified": true]
                    }
                    if try migrationJournals(root).contains(where: { $0.1["id"] as? String != operation && $0.1["status"] as? String == "prepared" }) { throw OrbitError("Another migration is pending") }
                    try migrationOrdinaryPending(root)
                    return try migrationExecuteReplication(root, record: record, journal: journal, rollback: action == "rollback" || record["direction"] as? String == "rollback")
                }
            }
            return try migrationLegacy(root, action: action, targetVersion: legacyMigrationTarget, planID: planID, operation: operation)
        }
        if targetVersion == legacyMigrationTarget { return try migrationLegacy(root, action: action, targetVersion: targetVersion, planID: planID, operation: operation) }
        if action == "plan" { return try migrationPrepareReplication(root).0 }
        guard action == "apply" else { throw OrbitError("Unknown migration action") }
        return try withLock(root) {
            let (report, optional) = try migrationPrepareReplication(root)
            if report["status"] as? String == "unchanged" { return report }
            guard let planID, planID == report["plan_id"] as? String, var record = optional else { throw OrbitError("Migration preview is missing or stale; run plan again") }
            let id = newUUID(), journal = try safe(root, ".orbit/migrations/" + id + ".json")
            record.merge(["id": id, "kind": "migration", "status": "prepared", "created": now(), "plan_id": planID], uniquingKeysWith: { _, new in new })
            try atomic(journal, encode(record))
            return try migrationExecuteReplication(root, record: record, journal: journal)
        }
    }
}

private func migrationValidateJournal(_ record: JSONObject, replicated: Bool) throws {
    guard record["id"] is String, record["status"] is String, let writes = record["writes"] as? [JSONObject] else { throw OrbitError("Invalid migration journal") }
    for write in writes {
        guard write["path"] is String, let before = write["before"], let after = write["after"], before is String || before is NSNull, after is String || after is NSNull else { throw OrbitError("Invalid migration journal write") }
    }
    if replicated {
        guard record["inputs"] is [String: String], record["files"] is [String: String], let write = writes.first, write["path"] as? String == migrationMarker, write["before"] is String, write["after"] is String else { throw OrbitError("Invalid migration journal") }
        if let history = record["seed_history"], !(history is [String: String]) { throw OrbitError("Invalid migration seed history") }
    }
}

private func migrationTruthy(_ value: Any?) -> Bool {
    guard let value, !(value is NSNull) else { return false }
    if let values = value as? [Any] { return !values.isEmpty }
    if let values = value as? JSONObject { return !values.isEmpty }
    if let value = value as? Bool { return value }
    if let value = value as? String { return !value.isEmpty }
    return true
}
private func migrationHistoryPath(_ path: String) -> Bool { path.hasPrefix(".orbit/commits/") || path.hasPrefix(".orbit/observations/") }
private func migrationJSON(_ value: Any) throws -> String { String(data: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes, .sortedKeys]), encoding: .utf8)! }
private func migrationOrderedText(_ value: OrderedJSON) throws -> String { try value.rendered(pretty: true) + "\n" }
private func migrationOrderedWrites(_ writes: [JSONObject]) -> OrderedJSON {
    .array(writes.map { write in .object([("path", .scalar(write["path"]!)), ("before", .sorted(write["before"] ?? NSNull())), ("after", .sorted(write["after"] ?? NSNull()))]) })
}

private extension OrderedJSON {
    func migrationSetting(_ key: String, _ value: OrderedJSON) -> OrderedJSON {
        guard case .object(var pairs) = self else { return self }
        if let index = pairs.firstIndex(where: { $0.0 == key }) { pairs[index].1 = value }
        else { pairs.append((key, value)) }
        return .object(pairs)
    }
}
private func migrationChanges(_ writes: [JSONObject]) -> [JSONObject] { writes.map { ["path": $0["path"]!, "action": $0["after"] is NSNull ? "delete" : $0["before"] is NSNull ? "create" : "update"] } }

private func migrationSegment(_ value: Any) throws -> String {
    let value = schemaTrim(String(describing: value))
    guard !value.isEmpty, !value.hasPrefix("."), value.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:\0")) == nil else { throw OrbitError("Unsafe project title: " + value) }
    return value
}

private func migrationIdentities(_ notes: [JSONObject]) -> [String: Set<String>] {
    var table: [String: Set<String>] = [:]
    for note in notes {
        guard let path = note["path"] as? String else { continue }
        var keys = [path, (path as NSString).deletingPathExtension, ((path as NSString).lastPathComponent as NSString).deletingPathExtension]
        keys += [note["title"], note["id"]].compactMap { $0 as? String }; keys += note["aliases"] as? [String] ?? []
        for key in keys where !key.isEmpty { table[schemaFold(key), default: []].insert(path) }
    }
    return table
}

private func migrationReplace(_ text: String, pattern: String, options: NSRegularExpression.Options = [], transform: ([String]) throws -> String) throws -> String {
    let regex = try NSRegularExpression(pattern: pattern, options: options), ns = text as NSString
    var result = "", cursor = 0
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
        let values = (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
        result += try transform(values)
        cursor = match.range.location + match.range.length
    }
    return result + ns.substring(from: cursor)
}

private func migrationNormalize(_ path: String) -> String {
    var parts: [String] = []
    for part in path.split(separator: "/") {
        if part == "." { continue }
        if part == "..", let last = parts.last, last != ".." { parts.removeLast() }
        else { parts.append(String(part)) }
    }
    return parts.isEmpty ? "." : parts.joined(separator: "/")
}

private func migrationRelpath(_ destination: String, from parent: String) -> String {
    var target = destination.split(separator: "/").map(String.init), base = parent.split(separator: "/").map(String.init).filter { $0 != "." }
    while !target.isEmpty && !base.isEmpty && target[0] == base[0] { target.removeFirst(); base.removeFirst() }
    let result = Array(repeating: "..", count: base.count) + target
    return result.isEmpty ? "." : result.joined(separator: "/")
}

func migrationRewrite(_ text: String, old: String, new: String, mapping: [String: String], identities: [String: Set<String>]) throws -> String {
    let header = schemaMatches(#"^\uFEFF?---\r?\n.*?\r?\n---(?:\r?\n|$)"#, text, options: [.dotMatchesLineSeparators]).first?.first ?? ""
    let body = String(text.dropFirst(header.count))
    let link = #"(!?\[[^\]\n]*\]\()(<[^>\n]+>|[^\s()]+)(\s+(?:"[^"\n]*"|'[^'\n]*'))?(\))"#
    let reference = #"^(\s{0,3}\[[^\]\n]+\]:\s*)(<[^>\n]+>|\S+)(.*)$"#
    func destination(_ raw: String) throws -> String {
        let angle = raw.hasPrefix("<") && raw.hasSuffix(">")
        let value = angle ? String(raw.dropFirst().dropLast()) : raw
        if !schemaMatches(#"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, value).isEmpty || value.hasPrefix("/") { return raw }
        let fragmentParts = value.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let queryParts = String(fragmentParts[0]).split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let encodedPath = String(queryParts[0])
        guard !encodedPath.isEmpty else { return raw }
        let path = encodedPath.removingPercentEncoding ?? encodedPath
        let parent = (old as NSString).deletingLastPathComponent
        let resolved = migrationNormalize((parent.isEmpty ? "" : parent + "/") + path)
        if resolved.hasPrefix("../") { throw OrbitError("Link escapes vault in " + old) }
        let extensionless = mapping[resolved] == nil && mapping[resolved + ".md"] != nil
        var dest = mapping[extensionless ? resolved + ".md" : resolved] ?? resolved
        if extensionless { dest = (dest as NSString).deletingPathExtension }
        let relative = migrationRelpath(dest, from: (new as NSString).deletingLastPathComponent)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/@-._~")
        let encoded = encodedPath.contains("%") || !angle && relative.contains(" ") ? relative.addingPercentEncoding(withAllowedCharacters: allowed)! : relative
        let suffix = (queryParts.count > 1 && !queryParts[1].isEmpty ? "?" + queryParts[1] : "") + (fragmentParts.count > 1 && !fragmentParts[1].isEmpty ? "#" + fragmentParts[1] : "")
        return (angle ? "<" : "") + encoded + suffix + (angle ? ">" : "")
    }
    func transform(_ part: String) throws -> String {
        var result = try migrationReplace(part, pattern: #"\[\[([^\]\n]+)\]\]"#) { match in
            let token = match[1]
            let prefix = token.prefix { $0 != "|" && $0 != "#" }
            let target = schemaTrim(String(prefix))
            if target.isEmpty { return match[0] }
            let resolved = (identities[schemaFold(target)] ?? []).sorted()
            if resolved.count > 1 { throw OrbitError("Ambiguous wikilink in " + old + ": " + target) }
            guard let path = resolved.first, let dest = mapping[path], dest != path else { return match[0] }
            return "[[" + (dest as NSString).deletingPathExtension + token.dropFirst(prefix.count) + "]]"
        }
        result = try migrationReplace(result, pattern: link) { $0[1] + (try destination($0[2])) + $0[3] + $0[4] }
        result = try migrationReplace(result, pattern: reference, options: [.anchorsMatchLines]) { $0[1] + (try destination($0[2])) + $0[3] }
        let leftovers = try migrationReplace(part, pattern: link) { _ in "" }
        if leftovers.contains("](") { throw OrbitError("Unsupported Markdown link syntax in " + old) }
        if !schemaMatches(#"<(?:img|a)\b"#, part, options: [.caseInsensitive]).isEmpty { throw OrbitError("HTML links need manual migration in " + old) }
        return result
    }
    for (source, destination) in mapping where source != destination {
        if header.contains(source) || source.contains("/") && header.contains((source as NSString).deletingPathExtension) { throw OrbitError("Migration would invalidate preserved metadata paths in " + old) }
    }
    if try transform(header) != header { throw OrbitError("Migration would rewrite preserved metadata links in " + old) }
    let code = try NSRegularExpression(pattern: #"(`{3,}[^\n]*\n.*?^`{3,}[^\n]*$|~{3,}[^\n]*\n.*?^~{3,}[^\n]*$|`+[^`\n]*`+)"#, options: [.anchorsMatchLines, .dotMatchesLineSeparators])
    let ns = body as NSString
    var result = header, cursor = 0
    for match in code.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
        result += try transform(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
        result += ns.substring(with: match.range)
        cursor = match.range.location + match.range.length
    }
    result += try transform(ns.substring(from: cursor))
    return result
}
