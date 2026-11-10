import Foundation
import AppKit
import Combine

enum FolderFilter: String, CaseIterable, Identifiable {
    case all, diffs, changed, leftOnly, rightOnly, same
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Tutto"
        case .diffs: return "Differenze"
        case .changed: return "Modificati"
        case .leftOnly: return "Solo a sinistra"
        case .rightOnly: return "Solo a destra"
        case .same: return "Uguali"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .diffs: return "exclamationmark.circle"
        case .changed: return "pencil.circle"
        case .leftOnly: return "arrow.left.circle"
        case .rightOnly: return "arrow.right.circle"
        case .same: return "equal.circle"
        }
    }

    var help: String {
        switch self {
        case .all: return "Mostra tutto"
        case .diffs: return "Mostra solo le differenze: modificati e presenti da un solo lato"
        case .changed: return "Mostra solo i file presenti su entrambi i lati ma diversi"
        case .leftOnly: return "Mostra solo gli elementi presenti soltanto a sinistra"
        case .rightOnly: return "Mostra solo gli elementi presenti soltanto a destra"
        case .same: return "Mostra solo gli elementi uguali"
        }
    }

    func matches(_ s: NodeStatus) -> Bool {
        switch self {
        case .all: return true
        case .diffs: return s != .same
        case .changed: return s.isChanged
        case .leftOnly: return s == .leftOnly
        case .rightOnly: return s == .rightOnly
        case .same: return s == .same
        }
    }
}

enum ScanState: Equatable {
    case idle, connecting, scanning, done, failed(String)
}

struct ScanStats {
    var dirs = 0
    var items = 0
    var errors: [String] = []
    var started = Date()
    var finished: Date?
    var elapsed: TimeInterval { (finished ?? Date()).timeIntervalSince(started) }
}

struct RunSummary {
    let date: Date
    let result: SyncResult
}

struct PlanRequest: Identifiable {
    let id = UUID()
    let title: String
    var mode: SyncMode?
    var deleteMode: DeleteMode
    let plan: SyncPlan
    var freeLeft: Int64?
    var freeRight: Int64?
}

/// Un confronto tra due cartelle: analisi progressiva, filtri, sincronizzazione.
@MainActor
final class FolderSession: ObservableObject, Identifiable {
    let id: UUID
    let profileID: UUID?

    @Published var name: String { didSet { persist() } }
    @Published private(set) var leftURL: URL?
    @Published private(set) var rightURL: URL?
    @Published var leftServer = "" { didSet { persist() } }
    @Published var rightServer = "" { didSet { persist() } }
    @Published var options: DirOptions {
        didSet {
            persist()
            if options.scanKey != oldValue.scanKey { rescan() }
        }
    }
    @Published var mode: SyncMode { didSet { persist(); refreshModePlan() } }
    @Published var deleteMode: DeleteMode { didSet { persist() } }

    @Published private(set) var root: FolderNode?
    @Published private(set) var state: ScanState = .idle
    @Published private(set) var stats = ScanStats()
    @Published private(set) var liveTally = Tally()
    @Published private(set) var treeVersion = 0
    @Published private(set) var modePlan: SyncPlan?
    @Published private(set) var leftVolume: VolumeInfo?
    @Published private(set) var rightVolume: VolumeInfo?

    @Published var filter: FolderFilter = .all { didSet { bumpView() } }
    @Published var search = "" { didSet { if search != oldValue { bumpView() } } }
    @Published var selection: [FolderNode] = []

    @Published private(set) var progress: SyncProgress?
    @Published private(set) var lastRun: RunSummary?
    @Published var preview: PlanRequest?

    private(set) var viewGen = 0
    // Contatori dell'analisi: pubblicati a intervalli, non a ogni cartella (evita migliaia di ridisegni).
    private var pendingStats = ScanStats()
    private var pendingTally = Tally()
    private var gen = 0
    private var queue: [FolderNode] = []
    private var queueHead = 0
    private var urgent: [FolderNode] = []
    private var inFlight = 0
    private var refreshPending = false
    private var scanCancel = CancelFlag()
    private var runCancel = CancelFlag()
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var loading = true

    /// Letture di cartella contemporanee: molto utile sulle share di rete, dove conta la latenza.
    private let maxInFlight = 12

    init(profile: SyncProfile) {
        id = profile.id
        profileID = profile.id
        name = profile.name
        leftURL = profile.leftURL
        rightURL = profile.rightURL
        leftServer = profile.leftServer
        rightServer = profile.rightServer
        options = profile.options
        mode = profile.mode
        deleteMode = profile.deleteMode
        loading = false
        rescan()
    }

    init(left: URL?, right: URL?) {
        id = UUID()
        profileID = nil
        name = "Confronto"
        leftURL = left
        rightURL = right
        options = DirOptions()
        mode = .updateRight
        deleteMode = .archive
        loading = false
        updateName()
        rescan()
    }

    var profile: SyncProfile? { profileID.flatMap { ProfileStore.shared.profile($0) } }
    var isRunning: Bool { progress != nil }
    var isScanning: Bool { state == .scanning || state == .connecting }
    var roots: Planner.Roots? {
        guard let l = leftURL, let r = rightURL else { return nil }
        return .init(left: l, right: r)
    }

    func url(_ side: Side) -> URL? { side == .left ? leftURL : rightURL }
    func volume(_ side: Side) -> VolumeInfo? { side == .left ? leftVolume : rightVolume }
    func server(_ side: Side) -> String { side == .left ? leftServer : rightServer }

    private func updateName() {
        guard profileID == nil else { return }
        let l = leftURL?.lastPathComponent ?? "…", r = rightURL?.lastPathComponent ?? "…"
        name = leftURL == nil && rightURL == nil ? "Nuovo confronto" : "\(l) ↔ \(r)"
    }

    private func persist() {
        guard !loading, let id = profileID, var p = ProfileStore.shared.profile(id) else { return }
        p.name = name
        p.left = leftURL?.path ?? ""
        p.right = rightURL?.path ?? ""
        p.leftServer = leftServer
        p.rightServer = rightServer
        p.options = options
        p.mode = mode
        p.deleteMode = deleteMode
        ProfileStore.shared.upsert(p)
    }

    func set(_ url: URL, side: Side) {
        if side == .left { leftURL = url } else { rightURL = url }
        Task {
            if let s = await Task.detached(priority: .utility, operation: { NASMount.serverURL(for: url) }).value, url == self.url(side) {
                if side == .left { leftServer = s } else { rightServer = s }
            }
        }
        RecentFolders.add(url)
        updateName()
        persist()
        rescan()
    }

    func swapSides() {
        guard !isRunning else { return }
        swap(&leftURL, &rightURL)
        let s = leftServer
        leftServer = rightServer
        rightServer = s
        switch mode {
        case .updateLeft: mode = .updateRight
        case .updateRight: mode = .updateLeft
        case .mirrorLeft: mode = .mirrorRight
        case .mirrorRight: mode = .mirrorLeft
        case .updateBoth: break
        }
        updateName()
        persist()
        rescan()
    }

    // MARK: - Analisi progressiva

    func rescan() {
        scanCancel.cancel()
        gen += 1
        let g = gen
        queue.removeAll()
        queueHead = 0
        urgent.removeAll()
        inFlight = 0
        selection = []
        modePlan = nil
        liveTally = Tally()
        stats = ScanStats()
        pendingStats = ScanStats()
        pendingTally = Tally()
        guard let l = leftURL, let r = rightURL else {
            root = nil
            state = .idle
            refreshVolumes()
            bumpView()
            return
        }
        if profileID == nil {
            RecentStore.shared.add(left: l, right: r)
            LastSelection.save(.pair(left: l.path, right: r.path))
        }
        let flag = CancelFlag()
        scanCancel = flag
        state = .connecting
        Task {
            do {
                try await ensureMounted()
            } catch {
                guard g == gen else { return }
                fail(error.localizedDescription)
                return
            }
            guard g == gen else { return }
            for (u, s) in [(l, leftServer), (r, rightServer)] where !Reach.isDir(u.path) {
                fail(s.isEmpty ? "Cartella non raggiungibile: \(u.path)" : "Cartella non trovata dopo il montaggio: \(u.path)")
                return
            }
            refreshVolumes()
            let node = FolderNode.root(l, r)
            root = node
            state = .scanning
            pendingStats = ScanStats()
            stats = pendingStats
            queue = [node]
            pump()
            bumpView()
        }
    }

    /// Informazioni sui volumi (spazio libero, server) lette in background: un volume di rete lento non blocca la finestra.
    func refreshVolumes() {
        let l = leftURL, r = rightURL
        Task {
            let (lv, rv) = await Task.detached(priority: .utility) { (l.flatMap(VolumeInfo.of), r.flatMap(VolumeInfo.of)) }.value
            guard l == leftURL, r == rightURL else { return }
            leftVolume = lv
            rightVolume = rv
        }
    }

    private func fail(_ message: String) {
        root = nil
        state = .failed(message)
        resolveWaiters(false)
        bumpView()
    }

    private func ensureMounted() async throws {
        for (url, server) in [(leftURL, leftServer), (rightURL, rightServer)] {
            guard let url, !Reach.isDir(url.path), !server.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            _ = try await NASMount.mount(server)
        }
    }

    private func nextNode() -> FolderNode? {
        while let n = urgent.popLast() {
            if !n.requested {
                n.requested = true
                return n
            }
        }
        while queueHead < queue.count {
            let n = queue[queueHead]
            queueHead += 1
            if !n.requested {
                n.requested = true
                return n
            }
        }
        if queueHead > 4096, queueHead == queue.count {
            queue.removeAll()
            queueHead = 0
        }
        return nil
    }

    private func pump() {
        let o = options
        let patterns = o.excludeList
        while inFlight < maxInFlight, let node = nextNode() {
            inFlight += 1
            let g = gen, flag = scanCancel
            let l = node.leftDirURL, r = node.rightDirURL, rel = node.relPath
            Task.detached(priority: .userInitiated) {
                let res = DirLister.list(left: l, right: r, rel: rel, options: o, patterns: patterns, cancel: flag)
                await MainActor.run { [weak self] in self?.merge(node, res, g) }
            }
        }
    }

    private func merge(_ node: FolderNode, _ res: ListResult, _ g: Int) {
        guard g == gen else { return }
        inFlight -= 1
        let subs = Tree.attach(node, res)
        pendingStats.dirs += 1
        pendingStats.items += res.entries.count
        if let e = res.error { pendingStats.errors.append(e) }
        for c in node.children where !c.isDir { pendingTally += c.tally }
        if subs.isEmpty, Tree.finish(node) {
            finishScan()
        } else {
            queue.append(contentsOf: subs)
            pump()
        }
        scheduleRefresh()
    }

    private func finishScan() {
        state = .done
        pendingStats.finished = Date()
        stats = pendingStats
        if let root { pendingTally = root.tally }
        liveTally = pendingTally
        refreshModePlan()
        bumpView()
        resolveWaiters(true)
    }

    private func resolveWaiters(_ ok: Bool) {
        let w = waiters
        waiters.removeAll()
        w.forEach { $0.resume(returning: ok) }
    }

    /// Attende la fine dell'analisi in corso. Ritorna false se è fallita.
    func waitForScan() async -> Bool {
        switch state {
        case .done: return true
        case .failed, .idle: return false
        default: return await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// Le cartelle che l'utente apre vengono lette per prime.
    func prioritize(_ node: FolderNode) {
        guard node.isDir, !node.requested else { return }
        urgent.append(node)
        pump()
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            if self.state == .scanning {
                self.stats = self.pendingStats
                self.liveTally = self.pendingTally
            }
            self.bumpView()
        }
    }

    private func bumpView() {
        viewGen += 1
        treeVersion += 1
    }

    func stopScan() {
        guard isScanning else { return }
        scanCancel.cancel()
        gen += 1
        state = .failed("Analisi interrotta")
        resolveWaiters(false)
    }

    // MARK: - Vista filtrata

    func visibleChildren(_ node: FolderNode) -> [FolderNode] {
        if node.viewGen == viewGen { return node.viewChildren }
        let kids = (filter == .all && search.isEmpty) ? node.children : node.children.filter(isVisible)
        node.viewChildren = kids
        node.viewGen = viewGen
        return kids
    }

    private func nameMatches(_ n: FolderNode) -> Bool {
        search.isEmpty || n.name.localizedCaseInsensitiveContains(search)
    }

    private func isVisible(_ n: FolderNode) -> Bool {
        if n.isDir {
            if !n.complete { return true }
            if !visibleChildren(n).isEmpty { return true }
            let leaf = n.children.isEmpty || n.status.isOrphan || n.typeMismatch
            return leaf && filter.matches(n.status) && nameMatches(n)
        }
        return filter.matches(n.status) && nameMatches(n)
    }

    // MARK: - Piani e sincronizzazione

    private func refreshModePlan() {
        guard state == .done, let root, let roots else {
            modePlan = nil
            return
        }
        modePlan = Planner.plan(mode, root, roots: roots)
    }

    private func incomplete(_ nodes: [FolderNode]) -> Bool { nodes.contains { $0.isDir && !$0.complete } }

    private func ask(_ title: String, _ mode: SyncMode?, _ plan: SyncPlan) {
        if plan.isEmpty {
            infoAlert(title, plan.conflicts.isEmpty ? "Niente da fare: già allineate." : plan.summary)
            return
        }
        preview = PlanRequest(title: title, mode: mode, deleteMode: deleteMode, plan: plan,
                              freeLeft: leftVolume?.free, freeRight: rightVolume?.free)
    }

    func prepareSync() {
        guard let root, let roots else { return }
        guard state == .done else {
            infoAlert("Analisi in corso", "Attendi la fine dell'analisi per sincronizzare tutto l'albero.")
            return
        }
        ask(mode.title, mode, Planner.plan(mode, root, roots: roots))
    }

    func prepareCopy(_ nodes: [FolderNode], to dest: Side) {
        guard let roots, !nodes.isEmpty else { return }
        if incomplete(nodes) {
            infoAlert("Analisi in corso", "Alcune cartelle selezionate non sono ancora state analizzate per intero.")
            return
        }
        ask("Copia a \(dest.label)", nil, Planner.planCopy(topLevel(nodes), to: dest, roots: roots))
    }

    func prepareDelete(_ nodes: [FolderNode], on side: Side) {
        guard let roots, !nodes.isEmpty else { return }
        ask("Elimina a \(side.label)", nil, Planner.planDelete(topLevel(nodes), on: side, roots: roots))
    }

    /// Esclude dalla selezione gli elementi già contenuti in una cartella selezionata.
    private func topLevel(_ nodes: [FolderNode]) -> [FolderNode] {
        let set = Set(nodes.map(ObjectIdentifier.init))
        return nodes.filter { n in
            var p = n.parent
            while let q = p {
                if set.contains(ObjectIdentifier(q)) { return false }
                p = q.parent
            }
            return true
        }
    }

    func exclude(_ nodes: [FolderNode]) {
        let names = Set(nodes.map(\.name))
        var list = options.excludeList
        for n in names where !list.contains(n) { list.append(n) }
        options.excludes = list.joined(separator: ", ")
    }

    func run(_ plan: SyncPlan) {
        guard !isRunning else { return }
        let flag = CancelFlag()
        runCancel = flag
        let log = SyncLog(name: name)
        let exec = SyncExecutor(plan: plan, deleteMode: deleteMode, parallel: options.parallelCopies, cancel: flag, log: log) { p in
            Task { @MainActor [weak self] in
                if self?.progress != nil { self?.progress = p }
            }
        }
        progress = SyncProgress(totalOps: plan.ops.count, totalBytes: plan.copyBytes)
        Task {
            let result = await exec.run()
            progress = nil
            lastRun = RunSummary(date: Date(), result: result)
            if let id = profileID, var p = ProfileStore.shared.profile(id) {
                p.lastRun = Date()
                p.lastResult = result.summary
                ProfileStore.shared.upsert(p)
            }
            if !result.errors.isEmpty || !result.notes.isEmpty {
                NSSound(named: "Basso")?.play()
            }
            NSApp.requestUserAttention(.informationalRequest)
            rescan()
        }
    }

    func stopRun() { runCancel.cancel() }

    /// Per "Sincronizza tutti": analizza e ritorna il piano della modalità del profilo.
    func analyzeForBatch() async -> Result<SyncPlan, Error> {
        if !isScanning, state != .done { rescan() }
        let ok = await waitForScan()
        guard ok, let root, let roots else {
            if case .failed(let m) = state { return .failure(NSError(domain: "BeyondClone", code: 2, userInfo: [NSLocalizedDescriptionKey: m])) }
            return .failure(SyncError.cancelled)
        }
        return .success(Planner.plan(mode, root, roots: roots))
    }

    func makeProfile() -> SyncProfile {
        var p = SyncProfile()
        p.name = name
        p.left = leftURL?.path ?? ""
        p.right = rightURL?.path ?? ""
        p.leftServer = leftServer
        p.rightServer = rightServer
        p.mode = mode
        p.deleteMode = deleteMode
        p.options = options
        return p
    }
}

enum RecentFolders {
    private static let key = "recentFolders"
    static var list: [URL] { (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) } }
    static func add(_ u: URL) {
        var l = (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { $0 != u.path }
        l.insert(u.path, at: 0)
        UserDefaults.standard.set(Array(l.prefix(12)), forKey: key)
    }
}

/// Sessioni aperte: una per profilo più i confronti al volo. Più sessioni possono sincronizzare insieme.
@MainActor
final class SessionRegistry: ObservableObject {
    static let shared = SessionRegistry()

    @Published private(set) var adhoc: [FolderSession] = []
    @Published private(set) var version = 0
    private var byProfile: [UUID: FolderSession] = [:]
    private var bag: [UUID: AnyCancellable] = [:]

    func existing(_ id: UUID) -> FolderSession? { byProfile[id] ?? adhoc.first { $0.id == id } }

    @discardableResult
    func open(profile id: UUID) -> FolderSession? {
        if let s = byProfile[id] { return s }
        guard let p = ProfileStore.shared.profile(id) else { return nil }
        let s = FolderSession(profile: p)
        byProfile[id] = s
        observe(s)
        version += 1
        return s
    }

    func newAdhoc(left: URL? = nil, right: URL? = nil) -> FolderSession {
        let s = FolderSession(left: left, right: right)
        adhoc.insert(s, at: 0)
        observe(s)
        return s
    }

    func close(_ id: UUID) {
        existing(id)?.stopScan()
        byProfile[id] = nil
        adhoc.removeAll { $0.id == id }
        bag[id] = nil
        version += 1
    }

    /// Le righe della barra laterale si aggiornano quando cambia lo stato di una sessione.
    private func observe(_ s: FolderSession) {
        bag[s.id] = s.objectWillChange
            .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.version += 1 }
    }

    var running: [FolderSession] { (Array(byProfile.values) + adhoc).filter(\.isRunning) }
}

// MARK: - Coppie recenti e ultima selezione

struct RecentPair: Codable, Hashable, Identifiable {
    var left: String
    var right: String
    var date: Date
    var id: String { left + "\u{1F}" + right }
    var leftURL: URL { URL(fileURLWithPath: left) }
    var rightURL: URL { URL(fileURLWithPath: right) }
    var title: String { "\(leftURL.lastPathComponent) ↔ \(rightURL.lastPathComponent)" }
}

@MainActor
final class RecentStore: ObservableObject {
    static let shared = RecentStore()
    private let key = "recentPairs"
    @Published private(set) var pairs: [RecentPair] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([RecentPair].self, from: data) {
            pairs = list
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(pairs) { UserDefaults.standard.set(data, forKey: key) }
    }

    func add(left: URL, right: URL) {
        let p = RecentPair(left: left.path, right: right.path, date: Date())
        pairs.removeAll { $0.id == p.id }
        pairs.insert(p, at: 0)
        pairs = Array(pairs.prefix(15))
        save()
    }

    func remove(_ id: String) {
        pairs.removeAll { $0.id == id }
        save()
    }

    func clear() {
        pairs.removeAll()
        save()
    }

    func pair(_ id: String) -> RecentPair? { pairs.first { $0.id == id } }
}

/// Cosa era aperto l'ultima volta, per riaprirlo al lancio.
enum LastSelection {
    enum Value {
        case profile(UUID)
        case pair(left: String, right: String)
    }

    private static let key = "lastSelection"

    static func save(_ v: Value) {
        switch v {
        case .profile(let id): UserDefaults.standard.set("profile:" + id.uuidString, forKey: key)
        case .pair(let l, let r): UserDefaults.standard.set("pair:" + l + "\u{1F}" + r, forKey: key)
        }
    }

    static func load() -> Value? {
        guard let s = UserDefaults.standard.string(forKey: key) else { return nil }
        if s.hasPrefix("profile:"), let id = UUID(uuidString: String(s.dropFirst(8))) { return .profile(id) }
        if s.hasPrefix("pair:") {
            let parts = s.dropFirst(5).split(separator: "\u{1F}", omittingEmptySubsequences: false)
            if parts.count == 2 { return .pair(left: String(parts[0]), right: String(parts[1])) }
        }
        return nil
    }
}
