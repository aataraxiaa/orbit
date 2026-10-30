import Foundation
import CryptoKit
import CoreFoundation
import Darwin

private let replicationLimit = 64 * 1024 * 1024
private let replicationLocksGuard = NSLock()
private final class ReplicaLockEntry {
    let mutex = NSRecursiveLock()
    var depth = 0
}
private var replicationLocks: [String: ReplicaLockEntry] = [:]
private func rRealPath(_ input: URL) -> String {
    var path = input.standardizedFileURL.path
    var suffix: [String] = []
    while true {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return ([String(cString: resolved)] + suffix.reversed()).joined(separator: "/")
        }
        if path == "/" { return input.path }
        suffix.append((path as NSString).lastPathComponent)
        path = (path as NSString).deletingLastPathComponent
    }
}
private func rObject(_ value: Any?) -> JSONObject { value as? JSONObject ?? [:] }
private func rObjects(_ value: Any?) -> [JSONObject] { value as? [JSONObject] ?? [] }
private func rStrings(_ value: Any?) -> [String] { value as? [String] ?? [] }
private func rString(_ value: Any?) -> String { value as? String ?? "" }
private func rText(_ value: Any?) -> String? { value as? String }
private func rEqual(_ a: Any?, _ b: Any?) -> Bool {
    if let a = a as? String, let b = b as? String { return a.utf8.elementsEqual(b.utf8) }
    return (a as? NSObject ?? NSNull()).isEqual(b as? NSObject ?? NSNull())
}
private func rTextEqual(_ a: String?, _ b: String?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (a?, b?): return a.utf8.elementsEqual(b.utf8)
    default: return false
    }
}
private func rHash(_ value: Any) throws -> String { digest(try canonical(value)) }
private func rMatch(_ pattern: String, _ text: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
private struct ReplicaState {
    var records: [String: JSONObject] = [:]
    var versions: [String: JSONObject] = [:]
    var owners: [String: String] = [:]
    var eligible: Set<String> = []
    var heads: [String: [String]] = [:]
    var observations: [String: JSONObject] = [:]
    var unresolved: [String: JSONObject] = [:]
    var pending: [String: [String]] = [:]
    var invalid: [JSONObject] = []
    var localPaths: [String] = []
}

extension OrbitEngine {
    public func replicationEnabled(_ root: URL) -> Bool {
        guard let marker = try? readJSON(safe(root, ".orbit/vault.json")) else { return false }
        return marker["data_format"] as? Int == 3
    }

    private func replicaIdentity(_ root: URL) throws -> String {
        do {
            let value = try readJSON(safe(root, ".orbit/vault.json"))["id"] as? String
            guard let value, UUID(uuidString: value) != nil else { throw OrbitError("Replication requires a valid Orbit identity") }
            return value
        } catch is CancellationError { throw CancellationError() }
        catch { throw OrbitError("Replication requires a valid Orbit identity") }
    }

    private func replicaStateURL(_ root: URL) throws -> URL {
        let base = rRealPath(stateURL), canonicalRoot = rRealPath(root)
        if base == canonicalRoot || base.hasPrefix(canonicalRoot + "/") {
            throw OrbitError("ORBIT_STATE must be outside the synced Orbit folder")
        }
        return URL(fileURLWithPath: base).appendingPathComponent(try rHash([canonicalRoot, replicaIdentity(root)]))
    }

    public func withLocalLock<T>(_ root: URL, body: () throws -> T) throws -> T {
        let directory = try replicaStateURL(root)
        let key = directory.path
        replicationLocksGuard.lock()
        let entry = replicationLocks[key] ?? ReplicaLockEntry()
        replicationLocks[key] = entry
        replicationLocksGuard.unlock()
        entry.mutex.lock()
        defer { entry.mutex.unlock() }
        if entry.depth > 0 {
            entry.depth += 1
            defer { entry.depth -= 1 }
            return try body()
        }
        try createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = try openFile(directory.appendingPathComponent("write.lock"), flags: O_CREAT | O_RDWR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(fd, LOCK_UN) }
        entry.depth = 1
        defer { entry.depth = 0 }
        return try body()
    }

    private func replicaPath(_ root: URL, _ value: Any?) throws -> URL {
        guard let value = value as? String else { throw OrbitError("Snapshot path must be a string") }
        let url = try safe(root, value)
        let parts = value.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let integration = parts.count == 3 && Array(parts.prefix(2)) == [".orbit", "integrations"] && rMatch("^[a-f0-9]{64}\\.json$", parts[2])
        if !integration && (parts.contains(where: { $0.hasPrefix(".") }) || url.pathExtension.lowercased() != "md" || Array(parts.prefix(2)) == ["Sources", "assets"]) {
            throw OrbitError("Snapshot must target Markdown or an integration record")
        }
        guard parts.joined(separator: "/") == value, !parts.contains(".") else { throw OrbitError("Snapshot path must be canonical") }
        return url
    }

    private func replicaEntity(_ path: String, _ text: String?) -> String {
        if path.hasPrefix(".orbit/integrations/") { return "integration:" + URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
        if let text, let id = metadata(text)["id"] as? String, !id.isEmpty { return "note:" + id }
        return "path:" + path
    }

    private func replicaText(_ root: URL, _ path: String) throws -> String? {
        let url = try replicaPath(root, path)
        guard try fileExists(atPath: url.path) else { return nil }
        do {
            let data = try readData(url)
            guard String(data: data, encoding: .utf8) != nil else { throw OrbitError("Invalid UTF-8") }
            return String(decoding:data,as:UTF8.self)
        } catch is CancellationError { throw CancellationError() }
        catch { throw OrbitError("Cannot read snapshot target " + path) }
    }

    private func replicaUUID(_ value: String) throws -> String {
        guard let id = UUID(uuidString: value), id.uuidString.lowercased() == value else { throw OrbitError("request_id must be a canonical UUID string") }
        return value
    }

    private func replicaPublish(_ root: URL, _ directory: String, _ name: String, _ record: JSONObject) throws {
        let path = try safe(root, ".orbit/" + directory + "/" + name + ".json")
        let raw = try canonical(record)
        guard raw.count <= replicationLimit else { throw OrbitError("Snapshot exceeds 64 MiB limit") }
        if try fileExists(atPath: path.path) {
            guard try readData( path) == raw else { throw OrbitError("Immutable snapshot identity collision: " + name) }
            return
        }
        try atomic(path, raw)
        let fd = try openFile(path.deletingLastPathComponent(), flags: O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func replicaAssets(_ versions: [JSONObject]) -> [JSONObject] {
        var found: [String: String] = [:]
        let expression = try! NSRegularExpression(pattern: "Sources/assets/([a-f0-9]{64})(\\.[a-zA-Z0-9]{1,10})(?![a-zA-Z0-9])")
        for version in versions {
            let text = rString(version["content"])
            let ns = text as NSString
            for match in expression.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let hash = ns.substring(with: match.range(at: 1))
                found["Sources/assets/" + hash + ns.substring(with: match.range(at: 2))] = hash
            }
        }
        return found.keys.sorted().map { ["path": $0, "sha256": found[$0]!] }
    }

    private func replicaEnvelope(_ root: URL, _ operation: String, _ writes: [JSONObject], _ versions: [JSONObject], _ requestDigest: String, genesis: Bool = false) throws -> JSONObject {
        var payload: JSONObject = ["protocol": 1, "vault_id": try replicaIdentity(root), "id": operation, "request_digest": requestDigest, "genesis": genesis, "writes": writes, "versions": versions, "assets": replicaAssets(versions)]
        payload["sha256"] = try rHash(payload)
        return payload
    }

    private func replicaValidate(_ root: URL, _ record: JSONObject, _ filename: String) throws -> JSONObject {
        var payload = record
        payload.removeValue(forKey: "sha256")
        guard rString(record["sha256"]) == (try rHash(payload)) else { throw OrbitError("Snapshot integrity mismatch") }
        guard record["protocol"] as? Int == 1, rString(record["vault_id"]) == (try replicaIdentity(root)) else { throw OrbitError("Unsupported snapshot protocol or different Orbit identity") }
        guard try replicaUUID(rString(record["id"])) + ".json" == filename else { throw OrbitError("Snapshot filename does not match identity") }
        guard record["request_digest"] is String, let genesis = record["genesis"] as? NSNumber, CFGetTypeID(genesis) == CFBooleanGetTypeID() else { throw OrbitError("Invalid snapshot request metadata") }
        guard let versions = record["versions"] as? [JSONObject], !versions.isEmpty, let writes = record["writes"] as? [JSONObject], !writes.isEmpty else { throw OrbitError("Snapshot requires versions and writes") }
        var entities = Set<String>(), destinations = Set<String>(), writePaths = Set<String>()
        for write in writes {
            _ = try replicaPath(root, write["path"])
            let path = rString(write["path"])
            guard writePaths.insert(path).inserted else { throw OrbitError("Duplicate snapshot write path") }
            for key in ["before", "after"] where write[key] != nil && !(write[key] is NSNull) && !(write[key] is String) { throw OrbitError("Snapshot text must be UTF-8 text or null") }
        }
        for version in versions {
            _ = try replicaPath(root, version["path"])
            let entity = rString(version["entity"]), path = rString(version["path"]), content = rText(version["content"])
            guard !entity.isEmpty, entities.insert(entity).inserted else { throw OrbitError("Invalid or duplicate entity") }
            guard version["content"] == nil || version["content"] is NSNull || version["content"] is String else { throw OrbitError("Invalid entity content") }
            if let content, replicaEntity(path, content) != entity && !entity.hasPrefix("path:") { throw OrbitError("Entity identity differs from content") }
            if content != nil && !destinations.insert(path).inserted { throw OrbitError("Duplicate snapshot destination") }
            for key in ["parents", "observations", "paths"] {
                guard let values = version[key] as? [String], values == Array(Set(values)).sorted() else { throw OrbitError("Invalid " + key + " set") }
            }
            let paths = rStrings(version["paths"])
            guard !paths.isEmpty, paths.contains(path) else { throw OrbitError("Missing version path") }
            for p in paths { _ = try replicaPath(root, p) }
            let matching = writes.filter { paths.contains(rString($0["path"])) }
            let retired = truthy(version["retired"])
            if retired {
                guard let value = version["retired"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID(), content == nil, !rStrings(version["parents"]).isEmpty, versions.contains(where: { rString($0["entity"]) != entity && rString($0["path"]) == path && rText($0["content"]) != nil }) else { throw OrbitError("Invalid collision retirement") }
            }
            guard !matching.isEmpty, retired || matching.contains(where: { rString($0["path"]) == path && rEqual($0["after"], version["content"]) }) else { throw OrbitError("Version does not match its write evidence") }
            guard Set(paths) == Set(matching.map { rString($0["path"]) }) else { throw OrbitError("Missing write evidence") }
        }
        guard writePaths == Set(versions.flatMap { rStrings($0["paths"]) }) else { throw OrbitError("Unassigned write evidence") }
        guard rEqual(record["assets"], replicaAssets(versions)) else { throw OrbitError("Asset dependencies differ from content") }
        return record
    }

    private func replicaFiles(_ root: URL, _ directory: String) throws -> [URL] {
        let folder = try safe(root, directory)
        guard try fileExists(atPath: folder.path) else { return [] }
        return try directoryContents(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    }

    private func replicaLoad(_ root: URL) throws -> ReplicaState {
        var state = ReplicaState()
        for path in try replicaFiles(root, ".orbit/commits") {
            let relative = ".orbit/commits/" + path.lastPathComponent
            do {
                _ = try safe(root, relative)
                let raw = try readData( path)
                guard raw.count <= replicationLimit else { throw OrbitError("Snapshot exceeds size limit") }
                let record = try replicaValidate(root, readJSON(path), path.lastPathComponent)
                state.records[rString(record["id"])] = record
            } catch is CancellationError { throw CancellationError() }
            catch { state.invalid.append(["path": relative, "error": String(describing: error)]) }
        }
        if state.records.isEmpty && replicationEnabled(root) { state.invalid.append(["path": ".orbit/commits", "error": "Format 3 history is missing"]) }
        for path in try replicaFiles(root, ".orbit/observations") {
            let relative = ".orbit/observations/" + path.lastPathComponent
            do {
                _ = try safe(root, relative)
                guard try readData( path).count <= replicationLimit else { throw OrbitError("Observation exceeds size limit") }
                let record = try readJSON(path)
                guard rString(record["vault_id"]) == (try replicaIdentity(root)), record["protocol"] as? Int == 1 else { throw OrbitError("Invalid observation identity/protocol") }
                _ = try replicaPath(root, record["path"])
                guard let text = record["content"] as? String, let entity = record["entity"] as? String, replicaEntity(rString(record["path"]), text) == entity || entity.hasPrefix("path:") else { throw OrbitError("Invalid observation content/identity") }
                let id = try rHash(record)
                guard path.lastPathComponent == id + ".json" else { throw OrbitError("Observation integrity mismatch") }
                state.observations[id] = record
            } catch is CancellationError { throw CancellationError() }
            catch { state.invalid.append(["path": relative, "error": String(describing: error)]) }
        }
        return state
    }

    private func replicaLocalPaths(_ root: URL) throws -> Set<String> {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        var paths = Set<String>()
        func walk(_ directory: URL, _ prefix: String) throws {
            for path in try directoryContents(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                let values = try fileResourceValues(path, forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true {
                    if !path.lastPathComponent.hasPrefix(".") { try walk(path, prefix + path.lastPathComponent + "/") }
                } else {
                    let relative = prefix + path.lastPathComponent
                    if path.pathExtension.lowercased() == "md" && !relative.hasPrefix("Sources/assets/") { paths.insert(relative) }
                }
            }
        }
        try walk(root, "")
        for path in try replicaFiles(root, ".orbit/integrations") { paths.insert(".orbit/integrations/" + path.lastPathComponent) }
        return paths
    }

    private func replicaResolvedEntity(_ state: ReplicaState, _ path: String, _ text: String?) -> String {
        var legacy = Set(state.versions.values.filter { rString($0["entity"]).hasPrefix("path:") && rStrings($0["paths"]).contains(path) }.map { rString($0["entity"]) })
        for observation in Array(state.observations.values) + Array(state.unresolved.values) where rString(observation["entity"]).hasPrefix("path:") && rString(observation["path"]) == path { legacy.insert(rString(observation["entity"])) }
        return legacy.count == 1 ? legacy.first! : replicaEntity(path, text)
    }

    private func replicaUnfamiliar(_ root: URL, _ state: ReplicaState) throws -> [String: JSONObject] {
        let paths = try replicaLocalPaths(root).union(state.versions.values.flatMap { rStrings($0["paths"]) })
        var observations: [String: JSONObject] = [:]
        for path in paths.sorted() {
            guard let text = try replicaText(root, path) else { continue }
            if state.versions.values.contains(where: { rString($0["path"]) == path && rTextEqual(rText($0["content"]), text) }) { continue }
            let observation: JSONObject = ["protocol": 1, "vault_id": try replicaIdentity(root), "entity": replicaResolvedEntity(state, path, text), "path": path, "content": text]
            observations[try rHash(observation)] = observation
        }
        return observations
    }

    private func replicaCapture(_ root: URL, _ state: ReplicaState) throws {
        for (id, observation) in try replicaUnfamiliar(root, state) { try replicaPublish(root, "observations", id, observation) }
    }

    private func replicaFold(_ root: URL) throws -> ReplicaState {
        var state = try replicaLoad(root)
        for (id, record) in state.records {
            for (index, version) in rObjects(record["versions"]).enumerated() {
                let token = rString(record["sha256"]) + ":" + String(index)
                state.versions[token] = version
                state.owners[token] = id
            }
        }
        var remaining = Set(state.records.keys)
        while !remaining.isEmpty {
            var progressed = false
            for id in remaining.sorted() {
                let record = state.records[id]!
                var reasons: [String] = []
                for version in rObjects(record["versions"]) {
                    for parent in rStrings(version["parents"]) {
                        if let predecessor = state.versions[parent] {
                            if rString(predecessor["entity"]) != rString(version["entity"]) { reasons.append("parent belongs to another entity " + parent) }
                            else if let content = rText(version["content"]), let old = rText(predecessor["content"]), !rString(version["entity"]).hasPrefix("integration:"), let oldID = metadata(old)["id"], !(oldID is NSNull), truthy(oldID), !rEqual(oldID, metadata(content)["id"]) { reasons.append("parent stable identity changed " + parent) }
                            else if !state.eligible.contains(state.owners[parent]!) { reasons.append("pending parent " + parent) }
                        } else { reasons.append("missing parent " + parent) }
                    }
                    for id in rStrings(version["observations"]) {
                        if let observation = state.observations[id] {
                            if rString(observation["entity"]) != rString(version["entity"]) { reasons.append("observation belongs to another entity " + id) }
                        } else { reasons.append("missing observation " + id) }
                    }
                }
                for asset in rObjects(record["assets"]) {
                    let path = rString(asset["path"]), url = try safe(root, rString(asset["path"]))
                    var directory: ObjCBool = false
                    if try !fileExists(atPath: url.path, isDirectory: &directory) || directory.boolValue { reasons.append("missing asset " + path) }
                    else if digest(try readData( url)) != rString(asset["sha256"]) { reasons.append("asset hash mismatch " + path) }
                }
                if !reasons.isEmpty { state.pending[id] = Array(Set(reasons)).sorted() }
                else {
                    state.eligible.insert(id); remaining.remove(id); state.pending.removeValue(forKey: id); progressed = true
                }
            }
            if !progressed { break }
        }
        let active = state.versions.filter { state.eligible.contains(state.owners[$0.key]!) }
        let parents = Set(active.values.flatMap { rStrings($0["parents"]) })
        for (token, version) in active where !parents.contains(token) { state.heads[rString(version["entity"]), default: []].append(token) }
        state.heads = state.heads.mapValues { $0.sorted() }
        let consumed = Set(active.values.flatMap { rStrings($0["observations"]) })
        for (id, observation) in state.observations where !consumed.contains(id) {
            if !state.versions.values.contains(where: { rEqual($0["path"], observation["path"]) && rEqual($0["content"], observation["content"]) }) { state.unresolved[id] = observation }
        }
        for (id, observation) in try replicaUnfamiliar(root, state) where !consumed.contains(id) { state.unresolved[id] = observation }
        state.localPaths = try replicaLocalPaths(root).sorted()
        return state
    }

    private func replicaReport(_ state: ReplicaState) -> JSONObject {
        var conflicts: [JSONObject] = [], blocked = Set<String>(), byPath: [String: [String]] = [:], claims: [String: Set<String>] = [:]
        let entities = Set(state.heads.keys).union(state.unresolved.values.map { rString($0["entity"]) })
        for entity in entities.sorted() {
            let heads = state.heads[entity] ?? []
            let observations = state.unresolved.keys.filter { rString(state.unresolved[$0]!["entity"]) == entity }.sorted()
            var paths = Set(heads.flatMap { rStrings(state.versions[$0]!["paths"]) })
            paths.formUnion(observations.map { rString(state.unresolved[$0]!["path"]) })
            for path in paths { byPath[path, default: []].append(contentsOf: heads) }
            for token in heads where rText(state.versions[token]!["content"]) != nil { claims[rString(state.versions[token]!["path"]), default: []].insert(entity) }
            if heads.count > 1 || !observations.isEmpty {
                conflicts.append(["entity": entity, "paths": paths.sorted(), "heads": heads, "observations": observations]); blocked.formUnion(paths)
            }
        }
        for path in claims.keys.sorted() where claims[path]!.count > 1 {
            blocked.insert(path)
            for entity in claims[path]!.sorted() where !conflicts.contains(where: { rString($0["entity"]) == entity }) {
                let heads = state.heads[entity]!
                let paths = Set(heads.flatMap { rStrings(state.versions[$0]!["paths"]) }).sorted()
                conflicts.append(["entity": entity, "paths": paths, "heads": heads, "observations": [], "reason": "path collision"]); blocked.formUnion(paths)
            }
        }
        var identities: [String: [String: Set<String>]] = [:]
        for (entity, tokens) in state.heads where !entity.hasPrefix("integration:") {
            for token in tokens {
                let version = state.versions[token]!
                if let content = rText(version["content"]), let id = metadata(content)["id"] as? String, !id.isEmpty { identities[id, default: [:]][entity, default: []].formUnion(rStrings(version["paths"])) }
            }
        }
        for (identity, owners) in identities where owners.count > 1 {
            for entity in owners.keys.sorted() {
                let paths = owners[entity]!.sorted(); blocked.formUnion(paths)
                if !conflicts.contains(where: { rString($0["entity"]) == entity }) { conflicts.append(["entity": entity, "paths": paths, "heads": state.heads[entity]!, "observations": [], "reason": "duplicate stable identity " + identity]) }
            }
        }
        for id in state.pending.keys { blocked.formUnion(rObjects(state.records[id]!["versions"]).flatMap { rStrings($0["paths"]) }) }
        var changed = true
        while changed {
            changed = false
            let activeTokens = Set(state.heads.values.flatMap { $0 })
            for id in state.eligible where !(state.records[id]!["genesis"] as? Bool ?? false) {
                let paths = Set(state.versions.filter { state.owners[$0.key] == id && activeTokens.contains($0.key) }.values.flatMap { rStrings($0["paths"]) })
                if !paths.isDisjoint(with: blocked) && !paths.isSubset(of: blocked) { blocked.formUnion(paths); changed = true }
            }
        }
        for (path, entities) in claims where entities.count == 1 && !blocked.contains(path) { byPath[path] = state.heads[entities.first!]! }
        if !state.invalid.isEmpty { blocked.formUnion(state.localPaths); blocked.formUnion(state.versions.values.flatMap { rStrings($0["paths"]) }) }
        return ["status": !state.invalid.isEmpty ? "invalid" : !conflicts.isEmpty ? "conflicted" : !state.pending.isEmpty ? "pending" : "ready", "conflicts": conflicts.sorted { rString($0["entity"]) < rString($1["entity"]) }, "pending": state.pending.keys.sorted().map { ["operation": $0, "reasons": state.pending[$0]!] as JSONObject }, "invalid": state.invalid, "blocked_paths": blocked.sorted(), "heads": byPath.mapValues { Array(Set($0)).sorted() }]
    }

    public func replicationInspect(_ root: URL) throws -> JSONObject { replicaReport(try replicaFold(root)) }

    public func replicationHistory(_ root: URL, path: String) throws -> JSONObject {
        _ = try replicaPath(root, path)
        let state = try replicaFold(root)
        var entities = Set(state.versions.values.filter { rStrings($0["paths"]).contains(path) }.map { rString($0["entity"]) })
        entities.formUnion(state.observations.values.filter { rString($0["path"]) == path }.map { rString($0["entity"]) })
        let revisions: [JSONObject] = state.versions.keys.sorted().compactMap { token in
            var version = state.versions[token]!
            guard entities.contains(rString(version["entity"])) else { return nil }
            version["revision"] = token; version["operation"] = state.owners[token]!; version["eligible"] = state.eligible.contains(state.owners[token]!)
            return version
        }
        let current = try replicaText(root, path)
        let observations: [JSONObject] = state.observations.keys.sorted().compactMap { id in
            var observation = state.observations[id]!
            guard entities.contains(rString(observation["entity"])) else { return nil }
            observation["id"] = id; return observation
        }
        return ["path": path, "current": ["path": path, "content": current as Any? ?? NSNull(), "sha256": current.map { digest(Data($0.utf8)) } as Any? ?? NSNull()], "revisions": revisions, "observations": observations, "sync": replicaReport(state)]
    }

    public func replicationReconcile(_ root: URL) throws -> JSONObject {
        try withLocalLock(root) {
            var state = try replicaFold(root)
            try replicaCapture(root, state)
            state = try replicaFold(root)
            let report = replicaReport(state)
            var materialized: [String] = []
            func result(_ report: JSONObject) -> JSONObject { var value = report; value["materialized"] = materialized; return value }
            if !rObjects(report["invalid"]).isEmpty { return result(report) }
            let blocked = Set(rStrings(report["blocked_paths"]))
            let intent = try replicaStateURL(root).appendingPathComponent("checkout.json")
            let liveClaims = Set(state.heads.values.flatMap { $0 }.compactMap { rText(state.versions[$0]!["content"]) == nil ? nil : rString(state.versions[$0]!["path"]) })
            for entity in state.heads.keys.sorted() {
                let tokens = state.heads[entity]!
                guard tokens.count == 1 else { continue }
                let version = state.versions[tokens[0]]!
                guard Set(rStrings(version["paths"])).isDisjoint(with: blocked) else { continue }
                var desired: JSONObject = Dictionary(uniqueKeysWithValues: rStrings(version["paths"]).map { ($0, NSNull() as Any) })
                desired[rString(version["path"])] = version["content"] ?? NSNull()
                for path in desired.keys.sorted() {
                    let after = rText(desired[path])
                    if after == nil && liveClaims.contains(path) { continue }
                    let before = try replicaText(root, path)
                    if rTextEqual(before, after) { continue }
                    let known = state.versions.values.filter { rString($0["path"]) == path }.map { rText($0["content"]) } + state.observations.values.filter { rString($0["path"]) == path }.map { rText($0["content"]) }
                    if before != nil && !known.contains(where: { rTextEqual($0, before) }) { try replicaCapture(root, state); return result(replicaReport(try replicaFold(root))) }
                    try atomic(intent, canonical(["path": path, "before": before as Any? ?? NSNull(), "after": after as Any? ?? NSNull(), "head": tokens[0]]))
                    if try !rTextEqual(replicaText(root, path), before) { try replicaCapture(root, state); return result(replicaReport(try replicaFold(root))) }
                    let target = try replicaPath(root, path)
                    if let after { try atomic(target, Data(after.utf8)) }
                    else if try fileExists(atPath: target.path) { try removeFile(at: target) }
                    materialized.append(path)
                    if try fileExists(atPath: intent.path) { try removeFile(at: intent) }
                }
            }
            return result(replicaReport(try replicaFold(root)))
        }
    }

    private func replicaGenesis(_ root: URL, _ files: [String: String]) throws -> JSONObject {
        guard let namespace = UUID(uuidString: try replicaIdentity(root)) else { throw OrbitError("Replication requires a valid Orbit identity") }
        var tuple = namespace.uuid
        var bytes = withUnsafeBytes(of: &tuple) { Array($0) }
        bytes += Array("orbit-format-3-genesis".utf8)
        var hashed = Array(Insecure.SHA1.hash(data: Data(bytes)).prefix(16))
        hashed[6] = (hashed[6] & 0x0f) | 0x50; hashed[8] = (hashed[8] & 0x3f) | 0x80
        let operation = UUID(uuid: (hashed[0],hashed[1],hashed[2],hashed[3],hashed[4],hashed[5],hashed[6],hashed[7],hashed[8],hashed[9],hashed[10],hashed[11],hashed[12],hashed[13],hashed[14],hashed[15])).uuidString.lowercased()
        var versions: [JSONObject] = [], writes: [JSONObject] = [], entities = Set<String>()
        for path in files.keys.sorted() {
            _ = try replicaPath(root, path)
            let text = files[path]!, entity = replicaEntity(path, files[path]!)
            guard entities.insert(entity).inserted else { throw OrbitError("Genesis contains duplicate stable identities") }
            versions.append(["entity": entity, "path": path, "content": text, "parents": [], "observations": [], "paths": [path]])
            writes.append(["path": path, "before": text, "after": text, "reason": "Format 3 genesis"])
        }
        guard !writes.isEmpty else { throw OrbitError("Genesis requires at least one file, such as ORBIT.md") }
        return try replicaEnvelope(root, operation, writes, versions, rHash(files), genesis: true)
    }

    public func replicationSeedPreview(_ root: URL, files: [String: String]) throws -> JSONObject {
        let record = try replicaGenesis(root, files), operation = rString(record["id"])
        return ["operation": operation, "path": ".orbit/commits/" + operation + ".json", "sha256": digest(try canonical(record))]
    }

    public func replicationSeed(_ root: URL, files: [String: String]) throws -> JSONObject {
        try withLocalLock(root) {
            let record = try replicaGenesis(root, files)
            try replicaPublish(root, "commits", rString(record["id"]), record)
            return ["status": "committed", "operation": rString(record["id"]), "durability": "local", "verified": true]
        }
    }

    private func replicaReceipt(_ root: URL, _ record: JSONObject) -> JSONObject {
        do {
            let sync = try replicationReconcile(root)
            let verified = try rObjects(record["writes"]).allSatisfy { try rTextEqual(replicaText(root, rString($0["path"])), rText($0["after"])) }
            return ["status": "committed", "operation": rString(record["id"]), "durability": "local", "verified": verified, "sync": sync]
        } catch {
            return ["status": "committed", "operation": rString(record["id"]), "durability": "local", "verified": false, "sync": ["status": "interrupted", "error": String(describing: error), "materialized": []]]
        }
    }

    private func replicaPrevious(_ root: URL, _ requestID: String, _ requestDigest: String) throws -> JSONObject? {
        let path = try safe(root, ".orbit/commits/" + requestID + ".json")
        guard try fileExists(atPath: path.path) else { return nil }
        let record = try replicaValidate(root, readJSON(path), path.lastPathComponent)
        guard rString(record["request_digest"]) == requestDigest else { throw OrbitError("request_id was already used for different content") }
        return record
    }

    public func replicationRetry(_ root: URL, requestID: String, requestDigest: String) throws -> JSONObject? {
        _ = try replicaUUID(requestID)
        return try withLocalLock(root) {
            guard let record = try replicaPrevious(root, requestID, requestDigest) else { return nil }
            return replicaReceipt(root, record)
        }
    }

    public func replicationCommit(_ root: URL, writes: [JSONObject], requestID: String? = nil, requestDigest: String? = nil, dryRun: Bool = false) throws -> JSONObject {
        let operation = try requestID.map { try replicaUUID($0) } ?? newUUID()
        guard !writes.isEmpty, writes.count <= 50 else { throw OrbitError("Commit requires 1 to 50 writes") }
        let requestDigest = try requestDigest ?? rHash(writes)
        return try withLocalLock(root) {
            if let previous = try replicaPrevious(root, operation, requestDigest) {
                if dryRun { return ["status": "preview", "operation": operation, "already_committed": true, "sync": try replicationInspect(root)] }
                return replicaReceipt(root, previous)
            }
            var state = try replicaFold(root)
            if !dryRun { try replicaCapture(root, state); state = try replicaFold(root) }
            let report = replicaReport(state)
            guard rObjects(report["invalid"]).isEmpty, rObjects(report["pending"]).isEmpty else { throw OrbitError("Resolve invalid or incomplete sync evidence before saving") }
            var groups: [String: [JSONObject]] = [:], clean: [JSONObject] = [], seen = Set<String>(), retirements: [JSONObject] = []
            for original in writes {
                var write = original
                _ = try replicaPath(root, write["path"])
                let path = rString(write["path"])
                guard seen.insert(path).inserted else { throw OrbitError("Duplicate target in commit") }
                for key in ["expected_heads", "observations"] where write[key] != nil {
                    guard let values = write[key] as? [String], Set(values).count == values.count else { throw OrbitError("Expected heads and observations must be unique string lists") }
                }
                for key in ["before", "after"] where write[key] != nil && !(write[key] is NSNull) && !(write[key] is String) { throw OrbitError("Write content must be text or null") }
                let before = rText(write["before"]), after = rText(write["after"])
                guard try rTextEqual(replicaText(root, path), before) else { throw OrbitError("Write conflict: " + path + " changed before commit") }
                let entity = replicaResolvedEntity(state, path, after ?? before)
                let competing = state.heads.filter { _, heads in heads.contains { rString(state.versions[$0]!["path"]) == path && rText(state.versions[$0]!["content"]) != nil } }
                let collision = competing.count > 1
                if collision {
                    let allHeads = competing.values.flatMap { $0 }.sorted()
                    let allObservations = state.unresolved.keys.filter { competing[rString(state.unresolved[$0]!["entity"])] != nil }.sorted()
                    guard competing[entity] != nil, after != nil else { throw OrbitError("Choose the content of one existing identity to resolve the path collision") }
                    guard rStrings(write["expected_heads"]).sorted() == allHeads else { throw OrbitError("Path collision: supply the exact union of expected_heads for every competing identity") }
                    guard rStrings(write["observations"]).sorted() == allObservations else { throw OrbitError("Path collision: supply all observations for competing identities") }
                    for (losing, heads) in competing where losing != entity {
                        let paths = Set(heads.flatMap { rStrings(state.versions[$0]!["paths"]) }).sorted()
                        retirements.append(["entity": losing, "path": path, "content": NSNull(), "parents": heads, "observations": allObservations.filter { rString(state.unresolved[$0]!["entity"]) == losing }, "paths": paths, "retired": true])
                    }
                    write["expected_heads"] = competing[entity]!
                    write["observations"] = allObservations.filter { rString(state.unresolved[$0]!["entity"]) == entity }
                }
                if !collision, let before, let after, let id = metadata(before)["id"], truthy(id), !rEqual(id, metadata(after)["id"]) { throw OrbitError("Preserve stable identity") }
                groups[entity, default: []].append(write)
                clean.append(["path": path, "before": before as Any? ?? NSNull(), "after": after as Any? ?? NSNull(), "reason": rString(write["reason"])])
            }
            var versions: [JSONObject] = []
            for entity in groups.keys.sorted() {
                let members = groups[entity]!, heads = state.heads[entity] ?? []
                let observations = state.unresolved.keys.filter { rString(state.unresolved[$0]!["entity"]) == entity }.sorted()
                let suppliedHeads = members.compactMap { $0["expected_heads"] as? [String] }, suppliedObservations = members.compactMap { $0["observations"] as? [String] }
                if suppliedHeads.contains(where: { $0.sorted() != heads }) || ((heads.count > 1 || (!observations.isEmpty && !heads.isEmpty)) && suppliedHeads.isEmpty) { throw OrbitError("Conflict: supply exact expected_heads to resolve all branches") }
                if suppliedObservations.contains(where: { $0.sorted() != observations }) || (!observations.isEmpty && suppliedObservations.isEmpty) { throw OrbitError("External edit: supply exact observations to adopt or resolve") }
                if heads.count == 1 && suppliedHeads.isEmpty && observations.isEmpty {
                    let head = state.versions[heads[0]]!
                    guard let matching = members.first(where: { rEqual($0["path"], head["path"]) }), rEqual(matching["before"], head["content"]) else { throw OrbitError("Write conflict: current bytes do not match the accepted head; reconcile and read again") }
                }
                let live = members.filter { rText($0["after"]) != nil }
                guard live.count <= 1, !live.isEmpty || members.count <= 1 else { throw OrbitError("One entity requires one destination or one tombstone") }
                let selected = live.first ?? members[0]
                let paths = Set(members.map { rString($0["path"]) }).union(heads.flatMap { rStrings(state.versions[$0]!["paths"]) }).sorted()
                for oldPath in Set(paths).subtracting(members.map { rString($0["path"]) }).sorted() {
                    guard !seen.contains(oldPath) else { throw OrbitError("Another entity targets a retained historical path") }
                    let oldContent = try replicaText(root, oldPath)
                    if oldContent != nil && replicaResolvedEntity(state, oldPath, oldContent) != entity { throw OrbitError("Historical path is occupied by another entity") }
                    clean.append(["path": oldPath, "before": oldContent as Any? ?? NSNull(), "after": NSNull(), "reason": "Retain prior-location tombstone"]); seen.insert(oldPath)
                }
                versions.append(["entity": entity, "path": rString(selected["path"]), "content": selected["after"] ?? NSNull(), "parents": heads, "observations": observations, "paths": paths])
            }
            for retired in retirements {
                let entity = rString(retired["entity"])
                guard groups[entity] == nil else { throw OrbitError("A retired collision identity cannot also be updated in this operation") }
                for oldPath in rStrings(retired["paths"]) where !seen.contains(oldPath) {
                    let oldContent = try replicaText(root, oldPath)
                    if oldContent != nil && replicaResolvedEntity(state, oldPath, oldContent) != entity { throw OrbitError("Retired historical path is occupied by another identity") }
                    clean.append(["path": oldPath, "before": oldContent as Any? ?? NSNull(), "after": NSNull(), "reason": "Retire collision identity"]); seen.insert(oldPath)
                }
                versions.append(retired)
            }
            let record = try replicaEnvelope(root, operation, clean, versions, requestDigest)
            _ = try replicaValidate(root, record, operation + ".json")
            for write in clean {
                guard try rTextEqual(replicaText(root, rString(write["path"])), rText(write["before"])) else { throw OrbitError("Write conflict before durable acceptance: " + rString(write["path"])) }
            }
            if dryRun { return ["status": "preview", "sync": report] }
            try replicaPublish(root, "commits", operation, record)
            return replicaReceipt(root, record)
        }
    }

    public func replicationOperation(_ root: URL, id: String) throws -> JSONObject {
        _ = try replicaUUID(id)
        let state = try replicaFold(root)
        guard state.eligible.contains(id), let record = state.records[id] else { throw OrbitError("Operation is unavailable, incomplete or invalid") }
        return ["id": id, "status": "committed", "writes": record["writes"]!, "durability": "local"]
    }
}
