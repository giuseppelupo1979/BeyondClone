import SwiftUI
import AppKit

enum SidebarItem: Hashable {
    case profile(UUID)
    case adhoc(UUID)
    case recent(String)

    /// Sessione aperta corrispondente (le voci "recenti" diventano sessioni quando le scegli).
    var sessionID: UUID? {
        switch self {
        case .profile(let i), .adhoc(let i): return i
        case .recent: return nil
        }
    }
}

struct MainWindow: View {
    @ObservedObject private var store = ProfileStore.shared
    @ObservedObject private var registry = SessionRegistry.shared
    @Local private var selection: SidebarItem?
    @Local private var editing: SyncProfile?
    @Local private var showConnect = false
    @Local private var showSyncAll = false
    @Local private var showInspector = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection, editing: $editing, showConnect: $showConnect, showSyncAll: $showSyncAll)
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 380)
        } detail: {
            if let id = selection?.sessionID, let s = registry.existing(id) {
                WorkspaceView(session: s, showInspector: $showInspector, saveAsProfile: { saveAsProfile(s) })
                    .id(s.id)
            } else {
                WelcomeView(newCompare: newCompare, newProfile: { editing = SyncProfile() }, connect: { showConnect = true },
                            openRecent: { selection = .recent($0.id) })
            }
        }
        .onChange(of: selection) { _, item in
            switch item {
            case .profile(let id):
                registry.open(profile: id)
                LastSelection.save(.profile(id))
            case .recent(let key):
                guard let pair = RecentStore.shared.pair(key) else { return }
                selection = .adhoc(openPair(pair.leftURL, pair.rightURL).id)
            case .adhoc(let id):
                if let s = registry.existing(id), let l = s.leftURL, let r = s.rightURL {
                    LastSelection.save(.pair(left: l.path, right: r.path))
                }
            case .none:
                break
            }
        }
        .onAppear(perform: handleLaunch)
        .sheet(item: $editing) { p in
            ProfileEditor(profile: p) { saved in
                store.upsert(saved)
                if let s = registry.existing(saved.id) {
                    registry.close(s.id)
                }
                registry.open(profile: saved.id)
                selection = .profile(saved.id)
            }
        }
        .sheet(isPresented: $showConnect) { ConnectServerSheet() }
        .sheet(isPresented: $showSyncAll) { SyncAllSheet() }
        .frame(minWidth: 1100, minHeight: 640)
    }

    /// Riusa il confronto già aperto sulla stessa coppia, altrimenti ne apre uno nuovo.
    private func openPair(_ l: URL, _ r: URL) -> FolderSession {
        if let s = registry.adhoc.first(where: { $0.leftURL == l && $0.rightURL == r }) { return s }
        return registry.newAdhoc(left: l, right: r)
    }

    private func newCompare() {
        let s = registry.newAdhoc()
        selection = .adhoc(s.id)
    }

    private func saveAsProfile(_ s: FolderSession) {
        editing = s.makeProfile()
    }

    private func handleLaunch() {
        guard let spec = AppLaunch.takeInitial() else {
            guard selection == nil else { return }
            // Riapre quello che era aperto l'ultima volta.
            switch LastSelection.load() {
            case .profile(let id) where store.profile(id) != nil:
                selection = .profile(id)
            case .pair(let l, let r):
                selection = .adhoc(openPair(URL(fileURLWithPath: l), URL(fileURLWithPath: r)).id)
            default:
                if let first = store.profiles.first { selection = .profile(first.id) }
            }
            return
        }
        if spec.kind == .folder {
            let s = registry.newAdhoc(left: spec.leftURL, right: spec.rightURL)
            selection = .adhoc(s.id)
        } else {
            openWindow(value: spec)
        }
    }
}

// MARK: - Barra laterale

private struct Sidebar: View {
    @Binding var selection: SidebarItem?
    @Binding var editing: SyncProfile?
    @Binding var showConnect: Bool
    @Binding var showSyncAll: Bool
    @ObservedObject private var store = ProfileStore.shared
    @ObservedObject private var registry = SessionRegistry.shared
    @ObservedObject private var recents = RecentStore.shared
    @Local private var volumes: [VolumeInfo] = []

    var body: some View {
        List(selection: $selection) {
            Section("Sincronizzazioni") {
                ForEach(store.profiles) { p in
                    SidebarProfileRow(profile: p, session: registry.existing(p.id), version: registry.version)
                        .tag(SidebarItem.profile(p.id))
                        .help("\(p.name): \(p.mode.title.lowercased())\n\(p.left)\n→ \(p.right)\nTasto destro per modificare, duplicare o eliminare")
                        .contextMenu { profileMenu(p) }
                }
                .onMove { store.move(from: $0, to: $1) }
                if store.profiles.isEmpty {
                    Button { editing = SyncProfile() } label: {
                        Label("Crea un profilo", systemImage: "plus.circle")
                    }
                    .help("Crea un profilo: una coppia di cartelle da sincronizzare quando vuoi")
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            if !registry.adhoc.isEmpty {
                Section("Confronti") {
                    ForEach(registry.adhoc) { s in
                        SidebarAdhocRow(session: s, version: registry.version)
                            .tag(SidebarItem.adhoc(s.id))
                            .help("Confronto al volo, non salvato. Tasto destro per salvarlo come profilo o chiuderlo")
                            .contextMenu {
                                Button("Salva come profilo…") { editing = s.makeProfile() }
                                Divider()
                                Button("Chiudi confronto") {
                                    if selection?.sessionID == s.id { selection = nil }
                                    registry.close(s.id)
                                }
                            }
                    }
                }
            }
            let open = Set(registry.adhoc.compactMap { s -> String? in
                guard let l = s.leftURL, let r = s.rightURL else { return nil }
                return RecentPair(left: l.path, right: r.path, date: Date()).id
            })
            let shown = recents.pairs.filter { !open.contains($0.id) }.prefix(8)
            if !shown.isEmpty {
                Section("Recenti") {
                    ForEach(Array(shown)) { p in
                        RecentRow(pair: p)
                            .tag(SidebarItem.recent(p.id))
                            .help("\(p.left)\n↔ \(p.right)\nUltimo confronto: \(p.date.formatted(date: .abbreviated, time: .shortened))\nClic per riaprire · tasto destro per salvarlo come profilo")
                            .contextMenu {
                                Button("Salva come profilo…") {
                                    var prof = SyncProfile()
                                    prof.name = p.title
                                    prof.left = p.left
                                    prof.right = p.right
                                    editing = prof
                                }
                                Button("Mostra le cartelle nel Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([p.leftURL, p.rightURL])
                                }
                                Divider()
                                Button("Rimuovi dai recenti") { recents.remove(p.id) }
                                Button("Svuota i recenti") { recents.clear() }
                            }
                    }
                }
            }
            Section("Volumi") {
                ForEach(volumes) { v in
                    VolumeRow(volume: v)
                        .help("\(v.name)\(v.server.map { " · " + $0 } ?? "")\(v.free.map { "\n" + Fmt.size($0) + " liberi" } ?? "")\nTasto destro: confronta, mostra nel Finder, espelli")
                        .contextMenu {
                            Button("Confronta da qui…") {
                                let s = registry.newAdhoc(left: v.url, right: nil)
                                selection = .adhoc(s.id)
                            }
                            Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([v.url]) }
                            if v.isNetwork || v.isRemovable {
                                Divider()
                                Button("Espelli") {
                                    try? NSWorkspace.shared.unmountAndEjectDevice(at: v.url)
                                    Task { await reloadVolumes() }
                                }
                            }
                        }
                }
                Button { showConnect = true } label: {
                    Label("Connetti al server…", systemImage: "network")
                }
                .help("Monta una condivisione del NAS (SMB, AFP, NFS) per usarla nei confronti")
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .task { await reloadVolumes() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            Task { await reloadVolumes() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            Task { await reloadVolumes() }
        }
    }

    /// Un volume di rete che non risponde può bloccare per molti secondi: si legge fuori dal thread principale.
    private func reloadVolumes() async {
        volumes = await Task.detached(priority: .utility) { VolumeInfo.mounted() }.value
    }

    @ViewBuilder
    private func profileMenu(_ p: SyncProfile) -> some View {
        Button("Modifica…") { editing = p }
        Button("Duplica") {
            if let d = store.duplicate(p.id) { selection = .profile(d.id) }
        }
        Button("Mostra le cartelle nel Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([p.leftURL, p.rightURL].compactMap { $0 })
        }
        Divider()
        Button("Elimina profilo…", role: .destructive) {
            if confirmAlert("Eliminare il profilo «\(p.name)»?", "Vengono eliminate solo le impostazioni: i file non vengono toccati.", action: "Elimina") {
                if selection?.sessionID == p.id { selection = nil }
                registry.close(p.id)
                store.delete(p.id)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Nuovo profilo di sincronizzazione…") { editing = SyncProfile() }
                Button("Nuovo confronto al volo") {
                    let s = registry.newAdhoc()
                    selection = .adhoc(s.id)
                }
                Divider()
                Button("Connetti al server…") { showConnect = true }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Nuovo profilo o confronto")
            Spacer()
            Button {
                showSyncAll = true
            } label: {
                Label("Sincronizza tutti", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .disabled(store.profiles.isEmpty)
            .help("Analizza tutti i profili e sincronizzali insieme")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct SidebarProfileRow: View {
    let profile: SyncProfile
    let session: FolderSession?
    let version: Int

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(profile.mode.isMirror ? Color.orange.gradient : Color.accentColor.gradient)
                    .frame(width: 26, height: 26)
                Image(systemName: profile.mode.symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                subtitle
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var subtitle: some View {
        if let s = session {
            if let p = s.progress {
                Text("\(Int(p.fraction * 100))% · \(Fmt.speed(p.speed))").font(.caption).foregroundStyle(.blue)
            } else {
                switch s.state {
                case .connecting: Text("Connessione…").font(.caption).foregroundStyle(.secondary)
                case .scanning: Text("Analisi · \(s.stats.items.formatted()) elementi").font(.caption).foregroundStyle(.secondary)
                case .failed(let m): Text(m).font(.caption).foregroundStyle(.red).lineLimit(1)
                case .done:
                    if let plan = s.modePlan, !plan.isEmpty {
                        Text(plan.summary).font(.caption).foregroundStyle(.orange).lineLimit(1)
                    } else {
                        Text("Allineate").font(.caption).foregroundStyle(.green)
                    }
                case .idle: Text("Da configurare").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if let d = profile.lastRun {
            Text("Ultima: \(d.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else {
            Text(URL(fileURLWithPath: profile.right).lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let s = session {
            if let p = s.progress {
                ProgressRing(value: p.fraction).frame(width: 16, height: 16)
            } else if s.isScanning {
                ProgressView().controlSize(.mini)
            } else if s.state == .done, let plan = s.modePlan, !plan.isEmpty {
                Text("\(plan.ops.count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.2)))
            }
        }
    }
}

private struct SidebarAdhocRow: View {
    @ObservedObject var session: FolderSession
    let version: Int

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "rectangle.split.2x1")
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name).font(.system(size: 13)).lineLimit(1)
                if session.isScanning {
                    Text("Analisi…").font(.caption).foregroundStyle(.secondary)
                } else if session.state == .done {
                    let d = session.liveTally.diffs
                    Text(d == 0 ? "Identiche" : "\(d.formatted()) differenze")
                        .font(.caption)
                        .foregroundStyle(d == 0 ? .green : .orange)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct RecentRow: View {
    let pair: RecentPair

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(pair.title).font(.system(size: 13)).lineLimit(1)
                Text(pair.date.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }
}

private struct VolumeRow: View {
    let volume: VolumeInfo

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: volume.symbol)
                .foregroundStyle(volume.isNetwork ? Color.teal : .secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name).font(.system(size: 13)).lineLimit(1)
                if let free = volume.free {
                    Text("\(Fmt.size(free)) liberi" + (volume.server.map { " · " + (URL(string: $0)?.host ?? "") } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let free = volume.free, let total = volume.total, total > 0 {
                CapacityBar(used: 1 - Double(free) / Double(total)).frame(width: 34, height: 5)
            }
        }
        .padding(.vertical, 1)
    }
}

struct CapacityBar: View {
    let used: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(used > 0.9 ? Color.red : (used > 0.75 ? Color.orange : Color.accentColor))
                    .frame(width: g.size.width * max(0, min(1, used)))
            }
        }
    }
}

struct ProgressRing: View {
    let value: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
            Circle().trim(from: 0, to: value)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Benvenuto

private struct WelcomeView: View {
    let newCompare: () -> Void
    let newProfile: () -> Void
    let connect: () -> Void
    let openRecent: (RecentPair) -> Void
    @ObservedObject private var recents = RecentStore.shared

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
            VStack(spacing: 6) {
                Text("BeyondClone").font(.system(size: 30, weight: .semibold))
                Text("Confronta, sincronizza e specchia cartelle, sul Mac e sul NAS.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                WelcomeCard(symbol: "rectangle.split.2x1", title: "Confronto al volo",
                            text: "Scegli due cartelle e guarda subito le differenze.", action: newCompare)
                WelcomeCard(symbol: "arrow.triangle.2.circlepath", title: "Profilo di sincronizzazione",
                            text: "Una coppia di cartelle salvata, da rieseguire quando vuoi.", action: newProfile)
                WelcomeCard(symbol: "network", title: "Connetti il NAS",
                            text: "Monta una condivisione SMB, AFP o NFS.", action: connect)
            }
            if !recents.pairs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Confronti recenti").font(.headline)
                    ForEach(recents.pairs.prefix(6)) { p in
                        Button {
                            openRecent(p)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.title).font(.system(size: 13, weight: .medium))
                                    Text("\(p.left)  ↔  \(p.right)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Text(p.date.formatted(.relative(presentation: .named)))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Riapri il confronto tra\n\(p.left)\ne\n\(p.right)")
                    }
                }
                .frame(width: 658)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WelcomeCard: View {
    let symbol: String
    let title: String
    let text: String
    let action: () -> Void
    @Local private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text(title).font(.headline)
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(width: 210, height: 140, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(hover ? Color.accentColor : Color(nsColor: .separatorColor)))
            .shadow(color: .black.opacity(hover ? 0.12 : 0), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .help(text)
        .onHover { hover = $0 }
    }
}

// MARK: - Connessione al server

struct ConnectServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Local private var address = RecentServers.list.first ?? "smb://"
    @Local private var busy = false
    @Local private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connetti al server", systemImage: "network").font(.title3.weight(.semibold))
            Text("Indirizzo della condivisione, ad esempio smb://DS920.local/Foto. Le credenziali le chiede macOS e possono restare nel Portachiavi.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("smb://server/condivisione", text: $address)
                .textFieldStyle(.roundedBorder)
                .onSubmit(connect)
            if !RecentServers.list.isEmpty {
                Text("Recenti").font(.caption).foregroundStyle(.secondary)
                ForEach(RecentServers.list, id: \.self) { s in
                    Button(s) { address = s }
                        .help("Usa questo indirizzo")
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(message.hasPrefix("Montato") ? .green : .red)
            }
            HStack {
                Spacer()
                Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction)
                    .help("Chiudi questa finestra (Esc)")
                Button {
                    connect()
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("Connetti") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || URL(string: address)?.host == nil)
                .help("Monta la condivisione; se servono, macOS chiede le credenziali (Invio)")
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func connect() {
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                let points = try await NASMount.mount(address)
                message = "Montato in " + (points.first ?? "/Volumes")
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

// MARK: - Sincronizza tutti

private struct SyncAllSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ProfileStore.shared

    enum ItemState {
        case waiting, analyzing, ready(SyncPlan), failed(String), running, done
    }

    @Local private var states: [UUID: ItemState] = [:]
    @Local private var chosen = Set<UUID>()
    @Local private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sincronizza tutti").font(.title3.weight(.semibold))
            Text("Ogni profilo viene analizzato con la sua modalità. Scegli quali eseguire: girano in parallelo.")
                .font(.callout)
                .foregroundStyle(.secondary)
            List(store.profiles) { p in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { chosen.contains(p.id) }, set: { on in
                        if on { chosen.insert(p.id) } else { chosen.remove(p.id) }
                    }))
                    .labelsHidden()
                    .disabled(!isReady(p.id) || started)
                    .help("Includi questo profilo nell'esecuzione")
                    Image(systemName: p.mode.symbol).foregroundStyle(p.mode.isMirror ? .orange : .accentColor).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.system(size: 13, weight: .medium))
                        Text(p.mode.title).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    stateView(states[p.id] ?? .waiting)
                }
                .padding(.vertical, 3)
            }
            .frame(minHeight: 240)
            HStack {
                Spacer()
                Button(started ? "Chiudi" : "Annulla") { dismiss() }.keyboardShortcut(.cancelAction)
                    .help(started ? "Chiudi: le sincronizzazioni avviate continuano" : "Chiudi senza eseguire nulla (Esc)")
                Button("Esegui \(chosen.count) sincronizzazioni") { runChosen() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || started)
                    .help("Esegue in parallelo i profili selezionati, dopo una conferma")
            }
        }
        .padding(20)
        .frame(width: 640, height: 460)
        .task { await analyzeAll() }
    }

    private func isReady(_ id: UUID) -> Bool {
        if case .ready(let p) = states[id], !p.isEmpty { return true }
        return false
    }

    @ViewBuilder
    private func stateView(_ s: ItemState) -> some View {
        switch s {
        case .waiting: Text("In attesa").font(.caption).foregroundStyle(.secondary)
        case .analyzing:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Analisi…").font(.caption)
            }
        case .ready(let plan):
            Text(plan.summary).font(.caption).foregroundStyle(plan.isEmpty ? .green : .orange).lineLimit(2)
                .frame(maxWidth: 260, alignment: .trailing)
        case .failed(let m): Text(m).font(.caption).foregroundStyle(.red).lineLimit(2).frame(maxWidth: 260, alignment: .trailing)
        case .running: Label("Avviata", systemImage: "play.fill").font(.caption).foregroundStyle(.blue)
        case .done: Label("Fatto", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
        }
    }

    private func analyzeAll() async {
        await withTaskGroup(of: Void.self) { group in
            for p in store.profiles where p.isComplete {
                states[p.id] = .analyzing
                group.addTask { @MainActor in
                    guard let s = SessionRegistry.shared.open(profile: p.id) else { return }
                    switch await s.analyzeForBatch() {
                    case .success(let plan):
                        states[p.id] = .ready(plan)
                        if !plan.isEmpty { chosen.insert(p.id) }
                    case .failure(let e):
                        states[p.id] = .failed(e.localizedDescription)
                    }
                }
            }
        }
    }

    private func runChosen() {
        let lines = store.profiles.filter { chosen.contains($0.id) }.compactMap { p -> String? in
            guard case .ready(let plan) = states[p.id] else { return nil }
            return "• \(p.name) — \(p.mode.title): \(plan.summary)"
        }
        guard confirmAlert("Eseguire \(lines.count) sincronizzazioni in parallelo?", lines.joined(separator: "\n"), action: "Esegui") else { return }
        started = true
        for id in chosen {
            guard case .ready(let plan) = states[id], let s = SessionRegistry.shared.existing(id) else { continue }
            s.run(plan)
            states[id] = .running
        }
    }
}
