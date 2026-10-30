import Foundation
import Darwin

func eString(_ value: Any?) -> String { value as? String ?? "" }
func eObjects(_ value: Any?) -> [JSONObject] { value as? [JSONObject] ?? [] }
func eInt(_ value: Any?, _ fallback: Int = 0) -> Int { value as? Int ?? fallback }
func eBool(_ value: Any?) -> Bool { value as? Bool ?? false }
func eExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
func eText(_ url: URL) throws -> String { let data = try Data(contentsOf: url); guard let text = String(data:data,encoding:.utf8) else { throw OrbitError("Invalid UTF-8: " + url.path) }; return text }
func eLines(_ text: String) -> [String] { var lines = text.components(separatedBy: .newlines); if lines.last == "" { lines.removeLast() }; return lines }
func eEqual(_ lhs: Any?, _ rhs: Any?) -> Bool { if lhs == nil || lhs is NSNull { return rhs == nil || rhs is NSNull }; guard let lhs, let rhs else { return false }; return (try? canonical(lhs)) == (try? canonical(rhs)) }
func eMatches(_ pattern: String, _ text: String, _ options: NSRegularExpression.Options = []) -> [[String]] { guard let regex = try? NSRegularExpression(pattern:pattern, options:options) else { return [] }; let ns = text as NSString; return regex.matches(in:text,range:NSRange(location:0,length:ns.length)).map { match in (0..<match.numberOfRanges).map { match.range(at:$0).location == NSNotFound ? "" : ns.substring(with:match.range(at:$0)) } } }
func eReplace(_ pattern: String, _ text: String, _ replacement: String, _ options: NSRegularExpression.Options = []) -> String { guard let regex = try? NSRegularExpression(pattern:pattern, options:options) else { return text }; return regex.stringByReplacingMatches(in:text,range:NSRange(text.startIndex...,in:text),withTemplate:replacement) }
func ePublic(_ path: String) -> Bool { !path.split(separator:"/").contains(where:{$0.hasPrefix(".")}) }
func eJSON(_ value: Any) -> String { String(data:(try? encode(value)) ?? Data(),encoding:.utf8) ?? "" }
func eChildren(_ url:URL, suffix:String) throws -> [URL] { guard eExists(url) else { return [] }; return try FileManager.default.contentsOfDirectory(at:url,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasSuffix(suffix)}.sorted{$0.path < $1.path} }

extension OrbitEngine {
    func withLock<T>(_ root:URL, body:() throws -> T) throws -> T {
        if replicationEnabled(root) { return try withLocalLock(root,body:body) }
        let path = try safe(root,".orbit/write.lock")
        let fd = Darwin.open(path.path,O_CREAT | O_EXCL | O_WRONLY,0o600)
        guard fd >= 0 else { throw OrbitError("Vault has a write lock. Check active writers; see recovery instructions before removing a stale lock.") }
        defer { Darwin.close(fd); try? FileManager.default.removeItem(at:path) }
        let bytes = try encode(["pid":Int(getpid()),"created":now()])
        try bytes.write(to:path)
        return try body()
    }
    func coherent<T>(_ root:URL, body:(JSONObject)throws->T) throws -> T {
        if !replicationEnabled(root) { return try body([:]) }
        return try withLock(root) { try migrationEnsureWritable(root); return try body(replicationReconcile(root)) }
    }
    func readableNotes(_ root:URL) throws -> [JSONObject] {
        let blocked = replicationEnabled(root) ? Set(strings(try replicationInspect(root)["blocked_paths"])) : []
        return try scan(root).filter{ !blocked.contains(eString($0["path"])) }
    }
    public func read(_ root:URL,path:String,start:Int=1,count:Int=160) throws -> JSONObject {
        let canonicalPath = try safe(root,path).path.replacingOccurrences(of:root.path + "/",with:"")
        return try coherent(root) { sync in
            if strings(sync["blocked_paths"]).contains(canonicalPath) { throw OrbitError("Note has unresolved or incomplete revisions; use orbit_sync action=history for " + canonicalPath) }
            var result = try readNote(root,path:canonicalPath,start:start,count:count)
            if !sync.isEmpty { result["sync"] = sync; result["heads"] = (sync["heads"] as? JSONObject)?[canonicalPath] ?? [] }
            return result
        }
    }
    func readNote(_ root:URL,path:String,start:Int=1,count:Int=160)throws->JSONObject {
        let url = try safe(root,path)
        guard url.pathExtension.lowercased() == "md",ePublic(path) else { throw OrbitError("Read accepts public Markdown notes only") }
        let raw = try Data(contentsOf:url)
        guard var text = String(data:raw,encoding:.utf8) else { throw OrbitError("Invalid UTF-8") }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        let lines = eLines(text), start = max(1,start), count = max(1,min(count,500))
        let end = min(lines.count,start-1+count)
        let excerpt:[JSONObject] = start-1 < end ? (start-1..<end).map{["line":$0+1,"text":lines[$0]]} : []
        return ["path":path,"sha256":digest(raw),"total_lines":lines.count,"start":start,"lines":excerpt,"more":start-1+count < lines.count]
    }
    public func search(_ root:URL,query:String,limit:Int=8,scope:String?=nil,noteType:String?=nil,status:String?=nil)throws->JSONObject {
        try coherent(root) { sync in var result = try searchCurrent(root,query:query,limit:limit,scope:scope,noteType:noteType,status:status); if !sync.isEmpty { result["sync"] = sync }; return result }
    }
    func searchCurrent(_ root:URL,query:String,limit:Int=8,scope:String?=nil,noteType:String?=nil,status:String?=nil)throws->JSONObject {
        do { return try retrievalSearch(root,query:query,limit:limit,scope:scope,noteType:noteType,status:status) }
        catch let error as RetrievalError {
            if scope != nil || noteType != nil || status != nil { return ["mode":"unavailable","total":0,"results":[],"coverage":["state":"unavailable","reason":error.description],"hint":"Scoped index unavailable. Repair the index or read explicit paths."] }
            var result = try lexicalSearch(root,query:query,limit:limit)
            result["coverage"] = ["state":"degraded","semantic":false,"reason":error.description]
            return result
        }
    }
    func lexicalSearch(_ root:URL,query:String,limit:Int=8)throws->JSONObject {
        let notes = try readableNotes(root).filter{eString($0["type"]) != "schema" && eString($0["path"]) != "ORBIT.md"}
        var terms:[String]=[]; for token in tokens(query) where !terms.contains(token) { terms.append(token) }
        if terms.isEmpty { return ["mode":"lexical","results":[],"hint":"Use a name, alias or meaningful term."] }
        let counts = notes.map { Dictionary(tokens(eString($0["text"])).map{($0,1)},uniquingKeysWith:+) }
        let average = max(1,Double(counts.reduce(0){$0+$1.values.reduce(0,+)})/Double(max(1,counts.count)))
        var results:[JSONObject]=[]
        for (index,note) in notes.enumerated() {
            let frequencies=counts[index],size=Double(frequencies.values.reduce(0,+)), names=[eString(note["title"])]+strings(note["aliases"]), titleTerms=Set(tokens(names.joined(separator:" ")))
            var score=0.0,matched:[String]=[]
            for term in terms { let frequency=Double(frequencies[term] ?? 0); if frequency>0 || titleTerms.contains(term) { matched.append(term); let df=Double(counts.filter{$0[term] != nil}.count); let idf=log(1+(Double(notes.count)-df+0.5)/(df+0.5)); score += idf*(frequency*2.2/(frequency+1.2*(0.25+0.75*size/average)))+(titleTerms.contains(term) ? 2.5:0) } }
            if matched.isEmpty { continue }; if names.map({$0.lowercased()}).contains(query.lowercased()) { score += 12 }; if ["superseded","archived"].contains(eString(note["status"])) { score *= 0.8 }
            let ranked=eLines(eString(note["text"])).enumerated().sorted { a,b in let x=Set(tokens(a.element)).intersection(terms).count,y=Set(tokens(b.element)).intersection(terms).count; return x == y ? a.offset<b.offset : x>y }.prefix(3).sorted{$0.offset<$1.offset}
            results.append(["path":note["path"] ?? "","title":note["title"] ?? "","status":note["status"] ?? "","score":(score*10000).rounded()/10000,"matched":matched,"snippets":ranked.map{["line":$0.offset+1,"text":String($0.element.prefix(350))]}])
        }
        results.sort { let a=$0["score"] as? Double ?? 0,b=$1["score"] as? Double ?? 0; return a == b ? eString($0["path"])<eString($1["path"]) : a>b }
        return ["mode":"lexical-bm25-with-title-and-alias-boost","total":results.count,"results":Array(results.prefix(max(1,min(limit,100)))),"hint":"Read results before answering. For conceptual recall, search agent-generated synonyms and follow context links. No embeddings are installed."]
    }
    func context(_ root:URL,target:String,depth:Int=1,limit:Int=12)throws->JSONObject {
        let notes=try readableNotes(root),table=identities(notes),roots=resolve(target,table:table)
        guard roots.count == 1 else { throw OrbitError("Target must resolve uniquely; matches: " + eJSON(roots).trimmingCharacters(in:.whitespacesAndNewlines)) }
        var graph:[String:Set<String>]=[:]
        for note in notes { for link in strings(note["links"]) { let destinations=resolve(link,table:table); if destinations.count == 1 { graph[eString(note["path"]),default:[]].insert(destinations[0]); graph[destinations[0],default:[]].insert(eString(note["path"])) } } }
        var seen=Set(roots),front=roots
        for _ in 0..<max(0,min(depth,3)) { front=Set(front.flatMap{Array(graph[$0] ?? [])}).subtracting(seen).sorted(); seen.formUnion(front) }
        let ordered=notes.filter{seen.contains(eString($0["path"]))}.sorted{a,b in let ap=eString(a["path"]),bp=eString(b["path"]); return ap == roots[0] ? bp != roots[0] : bp == roots[0] ? false : ap<bp }
        return ["root":roots[0],"total":ordered.count,"notes":ordered.prefix(max(1,min(limit,50))).map{n in n.filter{["path","title","status","links"].contains($0.key)}},"hint":"Links indicate navigation, not proof. Read the relationship sentence and its evidence."]
    }
    func issues(_ notes:[JSONObject],root:URL,plannedAssets:[String]=[])throws->[JSONObject] {
        let table=identities(notes); var result:[JSONObject]=[]; var counts:[String:Int]=[:]
        for note in notes { if let id=note["id"] as? String,!id.isEmpty { counts[id,default:0]+=1 } }
        for note in notes {
            let path=eString(note["path"]),id=eString(note["id"])
            if !id.isEmpty,counts[id,default:0]>1 { result.append(["path":path,"kind":"duplicate-id","target":id]) }
            for link in strings(note["links"]) {
                let candidates=resolve(link,table:table)
                if candidates.isEmpty { let exists=(try? safe(root,link)).map{FileManager.default.fileExists(atPath:$0.path)} ?? false; if !exists && !plannedAssets.contains(link) { result.append(["path":path,"kind":"unresolved-link","target":link]) } }
                else if candidates.count>1 { result.append(["path":path,"kind":"ambiguous-link","target":link,"matches":candidates]) }
            }
        }
        let byPath=Dictionary(notes.map{(eString($0["path"]),$0)},uniquingKeysWith:{$1})
        for note in notes { let body=eReplace("```.*?```|~~~.*?~~~",eString(note["text"]),"",[.dotMatchesLineSeparators]); for match in eMatches("\\[\\[([^\\]\\n]+)\\]\\]",body) {
            let target=match[1].components(separatedBy:"|")[0]; let parts=target.components(separatedBy:"#"); if parts.count<2 { continue }; let destination=parts[0],anchor=parts.dropFirst().joined(separator:"#"); let candidates=destination.isEmpty ? [eString(note["path"])] : resolve(destination,table:table)
            if candidates.count != 1 || anchor.isEmpty { continue }; let content=eReplace("```.*?```|~~~.*?~~~",eString(byPath[candidates[0]]?["text"]),"",[.dotMatchesLineSeparators]); let present:Bool
            if anchor.hasPrefix("^") { present = !eMatches("(?:^|\\s)"+NSRegularExpression.escapedPattern(for:anchor)+"\\s*$",content,[.anchorsMatchLines]).isEmpty }
            else { present=eMatches("^#{1,6}\\s+(.+)$",content,[.anchorsMatchLines]).map{eReplace("\\s*#+\\s*$",$0[1],"").trimmingCharacters(in:.whitespaces).lowercased()}.contains(anchor.trimmingCharacters(in:.whitespaces).lowercased()) }
            if !present { result.append(["path":note["path"] ?? "","kind":"unresolved-anchor","target":target]) }
        } }
        return result
    }
    func doctor(_ root:URL)throws->JSONObject {
        let notes=try scan(root),journals=try eChildren(safe(root,".orbit/operations"),suffix:".json")
        let pending=try journals.compactMap{url -> String? in let r=try readJSON(url); return eString(r["status"]) == "prepared" ? eString(r["id"]) : nil }
        let sync:JSONObject=replicationEnabled(root) ? try replicationInspect(root) : ["status":"legacy","hint":"Migrate to format 3 for cross-device revision handling."]
        return ["vault":root.path,"notes":notes.count,"readable":true,"writable":FileManager.default.isWritableFile(atPath:root.path),"sync":sync,"issues":try issues(notes,root:root),"pending_operations":pending,"locked":eExists(try safe(root,".orbit/write.lock")),"state_directory":".orbit","rules":"ORBIT.md","migration":try migrationStatus(root),"search":"incremental local FTS5 passages with live lexical fallback; semantic expansion is performed by the agent","host_permissions":"This result verifies only the current process. Repeat in every host and a fresh conversation."]
    }
    func validatePlan(_ root:URL,plan:JSONObject,preservedLinkIssues:inout [JSONObject]?)throws->[JSONObject] {
        guard let changes=plan["changes"] as? [JSONObject],!changes.isEmpty else { throw OrbitError("Plan requires a nonempty changes list") }; guard changes.count<=50 else { throw OrbitError("At most 50 notes per operation; split large saves") }
        let existing=try scan(root); var projected=Dictionary(existing.map{(eString($0["path"]),$0)},uniquingKeysWith:{$1}),writes:[JSONObject]=[],seen=Set<String>(),retiredPaths=Set<String>()
        let conflicts=replicationEnabled(root) ? eObjects(try replicationInspect(root)["conflicts"]) : []
        for change in changes {
            let path=eString(change["path"]),url=try safe(root,path)
            guard ePublic(path),url.pathExtension == "md",!(path == "ORBIT.md" && !replicationEnabled(root)),!path.hasPrefix("Sources/assets/") else { throw OrbitError("Changes must target public .md notes, not configuration") }
            guard !seen.contains(path) else { throw OrbitError("Duplicate target in operation") }; seen.insert(path)
            let raw=eExists(url) ? try Data(contentsOf:url) : nil,expected=change["expected_sha256"] as? String
            if raw == nil && expected != nil { throw OrbitError(path+": expected existing note is missing") }
            if let raw,expected == nil || expected != digest(raw) { throw OrbitError(path+": conflict; read the latest note and supply its SHA-256") }
            guard let text=change["content"] as? String,let reason=change["reason"] as? String,!reason.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw OrbitError("Each change needs content and an explanation in reason") }
            let before:Any=raw.flatMap{String(data:$0,encoding:.utf8)} as Any? ?? NSNull()
            if path == "ORBIT.md" { writes.append(["path":path,"before":before,"after":text,"reason":reason]); continue }
            let meta=metadata(text)
            for field in ["id","title","type","summary"] { guard let value=meta[field] as? String,!value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw OrbitError(path+": missing string frontmatter "+field) } }
            for conflict in conflicts where eString(conflict["entity"]) == "note:"+eString(meta["id"]) && strings(conflict["paths"]).contains(path) && strings(conflict["heads"]).count>1 && strings(change["expected_heads"]).sorted() == strings(conflict["heads"]).sorted() { retiredPaths.formUnion(strings(conflict["paths"]).filter{$0 != path}) }
            let resolvingCollision=replicationEnabled(root) && change["expected_heads"] != nil && projected[path] != nil && !eEqual(projected[path]?["id"],meta["id"])
            if let old=projected[path],!eString(old["id"]).isEmpty,!eEqual(old["id"],meta["id"]),!resolvingCollision { throw OrbitError(path+": preserve the existing stable id") }
            if let raw,!resolvingCollision {
                var previous=String(data:raw,encoding:.utf8) ?? ""; if previous.hasPrefix("\u{feff}") { previous.removeFirst() }; let oldMeta=metadata(previous),missing=Set(oldMeta.keys).subtracting(meta.keys)
                if !missing.isEmpty { throw OrbitError(path+": preserve existing metadata fields: "+eJSON(missing.sorted()).trimmingCharacters(in:.whitespacesAndNewlines)) }
                var known=Set(["id","title","type","summary","aliases","status","created","updated","tags","source_url","source_hash","capture_scope","project","topics","repository","revision","observed","schema_version"])
                if eString(oldMeta["type"]) == "schema" && eString(meta["type"]) == "schema" { known.formUnion(["schema_for","required_fields","required_sections","validation"]) }
                let oldBlocks=metadataBlocks(previous),newBlocks=metadataBlocks(text)
                for field in Set(oldBlocks.keys).subtracting(known) where oldBlocks[field] != newBlocks[field] { throw OrbitError(path+": preserve unknown metadata block "+field+" verbatim") }
            }
            projected[path]=["path":path,"title":meta["title"] ?? "","aliases":strings(meta["aliases"]),"id":meta["id"] ?? NSNull(),"links":links(text),"text":text]
            writes.append(["path":path,"before":before,"after":text,"reason":reason])
        }
        for path in retiredPaths.subtracting(seen) { projected.removeValue(forKey:path) }
        let findings=try issues(Array(projected.values).sorted{eString($0["path"])<eString($1["path"])},root:root)
        let bad:[JSONObject]
        if let preserved=preservedLinkIssues { bad=findings.filter{finding in eString(finding["kind"]) == "duplicate-id" || !preserved.contains(where:{eEqual(finding,$0)})}; preservedLinkIssues=findings.filter{i in preserved.contains{eEqual(i,$0)}} }
        else { bad=findings.filter{seen.contains(eString($0["path"])) || eString($0["kind"]) == "duplicate-id"} }
        if !bad.isEmpty { throw OrbitError("Resolve links/identities before saving: "+eJSON(bad).trimmingCharacters(in:.whitespacesAndNewlines)) }
        return writes
    }
    public func apply(_ root:URL,plan:JSONObject,dryRun:Bool=false,formatMetadata:Bool=false)throws->JSONObject {
        try withLock(root) {
            try migrationEnsureWritable(root)
            let replicated=replicationEnabled(root),requestID=plan["request_id"] as? String,requestHash=try requestDigest(plan)
            if replicated && !dryRun { if let requestID,let previous=try replicationRetry(root,requestID:requestID,requestDigest:requestHash) { return previous }; _=try replicationReconcile(root) }
            let ops=try safe(root,".orbit/operations")
            if !replicated { try FileManager.default.createDirectory(at:ops,withIntermediateDirectories:true); if try eChildren(ops,suffix:".json").contains(where:{eString(try readJSON($0)["status"]) == "prepared"}) { throw OrbitError("Recover the pending operation before writing") } }
            var effectivePlan=plan,preserved:[JSONObject]?=nil,formatReceipts:[JSONObject]?=nil
            if formatMetadata { preserved=try issues(scan(root),root:root).filter{eString($0["kind"]) != "duplicate-id"}; let prepared=try formattingPrepare(root,plan:plan); effectivePlan=prepared.0; formatReceipts=prepared.1 }
            var writes=try validatePlan(root,plan:effectivePlan,preservedLinkIssues:&preserved)
            for (index,change) in eObjects(effectivePlan["changes"]).enumerated() { for field in ["expected_heads","observations"] { if let value=change[field] { writes[index][field]=value } } }
            let proposed=writes.map{["path":$0["path"] ?? "","text":$0["after"] ?? "","meta":metadata(eString($0["after"]))]}
            var warnings=try schemaWarnings(root,notes:proposed,resolvingPaths:Set(writes.map{eString($0["path"])}))
            let errors=warnings.filter{eString($0["severity"]) == "error"}; if !errors.isEmpty { throw OrbitError("Schema validation failed: "+eJSON(errors).trimmingCharacters(in:.whitespacesAndNewlines)) }
            var extra:JSONObject=[:]
            if let formatReceipts { warnings += (preserved ?? []).map{v in var r=v;r["severity"]="warning";r["preserved"]=true;return r};extra["formatted"]=formatReceipts }
            let changed=writes.filter{!eEqual($0["before"],$0["after"]) || $0["expected_heads"] != nil || !strings($0["observations"]).isEmpty}
            let report=changed.map{["path":$0["path"] ?? "","action":$0["before"] is NSNull ? "create":"update","reason":$0["reason"] ?? ""]}
            if dryRun && replicated && !changed.isEmpty { _=try replicationCommit(root,writes:changed,requestID:requestID,requestDigest:requestHash,dryRun:true) }
            if dryRun || changed.isEmpty { return ["status":dryRun ? "preview":"unchanged","changes":report,"warnings":warnings].merging(extra,uniquingKeysWith:{$1}) }
            if replicated { var result=try replicationCommit(root,writes:changed,requestID:requestID,requestDigest:requestHash,dryRun:false);result["changes"]=report;result["warnings"]=warnings;return result.merging(extra,uniquingKeysWith:{$1}) }
            let id=UUID().uuidString.lowercased(),journal=try safe(root,".orbit/operations/"+id+".json")
            var record:JSONObject=["id":id,"created":now(),"status":"prepared","summary":effectivePlan["summary"] ?? "","writes":changed]
            try atomic(journal,encode(record))
            for write in changed { let target=try safe(root,eString(write["path"])),current:Any=eExists(target) ? try eText(target) : NSNull();guard eEqual(current,write["before"]) else { throw OrbitError("Write conflict: "+eString(write["path"])+" changed after validation; recover the prepared operation") };try atomic(target,Data(eString(write["after"]).utf8)) }
            record["status"]="committed";try atomic(journal,encode(record))
            let verified=try changed.allSatisfy{try Data(contentsOf:safe(root,eString($0["path"]))) == Data(eString($0["after"]).utf8)}
            return ["status":"committed","operation":id,"changes":report,"warnings":warnings,"verified":verified].merging(extra,uniquingKeysWith:{$1})
        }
    }
    func recover(_ root:URL,operation:String,rollback:Bool=false,abandon:Bool=false)throws->JSONObject {
        if replicationEnabled(root) { if rollback || abandon { throw OrbitError("Format 3 accepted history is immutable. Read history and apply an explicit restoring revision instead.") }; return try withLock(root) { try migrationEnsureWritable(root);let record=try replicationOperation(root,id:operation);return ["operation":operation,"status":record["status"] ?? "","sync":try replicationReconcile(root)] } }
        guard !eMatches("^[a-f0-9-]{36}$",operation).isEmpty else { throw OrbitError("Invalid operation id") }
        return try withLock(root) {
            try migrationEnsureWritable(root);let journal=try safe(root,".orbit/operations/"+operation+".json");var record=try readJSON(journal)
            guard eString(record["status"]) == "prepared" else { throw OrbitError("Only interrupted (prepared) operations can be recovered") }
            let writes=eObjects(record["writes"])
            if abandon { guard !rollback else { throw OrbitError("Choose rollback or abandon, not both") };record["status"]="abandoned";record["resolution"]="Explicitly abandoned; current files preserved including partial writes and external edits";var observed:JSONObject=[:];for write in writes { let url=try safe(root,eString(write["path"]));observed[eString(write["path"])]=eExists(url) ? digest(try Data(contentsOf:url)) : NSNull() };record["observed"]=observed;try atomic(journal,encode(record));return ["operation":operation,"status":"abandoned","preserved":observed,"hint":"Review partial writes and re-plan from current reads."] }
            func check(_ write:JSONObject,_ during:Bool)throws { let url=try safe(root,eString(write["path"])),current:Any=eExists(url) ? try eText(url):NSNull();if !eEqual(current,write["before"]) && !eEqual(current,write["after"]) { throw OrbitError("Recovery conflict: "+eString(write["path"])+(during ? " changed during recovery":" has subsequent edits")) } }
            for write in writes { try check(write,false) }
            for write in writes { try check(write,true);let url=try safe(root,eString(write["path"])),value=write[rollback ? "before":"after"];if value == nil || value is NSNull { if eExists(url) { try FileManager.default.removeItem(at:url) } } else { try atomic(url,Data(eString(value).utf8)) } }
            record["status"]=rollback ? "rolled-back":"committed";try atomic(journal,encode(record));return ["operation":operation,"status":record["status"] ?? ""]
        }
    }
    func capture(_ root:URL,source:String)throws->JSONObject {
        let sourceURL=URL(fileURLWithPath:(source as NSString).expandingTildeInPath).resolvingSymlinksInPath();var directory:ObjCBool=false
        guard FileManager.default.fileExists(atPath:sourceURL.path,isDirectory:&directory),!directory.boolValue else { throw OrbitError("Source must be an accessible local file") }
        let raw=try Data(contentsOf:sourceURL),hash=digest(raw),suffix=sourceURL.pathExtension,ext = !eMatches("^[a-zA-Z0-9]{1,10}$",suffix).isEmpty ? "."+suffix.lowercased():".bin"
        let pair:(URL,Bool)=try withLock(root) { try migrationEnsureWritable(root);let folder=try safe(root,"Sources/assets");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);let previous=try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix(hash+".")}.sorted{$0.path<$1.path};let dest=previous.first ?? folder.appendingPathComponent(hash+ext),duplicate=eExists(dest);if duplicate && digest(try Data(contentsOf:dest)) != hash { throw OrbitError("Captured asset was modified; refusing to overwrite") };if !duplicate { try atomic(dest,raw) };return (dest,duplicate) }
        var receipt:JSONObject=["status":pair.1 ? "already-captured":"captured","path":pair.0.path.replacingOccurrences(of:root.path+"/",with:""),"sha256":hash,"bytes":raw.count,"original_name":sourceURL.lastPathComponent,"extraction":"not-performed","integration":"not-performed","next":"Read/extract using host capabilities, then apply source and knowledge notes. Capture alone is not integration."]
        receipt["processing"]=try knowledgeInitCapture(root,receipt:receipt);return receipt
    }
    public func dispatchTarget(_ action:String,arguments:JSONObject,root:URL)throws->JSONObject {
        if action == "sync" { guard replicationEnabled(root) else { throw OrbitError("Cross-device sync requires format 3. Preview an Orbit migration first.") }; return try withLock(root) { switch eString(arguments["action"]).isEmpty ? "reconcile":eString(arguments["action"]) { case "status":return try replicationInspect(root);case "history":return try replicationHistory(root,path:eString(arguments["path"]));case "reconcile":try migrationEnsureWritable(root);return try replicationReconcile(root);default:throw OrbitError("Unknown sync action") } } }
        if ["read","search","context","index","catalog","relations","schema","maintain","integration"].contains(action) { return try coherent(root) { sync in var result=try dispatchCurrent(action,arguments:arguments,root:root);if !sync.isEmpty { result["sync"]=sync };return result } }
        return try dispatchCurrent(action,arguments:arguments,root:root)
    }
    func dispatchCurrent(_ action:String,arguments a:JSONObject,root:URL)throws->JSONObject {
        if ["search","catalog","context","relations","index"].contains(action),!eObjects(try migrationStatus(root)["pending"]).isEmpty { throw OrbitError("Finish the pending migration before retrieving a coherent Orbit view") }
        switch action {
        case "format":return try apply(root,plan:a["plan"] as? JSONObject ?? [:],dryRun:a["dry_run"] as? Bool ?? true,formatMetadata:true)
        case "migrate":return try migrate(root,action:a["action"] as? String ?? "plan",targetVersion:a["target_version"] as? String,planID:a["plan_id"] as? String,operation:a["operation"] as? String)
        case "schema":return try schemaCheck(root,noteType:a["note_type"] as? String)
        case "doctor":return try doctor(root)
        case "index":return try retrievalRefresh(root,rebuild:eBool(a["rebuild"]))
        case "catalog":return try retrievalCatalog(root,scope:a["scope"] as? String,limit:eInt(a["limit"],50),offset:eInt(a["offset"]),noteType:a["note_type"] as? String,status:a["status"] as? String)
        case "relations":return try knowledgeRelations(root,target:a["target"] as? String)
        case "maintain":return try knowledgeMaintain(root,limit:eInt(a["limit"],20))
        case "integration":return try knowledgeIntegration(root,record:a["record"] as? JSONObject)
        case "search":return try search(root,query:eString(a["query"]),limit:eInt(a["limit"],8),scope:a["scope"] as? String,noteType:a["note_type"] as? String,status:a["status"] as? String)
        case "read":return try read(root,path:eString(a["path"]),start:eInt(a["start"],1),count:eInt(a["count"],160))
        case "context":return try context(root,target:eString(a["target"]),depth:eInt(a["depth"],1),limit:eInt(a["limit"],12))
        case "apply":return try apply(root,plan:a["plan"] as? JSONObject ?? [:],dryRun:eBool(a["dry_run"]))
        case "capture":return try capture(root,source:eString(a["source"]))
        case "recover":return try recover(root,operation:eString(a["operation"]),rollback:eBool(a["rollback"]),abandon:eBool(a["abandon"]))
        default:throw OrbitError("Unknown action")
        }
    }
}
