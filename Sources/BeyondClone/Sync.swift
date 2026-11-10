import Foundation
import Darwin

// MARK: - Modalità

enum SyncMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case updateRight, updateLeft, updateBoth, mirrorRight, mirrorLeft
    var id: String { rawValue }

    var title: String {
        switch self {
        case .updateRight: return "Aggiorna destra"
        case .updateLeft: return "Aggiorna sinistra"
        case .updateBoth: return "Aggiorna entrambe"
        case .mirrorRight: return "Specchia a destra"
        case .mirrorLeft: return "Specchia a sinistra"
        }
    }

    var detail: String {
        switch self {
        case .updateRight: return "Copia a destra i file nuovi e più recenti. Non elimina nulla."
        case .updateLeft: return "Copia a sinistra i file nuovi e più recenti. Non elimina nulla."
        case .updateBoth: return "In entrambe le direzioni vince il più recente. Non elimina nulla."
        case .mirrorRight: return "Destra diventa identica a sinistra, eliminazioni comprese."
        case .mirrorLeft: return "Sinistra diventa identica a destra, eliminazioni comprese."
        }
    }

    var symbol: String {
        switch self {
        case .updateRight: return "arrow.right"
        case .updateLeft: return "arrow.left"
        case .updateBoth: return "arrow.left.arrow.right"
        case .mirrorRight: return "arrow.right.to.line"
        case .mirrorLeft: return "arrow.left.to.line"
        }
    }

    var isMirror: Bool { self == .mirrorLeft || self == .mirrorRight }
}

enum DeleteMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case archive, trash, permanent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .archive: return "Archivio sulla destinazione"
        case .trash: return "Cestino del Mac"
        case .permanent: return "Eliminazione definitiva"
        }
    }
    var detail: String {
        switch self {
        case .archive: return "Eliminati e sovrascritti vanno in «\(DirLister.archiveName)/data-ora/» nella cartella di destinazione. Funziona anche sul NAS."
        case .trash: return "Nel Cestino del Mac; sulle share di rete senza Cestino si usa l'archivio."
        case .permanent: return "Nessuna copia di sicurezza: i file eliminati o sovrascritti non si recuperano."
        }
    }
}

// MARK: - Piano

struct PlannedOp: Identifiable, Sendable {
    enum Kind: Sendable { case copy, mkdir, delete }
    let id = UUID()
    let kind: Kind
    let dest: Side
    let rel: String
    let source: URL?
    let target: URL
    let destRoot: URL
    let size: Int64
    let replaces: Bool
    let isDir: Bool

    var actionTitle: String {
        switch kind {
        case .copy: return replaces ? "Sovrascrivi" : "Copia"
        case .mkdir: return "Crea cartella"
        case .delete: return isDir ? "Elimina cartella" : "Elimina"
        }
    }
}

struct SyncPlan: Sendable {
    var ops: [PlannedOp] = []
    var conflicts: [String] = []

    func copies(to side: Side) -> [PlannedOp] { ops.filter { $0.kind == .copy && $0.dest == side } }
    func bytes(to side: Side) -> Int64 { copies(to: side).reduce(0) { $0 + $1.size } }
    var copyCount: Int { ops.filter { $0.kind == .copy }.count }
    var copyBytes: Int64 { ops.filter { $0.kind == .copy }.reduce(0) { $0 + $1.size } }
    var deleteCount: Int { ops.filter { $0.kind == .delete }.count }
    var mkdirCount: Int { ops.filter { $0.kind == .mkdir }.count }
    var replaceCount: Int { ops.filter { $0.kind == .copy && $0.replaces }.count }
    var isEmpty: Bool { ops.isEmpty }

    var summary: String {
        if ops.isEmpty { return conflicts.isEmpty ? "Già allineate" : "\(conflicts.count) conflitti, nient'altro da fare" }
        var parts: [String] = []
        if copyCount > 0 { parts.append("\(copyCount) da copiare (\(Fmt.size(copyBytes)))") }
        if mkdirCount > 0 { parts.append("\(mkdirCount) cartelle") }
        if deleteCount > 0 { parts.append("\(deleteCount) da eliminare") }
        if !conflicts.isEmpty { parts.append("\(conflicts.count) conflitti") }
        return parts.joined(separator: " · ")
    }
}

enum Planner {
    struct Roots: Sendable {
        let left: URL
        let right: URL
        func url(_ side: Side) -> URL { side == .left ? left : right }
    }

    static func plan(_ mode: SyncMode, _ root: FolderNode, roots: Roots) -> SyncPlan {
        var plan = SyncPlan()
        sync(mode, root.children, parents: (roots.left, roots.right), roots, &plan)
        return plan
    }

    static func planCopy(_ nodes: [FolderNode], to dest: Side, roots: Roots) -> SyncPlan {
        var plan = SyncPlan()
        for n in nodes { copy(n, to: dest, destParent: destParent(of: n, dest, roots), roots, &plan) }
        return plan
    }

    static func planDelete(_ nodes: [FolderNode], on side: Side, roots: Roots) -> SyncPlan {
        var plan = SyncPlan()
        for n in nodes {
            guard let info = n.info(side) else { continue }
            plan.ops.append(del(info, n, side, roots))
        }
        return plan
    }

    /// Cartella di destinazione reale del genitore (rispetta il nome effettivo, anche se differisce per maiuscole).
    private static func destParent(of n: FolderNode, _ side: Side, _ roots: Roots) -> URL {
        if let p = n.parent, p.parent != nil, let info = p.info(side), info.isDir { return info.url }
        if let p = n.parent, p.parent != nil {
            return destParent(of: p, side, roots).appendingPathComponent(p.name)
        }
        return roots.url(side)
    }

    private static func del(_ info: FileInfo, _ n: FolderNode, _ side: Side, _ roots: Roots) -> PlannedOp {
        PlannedOp(kind: .delete, dest: side, rel: n.relPath, source: nil, target: info.url, destRoot: roots.url(side),
                  size: info.isDir ? (side == .left ? n.tally.leftBytes : n.tally.rightBytes) : info.size,
                  replaces: false, isDir: info.isDir)
    }

    private static func copy(_ node: FolderNode, to dest: Side, destParent: URL, _ roots: Roots, _ plan: inout SyncPlan) {
        guard let src = node.info(dest.other) else { return }
        let dst = node.info(dest)
        let target = dst?.url ?? destParent.appendingPathComponent(node.name)
        if src.isDir {
            if let dst, !dst.isDir { plan.ops.append(del(dst, node, dest, roots)) }
            if dst == nil || dst?.isDir == false {
                plan.ops.append(PlannedOp(kind: .mkdir, dest: dest, rel: node.relPath, source: nil, target: target,
                                          destRoot: roots.url(dest), size: 0, replaces: false, isDir: true))
            }
            for c in node.children { copy(c, to: dest, destParent: target, roots, &plan) }
        } else {
            if node.status == .same { return }
            if let dst, dst.isDir { plan.ops.append(del(dst, node, dest, roots)) }
            plan.ops.append(PlannedOp(kind: .copy, dest: dest, rel: node.relPath, source: src.url, target: target,
                                      destRoot: roots.url(dest), size: src.size,
                                      replaces: dst != nil && dst?.isDir == false, isDir: false))
        }
    }

    private static func sync(_ mode: SyncMode, _ nodes: [FolderNode], parents: (URL, URL), _ roots: Roots, _ plan: inout SyncPlan) {
        for n in nodes where n.status != .same {
            let childParents = (n.left?.url ?? parents.0.appendingPathComponent(n.name),
                                n.right?.url ?? parents.1.appendingPathComponent(n.name))
            func parent(_ s: Side) -> URL { s == .left ? parents.0 : parents.1 }
            switch mode {
            case .updateRight, .updateLeft:
                let dest: Side = mode == .updateRight ? .right : .left
                let orphan: NodeStatus = dest == .right ? .leftOnly : .rightOnly
                let newer: NodeStatus = dest == .right ? .leftNewer : .rightNewer
                if n.isDirBoth {
                    sync(mode, n.children, parents: childParents, roots, &plan)
                } else if n.status == orphan || n.status == newer {
                    copy(n, to: dest, destParent: parent(dest), roots, &plan)
                } else if n.status != .same, !n.status.isOrphan {
                    plan.conflicts.append(n.relPath)
                }
            case .updateBoth:
                if n.isDirBoth {
                    sync(mode, n.children, parents: childParents, roots, &plan)
                } else {
                    switch n.status {
                    case .leftOnly, .leftNewer: copy(n, to: .right, destParent: parent(.right), roots, &plan)
                    case .rightOnly, .rightNewer: copy(n, to: .left, destParent: parent(.left), roots, &plan)
                    default: plan.conflicts.append(n.relPath)
                    }
                }
            case .mirrorRight, .mirrorLeft:
                let dest: Side = mode == .mirrorRight ? .right : .left
                let extra: NodeStatus = dest == .right ? .rightOnly : .leftOnly
                if n.status == extra {
                    if let info = n.info(dest) { plan.ops.append(del(info, n, dest, roots)) }
                } else if n.isDirBoth {
                    sync(mode, n.children, parents: childParents, roots, &plan)
                } else {
                    copy(n, to: dest, destParent: parent(dest), roots, &plan)
                }
            }
        }
    }
}

// MARK: - Esecuzione

struct SyncProgress: Sendable {
    var doneOps = 0
    var totalOps = 0
    var doneBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var active: [String] = []
    var errors = 0
    var speed: Double = 0
    var started = Date()
    var phase = "Preparazione"

    var fraction: Double {
        if totalBytes > 0 { return min(1, max(0, Double(doneBytes) / Double(totalBytes))) }
        return totalOps > 0 ? Double(doneOps) / Double(totalOps) : 0
    }

    var eta: TimeInterval? {
        guard speed > 1, totalBytes > doneBytes else { return nil }
        return Double(totalBytes - doneBytes) / speed
    }
}

struct SyncResult: Sendable {
    var done = 0
    var bytes: Int64 = 0
    var errors: [String] = []
    var notes: [String] = []
    var cancelled = false
    var archiveFolders = Set<String>()
    var duration: TimeInterval = 0
    var logURL: URL?

    var summary: String {
        var text = "\(done) operazioni · \(Fmt.size(bytes)) in \(Fmt.duration(duration))"
        if cancelled { text = "Interrotta: " + text }
        if !errors.isEmpty { text += " · \(errors.count) errori" }
        return text
    }
}

/// Registro testuale di un'esecuzione, in ~/Library/Logs/BeyondClone.
final class SyncLog: @unchecked Sendable {
    let url: URL
    private let handle: FileHandle?
    private let lock = NSLock()
    private let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static var folder: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/BeyondClone", isDirectory: true)
    }

    init(name: String) {
        let dir = Self.folder
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        url = dir.appendingPathComponent("\(f.string(from: Date())) \(safe).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        let text = "[\(time.string(from: Date()))] \(line)\n"
        handle?.write(Data(text.utf8))
    }

    func close() {
        lock.lock()
        try? handle?.close()
        lock.unlock()
    }
}

private final class CopyContext {
    let cancel: CancelFlag
    let onBytes: (Int64) -> Void
    var last: Int64 = 0

    init(cancel: CancelFlag, onBytes: @escaping (Int64) -> Void) {
        self.cancel = cancel
        self.onBytes = onBytes
    }

    func report(_ copied: Int64) {
        let delta = copied - last
        last = copied
        if delta != 0 { onBytes(delta) }
    }
}

private let copyCallback: copyfile_callback_t = { what, stage, state, _, _, ctx in
    guard let ctx else { return COPYFILE_CONTINUE }
    let c = Unmanaged<CopyContext>.fromOpaque(ctx).takeUnretainedValue()
    if c.cancel.isCancelled { return COPYFILE_QUIT }
    if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS, let state {
        var copied: off_t = 0
        copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
        c.report(Int64(copied))
    }
    return COPYFILE_CONTINUE
}

final class SyncExecutor: @unchecked Sendable {
    let plan: SyncPlan
    let deleteMode: DeleteMode
    let parallel: Int
    let cancel: CancelFlag
    let log: SyncLog?
    private let onProgress: @Sendable (SyncProgress) -> Void

    private let lock = NSLock()
    private var progress: SyncProgress
    private var result = SyncResult()
    private var lastEmit = Date.distantPast
    private var lastSample = (Date(), Int64(0))
    private var trashFallbackNoted = false
    private let stamp: String

    init(plan: SyncPlan, deleteMode: DeleteMode, parallel: Int, cancel: CancelFlag, log: SyncLog?,
         onProgress: @escaping @Sendable (SyncProgress) -> Void) {
        self.plan = plan
        self.deleteMode = deleteMode
        self.parallel = max(1, min(16, parallel))
        self.cancel = cancel
        self.log = log
        self.onProgress = onProgress
        progress = SyncProgress(totalOps: plan.ops.count, totalBytes: plan.copyBytes)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        stamp = f.string(from: Date())
    }

    // MARK: Stato condiviso tra i thread di copia

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func emit(force: Bool = false) {
        let snapshot: SyncProgress? = locked {
            let now = Date()
            let dt = now.timeIntervalSince(lastSample.0)
            if dt >= 0.5 {
                let inst = Double(progress.doneBytes - lastSample.1) / dt
                progress.speed = progress.speed == 0 ? inst : progress.speed * 0.7 + inst * 0.3
                lastSample = (now, progress.doneBytes)
            }
            guard force || now.timeIntervalSince(lastEmit) >= 0.1 else { return nil }
            lastEmit = now
            return progress
        }
        if let snapshot { onProgress(snapshot) }
    }

    private func addBytes(_ n: Int64) {
        locked { progress.doneBytes += n }
        emit()
    }

    private func begin(_ rel: String) {
        locked { progress.active.append(rel) }
        emit()
    }

    private func end(_ op: PlannedOp, error: Error?) {
        locked {
            if let i = progress.active.firstIndex(of: op.rel) { progress.active.remove(at: i) }
            progress.doneOps += 1
            if let error {
                progress.errors += 1
                result.errors.append("\(op.rel): \(error.localizedDescription)")
            } else {
                result.done += 1
                if op.kind == .copy { result.bytes += op.size }
            }
        }
        if let error {
            log?.write("ERRORE \(op.actionTitle) \(op.rel): \(error.localizedDescription)")
        } else {
            log?.write("\(op.actionTitle) \(op.dest == .right ? "→" : "←") \(op.rel)\(op.kind == .copy ? " (\(Fmt.size(op.size)))" : "")")
        }
        emit()
    }

    // MARK: Esecuzione

    func run() async -> SyncResult {
        let start = Date()
        log?.write("Inizio: \(plan.summary). Eliminazioni: \(deleteMode.title). Copie parallele: \(parallel)")
        let replacing = Set(plan.ops.filter { $0.kind != .delete }.map(\.rel))
        var before: [PlannedOp] = [], copies: [PlannedOp] = [], after: [PlannedOp] = []
        for op in plan.ops {
            switch op.kind {
            case .mkdir: before.append(op)
            case .copy: copies.append(op)
            case .delete: if replacing.contains(op.rel) { before.append(op) } else { after.append(op) }
            }
        }

        locked { progress.phase = "Preparazione cartelle" }
        for op in before where !cancel.isCancelled { perform(op) }

        locked { progress.phase = "Copia" }
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for op in copies {
                if cancel.isCancelled { break }
                if running >= parallel {
                    await group.next()
                    running -= 1
                }
                group.addTask { self.perform(op) }
                running += 1
            }
            await group.waitForAll()
        }

        locked { progress.phase = "Eliminazioni" }
        for op in after where !cancel.isCancelled { perform(op) }

        let final: SyncResult = locked {
            result.cancelled = cancel.isCancelled
            result.duration = Date().timeIntervalSince(start)
            result.logURL = log?.url
            progress.phase = "Fine"
            return result
        }
        emit(force: true)
        log?.write("Fine: \(final.summary)")
        log?.close()
        return final
    }

    private func perform(_ op: PlannedOp) {
        begin(op.rel)
        do {
            let fm = FileManager()
            switch op.kind {
            case .mkdir:
                try fm.createDirectory(at: op.target, withIntermediateDirectories: true)
            case .delete:
                if (try? op.target.checkResourceIsReachable()) == true || fm.fileExists(atPath: op.target.path) {
                    try remove(op.target, root: op.destRoot, rel: op.rel, fm)
                }
            case .copy:
                try copy(op, fm)
            }
            end(op, error: nil)
        } catch {
            end(op, error: error)
        }
    }

    private func copy(_ op: PlannedOp, _ fm: FileManager) throws {
        guard let source = op.source else { return }
        let parent = op.target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // Copia su un file temporaneo e poi rinomina: un'interruzione non lascia file a metà.
        let tmp = parent.appendingPathComponent(".\(op.target.lastPathComponent)\(DirLister.partSuffix)")
        if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }
        var reported: Int64 = 0
        do {
            try Self.copyFile(source, tmp, cancel: cancel) { delta in
                reported += delta
                self.addBytes(delta)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            addBytes(op.size - reported)
            throw error
        }
        if reported != op.size { addBytes(op.size - reported) }
        if let date = (try? fm.attributesOfItem(atPath: source.path))?[.modificationDate] {
            try? fm.setAttributes([.modificationDate: date], ofItemAtPath: tmp.path)
        }
        if fm.fileExists(atPath: op.target.path) {
            do {
                try remove(op.target, root: op.destRoot, rel: op.rel, fm)
            } catch {
                try? fm.removeItem(at: tmp)
                throw error
            }
        }
        try fm.moveItem(at: tmp, to: op.target)
    }

    /// Copia un file con copyfile(3): avanzamento per byte e interruzione a metà file.
    static func copyFile(_ src: URL, _ dst: URL, cancel: CancelFlag, onBytes: @escaping (Int64) -> Void) throws {
        func attempt(_ flags: Int32) -> Int32 {
            guard let state = copyfile_state_alloc() else { return ENOMEM }
            defer { copyfile_state_free(state) }
            let ctx = CopyContext(cancel: cancel, onBytes: onBytes)
            let um = Unmanaged.passRetained(ctx)
            defer {
                ctx.report(ctx.last)
                um.release()
            }
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), um.toOpaque())
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(copyCallback, to: UnsafeRawPointer.self))
            let rc = copyfile(src.path, dst.path, state, copyfile_flags_t(flags))
            if rc != 0 {
                let e = errno
                // Il file parziale va tolto e i byte già contati restituiti prima di un nuovo tentativo.
                ctx.onBytes(-ctx.last)
                ctx.last = 0
                try? FileManager.default.removeItem(at: dst)
                return e == 0 ? EIO : e
            }
            return 0
        }
        var err = attempt(COPYFILE_DATA | COPYFILE_XATTR | COPYFILE_STAT)
        if err != 0, !cancel.isCancelled {
            // Alcune share SMB rifiutano permessi o attributi estesi: si ripiega sui soli dati.
            err = attempt(COPYFILE_DATA)
        }
        if cancel.isCancelled { throw SyncError.cancelled }
        if err != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(err)) }
    }

    private func archive(_ url: URL, root: URL, rel: String, _ fm: FileManager) throws {
        let base = root.appendingPathComponent(DirLister.archiveName).appendingPathComponent(stamp)
        let dest = base.appendingPathComponent(rel)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: url, to: dest)
        locked { _ = result.archiveFolders.insert(base.path) }
    }

    private func remove(_ url: URL, root: URL, rel: String, _ fm: FileManager) throws {
        switch deleteMode {
        case .permanent:
            try fm.removeItem(at: url)
        case .archive:
            try archive(url, root: root, rel: rel, fm)
        case .trash:
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
            } catch {
                try archive(url, root: root, rel: rel, fm)
                let first: Bool = locked {
                    defer { trashFallbackNoted = true }
                    return !trashFallbackNoted
                }
                if first {
                    locked { result.notes.append("Cestino non disponibile su \(root.path): usato l'archivio") }
                }
            }
        }
    }
}
