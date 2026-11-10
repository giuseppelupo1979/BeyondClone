import Foundation

// MARK: - Elementi dell'albero

struct FileInfo: Sendable {
    let url: URL
    let name: String
    let isDir: Bool
    let size: Int64
    let modified: Date?
}

enum NodeStatus: Sendable {
    case same, different, leftNewer, rightNewer, leftOnly, rightOnly, pending

    var isChanged: Bool { self == .different || self == .leftNewer || self == .rightNewer }
    var isOrphan: Bool { self == .leftOnly || self == .rightOnly }
}

/// Conteggi di un sottoalbero (per un file: il file stesso).
struct Tally: Sendable, Equatable {
    var same = 0
    var changed = 0
    var leftNewer = 0
    var rightNewer = 0
    var leftOnly = 0
    var rightOnly = 0
    var leftFiles = 0
    var rightFiles = 0
    var leftBytes: Int64 = 0
    var rightBytes: Int64 = 0

    var diffs: Int { changed + leftOnly + rightOnly }
    var compared: Int { same + diffs }

    static func += (a: inout Tally, b: Tally) {
        a.same += b.same
        a.changed += b.changed
        a.leftNewer += b.leftNewer
        a.rightNewer += b.rightNewer
        a.leftOnly += b.leftOnly
        a.rightOnly += b.rightOnly
        a.leftFiles += b.leftFiles
        a.rightFiles += b.rightFiles
        a.leftBytes += b.leftBytes
        a.rightBytes += b.rightBytes
    }

    static func file(_ s: NodeStatus, _ l: FileInfo?, _ r: FileInfo?) -> Tally {
        var t = Tally()
        if let l {
            t.leftFiles = 1
            t.leftBytes = l.size
        }
        if let r {
            t.rightFiles = 1
            t.rightBytes = r.size
        }
        switch s {
        case .same: t.same = 1
        case .different: t.changed = 1
        case .leftNewer:
            t.changed = 1
            t.leftNewer = 1
        case .rightNewer:
            t.changed = 1
            t.rightNewer = 1
        case .leftOnly: t.leftOnly = 1
        case .rightOnly: t.rightOnly = 1
        case .pending: break
        }
        return t
    }
}

final class FolderNode: @unchecked Sendable {
    let name: String
    let relPath: String
    var left: FileInfo?
    var right: FileInfo?
    weak var parent: FolderNode?
    var children: [FolderNode] = []
    var status: NodeStatus
    var tally = Tally()
    /// Contenuto letto (per le cartelle).
    var listed = false
    /// Lettura già richiesta.
    var requested = false
    /// Sottoalbero interamente analizzato.
    var complete = false
    var pendingDirs = 0
    var error: String?

    // Cache della vista filtrata.
    var viewGen = -1
    var viewChildren: [FolderNode] = []

    init(name: String, relPath: String, left: FileInfo?, right: FileInfo?, status: NodeStatus) {
        self.name = name
        self.relPath = relPath
        self.left = left
        self.right = right
        self.status = status
    }

    static func root(_ l: URL, _ r: URL) -> FolderNode {
        FolderNode(name: "", relPath: "",
                   left: FileInfo(url: l, name: l.lastPathComponent, isDir: true, size: 0, modified: nil),
                   right: FileInfo(url: r, name: r.lastPathComponent, isDir: true, size: 0, modified: nil),
                   status: .pending)
    }

    var isDir: Bool { (left?.isDir ?? false) || (right?.isDir ?? false) }
    var isDirBoth: Bool { (left?.isDir ?? false) && (right?.isDir ?? false) }
    var leftDirURL: URL? { left?.isDir == true ? left?.url : nil }
    var rightDirURL: URL? { right?.isDir == true ? right?.url : nil }
    var typeMismatch: Bool { left != nil && right != nil && left!.isDir != right!.isDir }

    func info(_ side: Side) -> FileInfo? { side == .left ? left : right }

    var depth: Int {
        var d = 0
        var p = parent
        while let q = p, q.parent != nil {
            d += 1
            p = q.parent
        }
        return d
    }
}

// MARK: - Opzioni di confronto

enum CompareMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case sizeDate, size, content
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sizeDate: return "Dimensione e data"
        case .size: return "Solo dimensione"
        case .content: return "Contenuto (lento, legge i file)"
        }
    }
}

struct DirOptions: Codable, Hashable, Sendable {
    static let defaultExcludes = ".DS_Store, ._*, .Spotlight-V100, .Trashes, .fseventsd, .TemporaryItems, .DocumentRevisions-V100, Thumbs.db, desktop.ini, @eaDir, #recycle, #snapshot, .SynologyWorkingDirectory"

    var method: CompareMethod = .sizeDate
    var timeTolerance: Double = 2
    var ignoreHourShift = true
    var includeHidden = true
    var caseInsensitive = false
    var excludes = DirOptions.defaultExcludes
    var parallelCopies = 4

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DirOptions()
        method = try c.decodeIfPresent(CompareMethod.self, forKey: .method) ?? d.method
        timeTolerance = try c.decodeIfPresent(Double.self, forKey: .timeTolerance) ?? d.timeTolerance
        ignoreHourShift = try c.decodeIfPresent(Bool.self, forKey: .ignoreHourShift) ?? d.ignoreHourShift
        includeHidden = try c.decodeIfPresent(Bool.self, forKey: .includeHidden) ?? d.includeHidden
        caseInsensitive = try c.decodeIfPresent(Bool.self, forKey: .caseInsensitive) ?? d.caseInsensitive
        excludes = try c.decodeIfPresent(String.self, forKey: .excludes) ?? d.excludes
        parallelCopies = try c.decodeIfPresent(Int.self, forKey: .parallelCopies) ?? d.parallelCopies
    }

    var excludeList: [String] {
        excludes.split(whereSeparator: { ",;\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Le opzioni che cambiano il risultato del confronto (non il numero di copie parallele).
    var scanKey: [String] {
        [method.rawValue, "\(timeTolerance)", "\(ignoreHourShift)", "\(includeHidden)", "\(caseInsensitive)", excludes]
    }
}

// MARK: - Lettura di una cartella su entrambi i lati

struct ListEntry: Sendable {
    let name: String
    let left: FileInfo?
    let right: FileInfo?
    let status: NodeStatus
}

struct ListResult: Sendable {
    var entries: [ListEntry] = []
    var error: String?
}

enum DirLister {
    static let archiveName = ".beyondclone-archivio"
    static let partSuffix = ".bcpart"
    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]

    static func readSide(_ url: URL?) -> ([FileInfo], String?) {
        guard let url else { return ([], nil) }
        do {
            let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
            var out: [FileInfo] = []
            out.reserveCapacity(items.count)
            for item in items {
                let v = try? item.resourceValues(forKeys: Set(keys))
                // I pacchetti (.app, .photoslibrary…) restano cartelle: vanno sincronizzati per intero.
                let isDir = (v?.isDirectory ?? false) && !(v?.isSymbolicLink ?? false)
                out.append(FileInfo(url: item, name: item.lastPathComponent, isDir: isDir,
                                    size: Int64(v?.fileSize ?? 0), modified: v?.contentModificationDate))
            }
            return (out, nil)
        } catch {
            return ([], "\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    static func excluded(_ name: String, rel: String, _ o: DirOptions, _ patterns: [String]) -> Bool {
        if name == archiveName || name.hasSuffix(partSuffix) { return true }
        if !o.includeHidden, name.hasPrefix(".") { return true }
        for p in patterns {
            if p.contains("/") {
                if fnmatch(p, rel, 0) == 0 { return true }
            } else if fnmatch(p, name, 0) == 0 {
                return true
            }
        }
        return false
    }

    static func key(_ name: String, _ o: DirOptions) -> String {
        let k = name.precomposedStringWithCanonicalMapping
        return o.caseInsensitive ? k.lowercased() : k
    }

    static func list(left: URL?, right: URL?, rel: String, options o: DirOptions, patterns: [String], cancel: CancelFlag) -> ListResult {
        let (l, le) = readSide(left)
        let (r, re) = readSide(right)
        var res = ListResult()
        res.error = [le, re].compactMap { $0 }.first
        var map: [String: (FileInfo?, FileInfo?)] = [:]
        map.reserveCapacity(l.count + r.count)
        for f in l {
            map[key(f.name, o), default: (nil, nil)].0 = f
        }
        for f in r {
            map[key(f.name, o), default: (nil, nil)].1 = f
        }
        for (_, pair) in map {
            if cancel.isCancelled { break }
            let name = (pair.0 ?? pair.1)!.name
            let childRel = rel.isEmpty ? name : rel + "/" + name
            if excluded(name, rel: childRel, o, patterns) { continue }
            res.entries.append(ListEntry(name: name, left: pair.0, right: pair.1, status: classify(pair.0, pair.1, o, cancel)))
        }
        res.entries.sort {
            let ad = ($0.left?.isDir ?? false) || ($0.right?.isDir ?? false)
            let bd = ($1.left?.isDir ?? false) || ($1.right?.isDir ?? false)
            if ad != bd { return ad }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return res
    }

    static func classify(_ l: FileInfo?, _ r: FileInfo?, _ o: DirOptions, _ cancel: CancelFlag) -> NodeStatus {
        guard let l else { return .rightOnly }
        guard let r else { return .leftOnly }
        if l.isDir != r.isDir { return .different }
        if l.isDir { return .pending }
        let dt = (l.modified ?? .distantPast).timeIntervalSince(r.modified ?? .distantPast)
        var adt = abs(dt)
        // Ora legale o fuso diverso tra Mac e NAS: scarto di un'ora esatta.
        if o.ignoreHourShift, abs(adt - 3600) <= o.timeTolerance { adt = 0 }
        let newer: NodeStatus = adt <= o.timeTolerance ? .different : (dt > 0 ? .leftNewer : .rightNewer)
        switch o.method {
        case .size:
            return l.size == r.size ? .same : newer
        case .sizeDate:
            if l.size != r.size { return newer }
            return adt <= o.timeTolerance ? .same : newer
        case .content:
            if l.size != r.size { return newer }
            return sameContent(l.url, r.url, cancel) ? .same : newer
        }
    }

    static func sameContent(_ a: URL, _ b: URL, _ cancel: CancelFlag) -> Bool {
        guard let fa = try? FileHandle(forReadingFrom: a), let fb = try? FileHandle(forReadingFrom: b) else { return false }
        defer {
            try? fa.close()
            try? fb.close()
        }
        while true {
            if cancel.isCancelled { return false }
            let da = (try? fa.read(upToCount: 1 << 20)) ?? Data()
            let db = (try? fb.read(upToCount: 1 << 20)) ?? Data()
            if da != db { return false }
            if da.isEmpty { return true }
        }
    }
}

// MARK: - Costruzione dell'albero (condivisa da analisi progressiva e analisi completa)

enum Tree {
    /// Aggancia il contenuto letto; ritorna le sottocartelle da leggere.
    static func attach(_ node: FolderNode, _ res: ListResult) -> [FolderNode] {
        node.listed = true
        node.error = res.error
        var subdirs: [FolderNode] = []
        node.children = res.entries.map { e in
            let rel = node.relPath.isEmpty ? e.name : node.relPath + "/" + e.name
            let c = FolderNode(name: e.name, relPath: rel, left: e.left, right: e.right, status: e.status)
            c.parent = node
            if c.isDir {
                subdirs.append(c)
            } else {
                c.tally = Tally.file(e.status, e.left, e.right)
                c.listed = true
                c.requested = true
                c.complete = true
            }
            return c
        }
        node.pendingDirs = subdirs.count
        return subdirs
    }

    /// Da chiamare quando la cartella è letta e non ha sottocartelle in sospeso.
    /// Risale l'albero chiudendo i genitori completati. Ritorna true se si è chiusa la radice.
    static func finish(_ node: FolderNode) -> Bool {
        var cur: FolderNode? = node
        while let n = cur {
            n.complete = true
            var t = Tally()
            for c in n.children { t += c.tally }
            if n.typeMismatch {
                n.status = .different
                t.changed += 1
            } else if n.left == nil {
                n.status = .rightOnly
                if n.children.isEmpty { t.rightOnly += 1 }
            } else if n.right == nil {
                n.status = .leftOnly
                if n.children.isEmpty { t.leftOnly += 1 }
            } else {
                n.status = (t.diffs == 0 && n.error == nil) ? .same : .different
            }
            n.tally = t
            guard let p = n.parent else { return true }
            p.pendingDirs -= 1
            cur = (p.listed && p.pendingDirs == 0) ? p : nil
        }
        return false
    }

    /// Analisi completa sincrona (autotest e uso senza interfaccia).
    static func scanSync(left: URL, right: URL, options: DirOptions, cancel: CancelFlag = CancelFlag()) throws -> FolderNode {
        for u in [left, right] where !Reach.isDir(u.path) { throw SyncError.unreachable(u.path) }
        let root = FolderNode.root(left, right)
        let patterns = options.excludeList
        var stack = [root]
        while let n = stack.popLast() {
            if cancel.isCancelled { throw SyncError.cancelled }
            let res = DirLister.list(left: n.leftDirURL, right: n.rightDirURL, rel: n.relPath, options: options, patterns: patterns, cancel: cancel)
            let subs = Tree.attach(n, res)
            if subs.isEmpty { _ = Tree.finish(n) }
            stack.append(contentsOf: subs)
        }
        return root
    }
}

enum Reach {
    static func isDir(_ path: String) -> Bool {
        var d: ObjCBool = false
        return !path.isEmpty && FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

enum SyncError: LocalizedError {
    case unreachable(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unreachable(let p): return "Cartella non raggiungibile: \(p)"
        case .cancelled: return "Annullato"
        }
    }
}
