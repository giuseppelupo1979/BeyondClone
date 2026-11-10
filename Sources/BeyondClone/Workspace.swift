import SwiftUI
import AppKit

extension Notification.Name {
    static let outlineCommand = Notification.Name("BeyondClone.outlineCommand")
}

struct WorkspaceView: View {
    @ObservedObject var session: FolderSession
    @Binding var showInspector: Bool
    let saveAsProfile: () -> Void
    @Environment(\.openWindow) private var openWindow
    @Local private var showOptions = false

    var body: some View {
        VStack(spacing: 0) {
            RootsHeader(session: session)
            Divider()
            FilterStrip(session: session)
            Divider()
            ZStack {
                if session.root != nil {
                    DirOutline(session: session) { l, r in
                        openWindow(value: SessionSpec(kind: .detect(l.url, r.url), left: l.url, right: r.url))
                    }
                }
                overlay
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StatusFooter(session: session)
        }
        .navigationTitle(session.name)
        .navigationSubtitle(subtitle)
        .searchable(text: $session.search, placement: .toolbar, prompt: "Filtra per nome")
        .toolbar { toolbar }
        .inspector(isPresented: $showInspector) {
            InspectorView(session: session)
                .inspectorColumnWidth(min: 250, ideal: 290, max: 400)
        }
        .sheet(item: $session.preview) { req in
            PlanPreviewSheet(request: req, leftName: session.leftURL?.lastPathComponent ?? "Sinistra",
                             rightName: session.rightURL?.lastPathComponent ?? "Destra") {
                session.run(req.plan)
            }
        }
    }

    private var subtitle: String {
        switch session.state {
        case .done: return session.liveTally.diffs == 0 ? "Identiche" : "\(session.liveTally.diffs.formatted()) differenze"
        case .scanning: return "Analisi in corso"
        case .connecting: return "Connessione"
        case .failed: return "Errore"
        case .idle: return ""
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch session.state {
        case .idle:
            EmptyStateView(symbol: "folder.badge.questionmark", title: "Scegli le due cartelle",
                           text: "Usa le schede in alto, oppure trascinaci sopra una cartella dal Finder.")
        case .connecting:
            VStack(spacing: 10) {
                ProgressView()
                Text("Connessione alle cartelle…").foregroundStyle(.secondary)
            }
        case .failed(let m):
            VStack(spacing: 12) {
                EmptyStateView(symbol: "exclamationmark.triangle", title: "Confronto non disponibile", text: m)
                Button("Riprova") { session.rescan() }
                    .help("Riprova a raggiungere le cartelle e a confrontarle")
            }
            .padding(30)
            .background(.background)
        default:
            if let root = session.root, root.listed, session.visibleChildren(root).isEmpty {
                EmptyStateView(symbol: session.filter == .all && session.search.isEmpty ? "tray" : "line.3.horizontal.decrease.circle",
                               title: session.filter == .all && session.search.isEmpty ? "Cartelle vuote" : "Nessun elemento",
                               text: session.filter == .all && session.search.isEmpty ? "" : "Nessun elemento corrisponde al filtro «\(session.filter.title)»\(session.search.isEmpty ? "" : " e alla ricerca").")
                    .allowsHitTesting(false)
            }
        }
    }

    private func command(_ c: String) {
        NotificationCenter.default.post(name: .outlineCommand, object: session.id, userInfo: ["cmd": c])
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { command("expand") } label: { Label("Espandi tutto", systemImage: "plus.square.on.square") }
                .help("Espandi tutte le cartelle già analizzate")
            Button { command("collapse") } label: { Label("Comprimi tutto", systemImage: "minus.square") }
                .help("Comprimi tutto")
            Button { session.rescan() } label: { Label("Aggiorna", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(session.isRunning)
                .help("Rianalizza (⌘R)")
            Button { showOptions.toggle() } label: { Label("Opzioni", systemImage: "slider.horizontal.3") }
                .help("Opzioni di confronto")
                .popover(isPresented: $showOptions, arrowEdge: .bottom) {
                    OptionsPopover(session: session)
                }
            if session.profileID == nil {
                Button(action: saveAsProfile) { Label("Salva come profilo", systemImage: "star") }
                    .disabled(session.leftURL == nil || session.rightURL == nil)
                    .help("Salva questa coppia come profilo di sincronizzazione")
            }
            Button {
                session.prepareSync()
            } label: {
                Label("Sincronizza…", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(session.mode.isMirror ? .orange : .accentColor)
            .disabled(session.state != .done || session.isRunning)
            .keyboardShortcut(.return, modifiers: .command)
            .help("\(session.mode.title): mostra le operazioni e poi le esegue (⌘↩)")
            Button { showInspector.toggle() } label: { Label("Ispettore", systemImage: "sidebar.right") }
                .help("Mostra/nascondi i dettagli")
        }
    }
}

/// Filtri ben visibili: icona, nome e quanti elementi mostrano.
private struct FilterStrip: View {
    @ObservedObject var session: FolderSession

    private func count(_ f: FolderFilter) -> Int? {
        guard session.root != nil else { return nil }
        let t = session.liveTally
        switch f {
        case .all: return t.compared
        case .diffs: return t.diffs
        case .changed: return t.changed
        case .leftOnly: return t.leftOnly
        case .rightOnly: return t.rightOnly
        case .same: return t.same
        }
    }

    private func color(_ f: FolderFilter) -> Color {
        switch f {
        case .all: return .accentColor
        case .diffs, .changed: return .red
        case .leftOnly, .rightOnly: return .purple
        case .same: return .green
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("Mostra").font(.caption).foregroundStyle(.secondary)
            ForEach(FolderFilter.allCases) { f in
                let selected = session.filter == f
                Button {
                    session.filter = f
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: selected ? f.symbol + ".fill" : f.symbol)
                        Text(f.title)
                        if let c = count(f) {
                            Text(c.formatted())
                                .monospacedDigit()
                                .foregroundStyle(selected ? color(f) : .secondary)
                        }
                    }
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? color(f) : .primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(selected ? color(f).opacity(0.18) : Color.secondary.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(selected ? color(f).opacity(0.5) : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(f.help)
            }
            Spacer()
            if !session.search.isEmpty {
                Label("Ricerca: «\(session.search)»", systemImage: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    session.search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Annulla la ricerca per nome")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.medium))
            if !text.isEmpty {
                Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
        }
    }
}

// MARK: - Intestazione con le due radici

private struct RootsHeader: View {
    @ObservedObject var session: FolderSession

    var body: some View {
        HStack(spacing: 0) {
            RootCard(session: session, side: .left)
            ModeControl(session: session)
                .frame(width: 150)
            RootCard(session: session, side: .right)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct RootCard: View {
    @ObservedObject var session: FolderSession
    let side: Side
    @Local private var targeted = false
    @Local private var hover = false

    var body: some View {
        let url = session.url(side)
        let vol = session.volume(side)
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill((vol?.isNetwork ?? false ? Color.teal : Color.accentColor).opacity(0.14))
                Image(systemName: url == nil ? "folder.badge.plus" : (vol?.symbol ?? "folder"))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(vol?.isNetwork ?? false ? Color.teal : Color.accentColor)
            }
            .frame(width: 46, height: 46)
            .help("Cartella \(side.label): doppio clic sulla scheda per sceglierne un'altra, oppure trascinaci sopra una cartella dal Finder")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(url?.lastPathComponent ?? (side == .left ? "Cartella sinistra" : "Cartella destra"))
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    if let vol, vol.isNetwork {
                        Text(URL(string: vol.server ?? "")?.host ?? "rete")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.teal.opacity(0.18)))
                    }
                }
                Text(url?.deletingLastPathComponent().path ?? "Scegli una cartella o trascinala qui")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(url.map { "\($0.path)\nDoppio clic sulla scheda per cambiare cartella" } ?? "Doppio clic per scegliere la cartella \(side.label), oppure trascinala qui")
                metrics(vol)
            }
            Spacer(minLength: 4)
            Menu {
                Button("Scegli cartella…") { choose() }
                if !RecentFolders.list.isEmpty {
                    Menu("Recenti") {
                        ForEach(RecentFolders.list, id: \.self) { u in
                            Button(u.path) { session.set(u, side: side) }
                        }
                    }
                }
                if let url {
                    Divider()
                    Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Copia percorso") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.path, forType: .string)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 15))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(session.isRunning)
            .help("Scegli la cartella \(side.label), recenti, mostra nel Finder")
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(hover ? 1 : 0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(targeted ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: targeted ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !session.isRunning { choose() } }
        .onHover { hover = $0 }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            loadURLs(providers) { urls in
                if let u = urls.first, Reach.isDir(u.path), !session.isRunning { session.set(u, side: side) }
            }
            return true
        }
    }

    @ViewBuilder
    private func metrics(_ vol: VolumeInfo?) -> some View {
        let t = session.liveTally
        let files = side == .left ? t.leftFiles : t.rightFiles
        let bytes = side == .left ? t.leftBytes : t.rightBytes
        HStack(spacing: 8) {
            if session.root != nil {
                Text("\(files.formatted()) file · \(Fmt.size(bytes))\(session.state == .done ? "" : "…")")
            }
            if let free = vol?.free {
                Text("·")
                Text("\(Fmt.size(free)) liberi su \(vol?.name ?? "")")
                if let total = vol?.total, total > 0 {
                    CapacityBar(used: 1 - Double(free) / Double(total)).frame(width: 40, height: 4)
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func choose() {
        if let u = pickURL(directories: true) { session.set(u, side: side) }
    }
}

private struct ModeControl: View {
    @ObservedObject var session: FolderSession

    var body: some View {
        VStack(spacing: 4) {
            Menu {
                ForEach(SyncMode.allCases) { m in
                    Button {
                        session.mode = m
                    } label: {
                        Label(m.title, systemImage: m.symbol)
                    }
                }
                Divider()
                Button {
                    session.swapSides()
                } label: {
                    Label("Scambia sinistra e destra", systemImage: "arrow.left.arrow.right.square")
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(session.mode.isMirror ? Color.orange.gradient : Color.accentColor.gradient)
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                    Image(systemName: session.mode.symbol)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 40, height: 40)
                .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(session.isRunning)
            .help(session.mode.detail)
            Text(session.mode.title)
                .font(.caption.weight(.semibold))
            if let plan = session.modePlan {
                Text(plan.isEmpty ? "niente da fare" : "\(plan.ops.count.formatted()) operazioni")
                    .font(.caption2)
                    .foregroundStyle(plan.isEmpty ? .green : .secondary)
            } else {
                Text(" ").font(.caption2)
            }
        }
    }
}

// MARK: - Barra di stato

private struct StatusFooter: View {
    @ObservedObject var session: FolderSession

    var body: some View {
        HStack(spacing: 10) {
            if let p = session.progress {
                runView(p)
            } else {
                switch session.state {
                case .scanning, .connecting:
                    ProgressView().controlSize(.small)
                    Text("Analisi: \(session.stats.dirs.formatted()) cartelle, \(session.stats.items.formatted()) elementi · \(Fmt.duration(session.stats.elapsed))")
                        .monospacedDigit()
                    Button("Ferma") { session.stopScan() }.controlSize(.small)
                        .help("Interrompi l'analisi delle cartelle")
                    Spacer()
                case .done:
                    Label(session.liveTally.diffs == 0 ? "Le due cartelle sono identiche" : "\(session.liveTally.diffs.formatted()) differenze su \(session.liveTally.compared.formatted()) elementi",
                          systemImage: session.liveTally.diffs == 0 ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(session.liveTally.diffs == 0 ? .green : .primary)
                    if let plan = session.modePlan {
                        Text("· \(session.mode.title): \(plan.summary.lowercased())").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !session.stats.errors.isEmpty {
                        Button {
                            infoAlert("Cartelle non leggibili", session.stats.errors.prefix(30).joined(separator: "\n"))
                        } label: {
                            Label("\(session.stats.errors.count) non leggibili", systemImage: "exclamationmark.triangle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.orange)
                        .help("Elenco delle cartelle che non è stato possibile leggere (permessi o rete)")
                    }
                    Text("\(session.stats.items.formatted()) elementi in \(Fmt.duration(session.stats.elapsed))")
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                default:
                    Spacer()
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.bar)
    }

    private var chips: some View {
        let t = session.liveTally
        return HStack(spacing: 6) {
            Chip(text: "\(t.same.formatted()) uguali", color: .secondary, active: session.filter == .same,
                 tip: "Mostra solo gli elementi uguali") { toggle(.same) }
            Chip(text: "\(t.changed.formatted()) modificati", color: .red, active: session.filter == .changed,
                 tip: "Mostra solo i file diversi: \(t.leftNewer) più recenti a sinistra, \(t.rightNewer) a destra") { toggle(.changed) }
            Chip(text: "\(t.leftOnly.formatted()) solo a sinistra", color: .purple, active: session.filter == .leftOnly,
                 tip: "Mostra solo gli elementi che esistono soltanto a sinistra") { toggle(.leftOnly) }
            Chip(text: "\(t.rightOnly.formatted()) solo a destra", color: .purple, active: session.filter == .rightOnly,
                 tip: "Mostra solo gli elementi che esistono soltanto a destra") { toggle(.rightOnly) }
        }
    }

    private func toggle(_ f: FolderFilter) {
        session.filter = session.filter == f ? .all : f
    }

    @ViewBuilder
    private func runView(_ p: SyncProgress) -> some View {
        ProgressView(value: p.fraction).frame(width: 200)
        Text("\(Int(p.fraction * 100))%").monospacedDigit().fontWeight(.semibold)
        Text("\(Fmt.size(p.doneBytes)) di \(Fmt.size(p.totalBytes)) · \(p.doneOps.formatted())/\(p.totalOps.formatted())")
            .monospacedDigit()
        Text(Fmt.speed(p.speed)).monospacedDigit().foregroundStyle(.blue)
        if let eta = p.eta { Text("mancano \(Fmt.duration(eta))").foregroundStyle(.secondary) }
        if p.errors > 0 { Text("\(p.errors) errori").foregroundStyle(.red) }
        Text(p.active.last ?? p.phase)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(.secondary)
        Spacer()
        Button("Ferma") { session.stopRun() }.controlSize(.small)
            .help("Interrompi la sincronizzazione: il file in copia viene annullato, quelli già copiati restano")
    }
}

private struct Chip: View {
    let text: String
    let color: Color
    let active: Bool
    let tip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(text).monospacedDigit()
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(active ? color.opacity(0.22) : Color.secondary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(active ? "Filtro attivo: clic per tornare a mostrare tutto" : tip)
    }
}

// MARK: - Ispettore

private struct InspectorView: View {
    @ObservedObject var session: FolderSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let sel = session.selection
                if sel.count == 1, let n = sel.first {
                    nodeDetail(n)
                } else if sel.count > 1 {
                    multiDetail(sel)
                } else {
                    overview
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Riepilogo del confronto.
    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Riepilogo").font(.headline)
            let t = session.liveTally
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text("Sinistra").font(.caption.weight(.semibold))
                    Text("Destra").font(.caption.weight(.semibold))
                }
                GridRow {
                    Text("File").foregroundStyle(.secondary)
                    Text(t.leftFiles.formatted()).monospacedDigit()
                    Text(t.rightFiles.formatted()).monospacedDigit()
                }
                GridRow {
                    Text("Dimensione").foregroundStyle(.secondary)
                    Text(Fmt.size(t.leftBytes)).monospacedDigit()
                    Text(Fmt.size(t.rightBytes)).monospacedDigit()
                }
                GridRow {
                    Text("Solo qui").foregroundStyle(.secondary)
                    Text(t.leftOnly.formatted()).foregroundStyle(.purple).monospacedDigit()
                    Text(t.rightOnly.formatted()).foregroundStyle(.purple).monospacedDigit()
                }
                GridRow {
                    Text("Più recenti").foregroundStyle(.secondary)
                    Text(t.leftNewer.formatted()).foregroundStyle(.red).monospacedDigit()
                    Text(t.rightNewer.formatted()).foregroundStyle(.red).monospacedDigit()
                }
            }
            .font(.callout)
            if t.compared > 0 {
                DiffBar(tally: t).frame(height: 8)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Label(session.mode.title, systemImage: session.mode.symbol).font(.callout.weight(.semibold))
                Text(session.mode.detail).font(.caption).foregroundStyle(.secondary)
                if let plan = session.modePlan {
                    Text(plan.summary).font(.callout)
                        .foregroundStyle(plan.isEmpty ? .green : .primary)
                }
                Text("Eliminati e sovrascritti: \(session.deleteMode.title.lowercased())")
                    .font(.caption)
                    .foregroundStyle(session.deleteMode == .permanent ? .red : .secondary)
            }
            if let run = session.lastRun {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ultima esecuzione").font(.callout.weight(.semibold))
                    Text(run.result.summary).font(.caption)
                    ForEach(run.result.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                    HStack {
                        if let log = run.result.logURL {
                            Button("Apri registro") { NSWorkspace.shared.open(log) }
                                .help("Apri il registro dettagliato dell'ultima esecuzione")
                        }
                        if let a = run.result.archiveFolders.first {
                            Button("Apri archivio") { NSWorkspace.shared.open(URL(fileURLWithPath: a)) }
                                .help("Apri la cartella con i file eliminati o sovrascritti dall'ultima esecuzione")
                        }
                    }
                    .controlSize(.small)
                    if !run.result.errors.isEmpty {
                        Text(run.result.errors.prefix(8).joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                    }
                }
            }
            Divider()
            Button("Cartella dei registri") {
                try? FileManager.default.createDirectory(at: SyncLog.folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(SyncLog.folder)
            }
            .controlSize(.small)
            .help("Apri la cartella con i registri di tutte le esecuzioni")
        }
    }

    private func nodeDetail(_ n: FolderNode) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if let info = n.left ?? n.right {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: info.url.path))
                        .resizable()
                        .frame(width: 40, height: 40)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(n.name).font(.headline).lineLimit(2)
                    StatusBadge(node: n)
                }
            }
            Text(n.relPath).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            sideBox("Sinistra", n.left, n, .left)
            sideBox("Destra", n.right, n, .right)
            if n.isDir, n.complete {
                DiffBar(tally: n.tally).frame(height: 8)
                Text("\(n.tally.diffs.formatted()) differenze su \(n.tally.compared.formatted()) elementi")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            actions([n])
        }
    }

    private func multiDetail(_ nodes: [FolderNode]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(nodes.count) elementi selezionati").font(.headline)
            let l = nodes.reduce(Int64(0)) { $0 + ($1.isDir ? $1.tally.leftBytes : ($1.left?.size ?? 0)) }
            let r = nodes.reduce(Int64(0)) { $0 + ($1.isDir ? $1.tally.rightBytes : ($1.right?.size ?? 0)) }
            Text("Sinistra: \(Fmt.size(l)) · Destra: \(Fmt.size(r))").font(.callout).foregroundStyle(.secondary)
            actions(nodes)
        }
    }

    private func sideBox(_ title: String, _ info: FileInfo?, _ n: FolderNode, _ side: Side) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let info {
                if info.isDir {
                    row("Contenuto", n.complete ? "\((side == .left ? n.tally.leftFiles : n.tally.rightFiles).formatted()) file" : "analisi…")
                    row("Dimensione", n.complete ? Fmt.size(side == .left ? n.tally.leftBytes : n.tally.rightBytes) : "…")
                } else {
                    row("Dimensione", "\(Fmt.size(info.size)) (\(info.size.formatted()) byte)")
                    row("Modificato", info.modified.map { Fmt.date.string(from: $0) } ?? "—",
                        highlight: (side == .left && n.status == .leftNewer) || (side == .right && n.status == .rightNewer))
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([info.url])
                } label: {
                    Text(info.url.path).font(.caption2.monospaced()).lineLimit(2).truncationMode(.middle).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Mostra nel Finder")
            } else {
                Text("Non presente").font(.callout).foregroundStyle(.purple)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func row(_ k: String, _ v: String, highlight: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(v).foregroundStyle(highlight ? .red : .primary).fontWeight(highlight ? .semibold : .regular)
        }
        .font(.callout)
    }

    private func actions(_ nodes: [FolderNode]) -> some View {
        let hasL = nodes.contains { $0.left != nil }, hasR = nodes.contains { $0.right != nil }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { session.prepareCopy(nodes, to: .left) } label: { Label("Copia a sinistra", systemImage: "arrow.left") }
                    .disabled(!hasR || session.isRunning)
                    .help("Copia la selezione da destra a sinistra (⌥←), dopo un'anteprima")
                Button { session.prepareCopy(nodes, to: .right) } label: { Label("Copia a destra", systemImage: "arrow.right") }
                    .disabled(!hasL || session.isRunning)
                    .help("Copia la selezione da sinistra a destra (⌥→), dopo un'anteprima")
            }
            HStack {
                Button(role: .destructive) { session.prepareDelete(nodes, on: .left) } label: { Label("Elimina sx", systemImage: "trash") }
                    .disabled(!hasL || session.isRunning)
                    .help("Elimina la selezione dal lato sinistro, dopo un'anteprima")
                Button(role: .destructive) { session.prepareDelete(nodes, on: .right) } label: { Label("Elimina dx", systemImage: "trash") }
                    .disabled(!hasR || session.isRunning)
                    .help("Elimina la selezione dal lato destro, dopo un'anteprima")
            }
            Button { session.exclude(nodes) } label: { Label("Escludi dal confronto", systemImage: "eye.slash") }
                .help("Aggiunge questi nomi alle esclusioni: non verranno più confrontati né copiati")
        }
        .controlSize(.regular)
    }
}

struct StatusBadge: View {
    let node: FolderNode

    var body: some View {
        let (text, color): (String, Color) = {
            if node.isDir && !node.complete { return ("In analisi", .secondary) }
            switch node.status {
            case .same: return ("Uguali", .green)
            case .different: return node.typeMismatch ? ("File e cartella", .orange) : (node.isDir ? "Contiene differenze" : "Diversi", .red)
            case .leftNewer: return ("Più recente a sinistra", .red)
            case .rightNewer: return ("Più recente a destra", .red)
            case .leftOnly: return ("Solo a sinistra", .purple)
            case .rightOnly: return ("Solo a destra", .purple)
            case .pending: return ("In analisi", .secondary)
            }
        }()
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

struct DiffBar: View {
    let tally: Tally

    var body: some View {
        GeometryReader { g in
            let total = max(1, Double(tally.compared))
            HStack(spacing: 1) {
                seg(Double(tally.same), total, g.size.width, .green.opacity(0.7))
                seg(Double(tally.changed), total, g.size.width, .red)
                seg(Double(tally.leftOnly + tally.rightOnly), total, g.size.width, .purple)
            }
            .clipShape(Capsule())
        }
    }

    private func seg(_ v: Double, _ total: Double, _ w: CGFloat, _ c: Color) -> some View {
        Rectangle().fill(c).frame(width: v > 0 ? max(2, w * v / total) : 0)
    }
}

// MARK: - Opzioni

private struct OptionsPopover: View {
    @ObservedObject var session: FolderSession
    @Local private var excludes = ""

    var body: some View {
        Form {
            Section("Confronto") {
                Picker("Criterio", selection: $session.options.method) {
                    ForEach(CompareMethod.allCases) { Text($0.title).tag($0) }
                }
                .help("Come decidere se due file sono uguali: dimensione e data è il più veloce")
                Stepper(value: $session.options.timeTolerance, in: 0...10, step: 1) {
                    Text("Tolleranza sulle date: \(Int(session.options.timeTolerance)) s")
                }
                .help("Differenza massima di orario per considerare uguali due date (FAT ed exFAT arrotondano a 2 s)")
                Toggle("Ignora differenze di un'ora esatta (ora legale, fuso del NAS)", isOn: $session.options.ignoreHourShift)
                    .help("Considera uguali due file che differiscono di un'ora esatta")
                Toggle("Abbina i nomi ignorando maiuscole e minuscole", isOn: $session.options.caseInsensitive)
                    .help("«Foto» e «foto» diventano lo stesso elemento: utile con NAS che distinguono le maiuscole")
                Toggle("Includi i file nascosti", isOn: $session.options.includeHidden)
                    .help("Confronta anche i file il cui nome inizia con un punto")
            }
            Section("Esclusioni") {
                TextField("Nomi o modelli, separati da virgola", text: $excludes, axis: .vertical)
                    .lineLimit(2...5)
                    .onSubmit { session.options.excludes = excludes }
                    .help("Nomi o modelli da ignorare, separati da virgola. Con «/» il modello vale sul percorso")
                HStack {
                    Button("Predefinite") { excludes = DirOptions.defaultExcludes }
                        .help("Ripristina le esclusioni predefinite (file di sistema del Mac e del Synology)")
                    Spacer()
                    Button("Applica") { session.options.excludes = excludes }
                        .disabled(excludes == session.options.excludes)
                        .help("Applica le esclusioni e rianalizza")
                }
            }
            Section("Sincronizzazione") {
                Picker("Eliminati e sovrascritti", selection: $session.deleteMode) {
                    ForEach(DeleteMode.allCases) { Text($0.title).tag($0) }
                }
                .help("Dove finiscono i file eliminati o sostituiti dalla sincronizzazione")
                Text(session.deleteMode.detail).font(.caption).foregroundStyle(.secondary)
                Stepper(value: $session.options.parallelCopies, in: 1...12) {
                    Text("Copie in parallelo: \(session.options.parallelCopies)")
                }
                .help("Quanti file copiare contemporaneamente: valori più alti aiutano con molti file piccoli sul NAS")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 520)
        .onAppear { excludes = session.options.excludes }
    }
}
