import SwiftUI
import AppKit

// MARK: - Anteprima delle operazioni

struct PlanPreviewSheet: View {
    let request: PlanRequest
    let leftName: String
    let rightName: String
    let run: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Local private var show: Kind = .all

    enum Kind: String, CaseIterable, Identifiable {
        case all = "Tutte", toRight = "→ Destra", toLeft = "← Sinistra", deletes = "Eliminazioni"
        var id: String { rawValue }
    }

    private var plan: SyncPlan { request.plan }

    private var rows: [PlannedOp] {
        switch show {
        case .all: return plan.ops
        case .toRight: return plan.ops.filter { $0.dest == .right && $0.kind != .delete }
        case .toLeft: return plan.ops.filter { $0.dest == .left && $0.kind != .delete }
        case .deletes: return plan.ops.filter { $0.kind == .delete }
        }
    }

    private func needed(_ side: Side) -> Int64 {
        let add = plan.bytes(to: side)
        let freed = plan.ops.filter { $0.dest == side && $0.kind == .delete && request.deleteMode == .permanent }.reduce(0) { $0 + $1.size }
        return add - freed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.title).font(.title2.weight(.semibold))
                    if let m = request.mode {
                        Text(m.detail).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            HStack(spacing: 10) {
                stat("arrow.right", "\(leftName) → \(rightName)", count: plan.copies(to: .right).count, bytes: plan.bytes(to: .right), color: .accentColor)
                stat("arrow.left", "\(rightName) → \(leftName)", count: plan.copies(to: .left).count, bytes: plan.bytes(to: .left), color: .accentColor)
                stat("trash", "Eliminazioni", count: plan.deleteCount, bytes: nil, color: plan.deleteCount > 0 ? .red : .secondary)
                stat("folder.badge.plus", "Nuove cartelle", count: plan.mkdirCount, bytes: nil, color: .secondary)
            }
            warnings
            Picker("", selection: $show) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            Table(rows) {
                TableColumn("") { op in
                    Image(systemName: icon(op))
                        .foregroundStyle(op.kind == .delete ? .red : (op.replaces ? .orange : .accentColor))
                }
                .width(22)
                TableColumn("Azione") { op in
                    Text(op.actionTitle).foregroundStyle(op.kind == .delete ? .red : (op.replaces ? .orange : .primary))
                }
                .width(110)
                TableColumn("Verso") { op in
                    Text(op.dest == .right ? "→ \(rightName)" : "← \(leftName)").lineLimit(1)
                }
                .width(min: 90, ideal: 130)
                TableColumn("Percorso") { op in
                    Text(op.rel).lineLimit(1).truncationMode(.middle).help(op.target.path)
                }
                TableColumn("Dimensione") { op in
                    Text(op.kind == .mkdir ? "" : Fmt.size(op.size)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(90)
            }
            if !plan.conflicts.isEmpty {
                DisclosureGroup("\(plan.conflicts.count) conflitti saltati: diversi ma con la stessa data, o file contro cartella") {
                    ScrollView {
                        Text(plan.conflicts.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 90)
                }
                .font(.caption)
            }
            HStack {
                Label(request.deleteMode.title, systemImage: request.deleteMode == .permanent ? "exclamationmark.triangle.fill" : "archivebox")
                    .font(.caption)
                    .foregroundStyle(request.deleteMode == .permanent ? .red : .secondary)
                    .help(request.deleteMode.detail)
                Spacer()
                Button("Annulla") { dismiss() }.keyboardShortcut(.cancelAction)
                    .help("Chiudi senza modificare nulla (Esc)")
                Button {
                    run()
                    dismiss()
                } label: {
                    Text("Esegui \(plan.ops.count.formatted()) operazioni").frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(plan.deleteCount > 0 ? .orange : .accentColor)
                .keyboardShortcut(.defaultAction)
                .disabled(plan.isEmpty)
                .help("Esegue tutte le operazioni elencate (Invio)")
            }
        }
        .padding(20)
        .frame(width: 900, height: 620)
    }

    @ViewBuilder
    private var warnings: some View {
        let issues: [String] = [Side.left, Side.right].compactMap { side in
            guard let free = side == .left ? request.freeLeft : request.freeRight else { return nil }
            let need = needed(side)
            guard need > 0, need > free else { return nil }
            return "Spazio insufficiente a \(side == .left ? leftName : rightName): servono \(Fmt.size(need)), liberi \(Fmt.size(free))."
        }
        if !issues.isEmpty || (plan.deleteCount > 0 && request.deleteMode == .permanent) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(issues, id: \.self) { Label($0, systemImage: "externaldrive.badge.exclamationmark") }
                if plan.deleteCount > 0 && request.deleteMode == .permanent {
                    Label("Le \(plan.deleteCount) eliminazioni sono definitive: niente archivio né Cestino.", systemImage: "exclamationmark.triangle.fill")
                }
            }
            .font(.callout)
            .foregroundStyle(.red)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
        }
    }

    private func icon(_ op: PlannedOp) -> String {
        switch op.kind {
        case .copy: return op.replaces ? "arrow.triangle.2.circlepath" : (op.dest == .right ? "arrow.right" : "arrow.left")
        case .mkdir: return "folder.badge.plus"
        case .delete: return "trash"
        }
    }

    private func stat(_ symbol: String, _ title: String, count: Int, bytes: Int64?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(count.formatted()).font(.system(size: 22, weight: .semibold).monospacedDigit()).foregroundStyle(count > 0 ? color : .secondary)
            Text(bytes.map(Fmt.size) ?? " ").font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

// MARK: - Editor del profilo

struct ProfileEditor: View {
    @Local var profile: SyncProfile
    let save: (SyncProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @Local private var mounting: Side?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ProfileStore.shared.profile(profile.id) == nil ? "Nuovo profilo di sincronizzazione" : "Modifica profilo")
                .font(.title3.weight(.semibold))
            Form {
                TextField("Nome", text: $profile.name)
                Section("Sinistra") { sideFields(.left) }
                Section("Destra") { sideFields(.right) }
                Section("Sincronizzazione") {
                    Picker("Modalità", selection: $profile.mode) {
                        ForEach(SyncMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    .help("In che direzione copiare e se eliminare gli elementi in più")
                    Text(profile.mode.detail).font(.caption).foregroundStyle(.secondary)
                    Picker("Eliminati e sovrascritti", selection: $profile.deleteMode) {
                        ForEach(DeleteMode.allCases) { Text($0.title).tag($0) }
                    }
                    .help("Dove finiscono i file eliminati o sostituiti dalla sincronizzazione")
                    Text(profile.deleteMode.detail).font(.caption).foregroundStyle(.secondary)
                }
                Section("Confronto") {
                    Picker("Criterio", selection: $profile.options.method) {
                        ForEach(CompareMethod.allCases) { Text($0.title).tag($0) }
                    }
                    .help("Come decidere se due file sono uguali")
                    Toggle("Ignora differenze di un'ora esatta", isOn: $profile.options.ignoreHourShift)
                        .help("Considera uguali due file che differiscono di un'ora esatta (ora legale, fuso del NAS)")
                    Toggle("Abbina i nomi ignorando maiuscole e minuscole", isOn: $profile.options.caseInsensitive)
                        .help("Utile se il NAS distingue maiuscole e minuscole e il Mac no: «Foto» e «foto» sono lo stesso elemento")
                    Toggle("Includi i file nascosti", isOn: $profile.options.includeHidden)
                        .help("Confronta anche i file il cui nome inizia con un punto")
                    TextField("Escludi", text: $profile.options.excludes, axis: .vertical).lineLimit(1...4)
                        .help("Nomi o modelli da ignorare, separati da virgola (es. *.tmp, node_modules)")
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Annulla") { dismiss() }.keyboardShortcut(.cancelAction)
                    .help("Chiudi senza salvare (Esc)")
                Button("Salva") {
                    save(profile)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!profile.isComplete || profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Salva il profilo e aprilo (Invio)")
            }
        }
        .padding(18)
        .frame(width: 640, height: 720)
    }

    @ViewBuilder
    private func sideFields(_ side: Side) -> some View {
        let path = side == .left ? $profile.left : $profile.right
        let server = side == .left ? $profile.leftServer : $profile.rightServer
        HStack {
            TextField("Cartella", text: path)
                .help("Percorso della cartella")
            Button("Scegli…") {
                if let u = pickURL(directories: true) {
                    path.wrappedValue = u.path
                    Task {
                        if let s = await Task.detached(priority: .utility, operation: { NASMount.serverURL(for: u) }).value {
                            server.wrappedValue = s
                        }
                    }
                    autoName()
                }
            }
            .help("Scegli la cartella con il Finder")
        }
        HStack {
            TextField("Server da montare (facoltativo)", text: server, prompt: Text("smb://DS920.local/condivisione"))
                .help("Se la cartella è su una condivisione non montata, l'app la monta da sola usando questo indirizzo")
            if mounting == side {
                ProgressView().controlSize(.small)
            } else {
                Button("Connetti…") { connect(side) }
                    .disabled(URL(string: server.wrappedValue)?.host == nil)
                    .help("Monta la condivisione e scegli la cartella al suo interno")
            }
        }
        if !path.wrappedValue.isEmpty, !Reach.isDir(path.wrappedValue) {
            Text(server.wrappedValue.isEmpty ? "Cartella non raggiungibile" : "Non montata: verrà montata in automatico")
                .font(.caption)
                .foregroundStyle(server.wrappedValue.isEmpty ? .red : .orange)
        }
    }

    private func autoName() {
        guard profile.name == "Nuovo profilo" || profile.name.isEmpty || profile.name.contains("↔") || profile.name.contains("→") else { return }
        let l = URL(fileURLWithPath: profile.left).lastPathComponent
        let r = URL(fileURLWithPath: profile.right).lastPathComponent
        profile.name = profile.left.isEmpty || profile.right.isEmpty ? (l.isEmpty ? r : l) : "\(l) → \(r)"
    }

    private func connect(_ side: Side) {
        let server = side == .left ? profile.leftServer : profile.rightServer
        mounting = side
        Task {
            defer { mounting = nil }
            do {
                let points = try await NASMount.mount(server)
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.directoryURL = URL(fileURLWithPath: points.first ?? "/Volumes")
                if panel.runModal() == .OK, let u = panel.url {
                    if side == .left { profile.left = u.path } else { profile.right = u.path }
                    autoName()
                }
            } catch {
                infoAlert("Connessione non riuscita", error.localizedDescription)
            }
        }
    }
}
