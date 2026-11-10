import SwiftUI
import AppKit

private struct EditTarget: Identifiable {
    let id = UUID()
    let row: Int
    let hadLeft: Bool
    let hadRight: Bool
    var left: String
    var right: String
}

struct TextCompareView: View {
    @StateObject private var model: TextCompareModel
    @Local private var editing: EditTarget?

    init(left: URL?, right: URL?) {
        _model = StateObject(wrappedValue: TextCompareModel(left: left, right: right))
    }

    private static let columns = [
        GridColumn(width: 52, alignRight: true),
        GridColumn(width: 400, flexible: true),
        GridColumn(width: 22),
        GridColumn(width: 52, alignRight: true),
        GridColumn(width: 400, flexible: true),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sideHeader(.left)
                Divider()
                sideHeader(.right)
            }
            .frame(height: 30)
            Divider()
            HStack(spacing: 0) {
                OverviewStrip(model: model)
                    .frame(width: 16)
                Divider()
                GridTable(
                    columns: Self.columns,
                    rowCount: model.visible.count,
                    version: model.version,
                    cell: { [model] r, c in model.cell(r, c) },
                    selection: $model.selection,
                    scrollRequest: model.scroll,
                    onDoubleClick: { beginEdit(visibleRow: $0) }
                )
            }
            Divider()
            DetailPane(model: model)
            Divider()
            statusBar
        }
        .navigationTitle(model.title)
        .toolbar { toolbar }
        .sheet(item: $editing) { target in
            EditSheet(target: target) { l, r in
                model.edit(row: target.row, left: l, right: r)
            }
        }
    }

    private func sideHeader(_ side: Side) -> some View {
        let info = side == .left ? model.left : model.right
        return HStack(spacing: 0) {
            PathField(url: info.url, dirty: info.dirty) { model.load($0, side: side) }
            Button {
                model.paste(side: side)
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
            .help("Incolla il testo degli appunti a \(side.label)")
            .padding(.trailing, 8)
            .frame(height: 30)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private func beginEdit(visibleRow: Int) {
        guard visibleRow < model.visible.count else { return }
        let index = model.visible[visibleRow]
        let row = model.rows[index]
        editing = EditTarget(row: index, hadLeft: row.left != nil, hadRight: row.right != nil,
                             left: row.left ?? "", right: row.right ?? "")
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            if model.busy {
                ProgressView().controlSize(.small)
                Text("Confronto in corso…")
            } else if model.stats.blocks == 0 {
                Label("I due testi sono identici", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                Text("\(model.stats.blocks) blocchi di differenze")
                Text("≠ \(model.stats.changed) modificate").foregroundStyle(.orange)
                Text("− \(model.stats.leftOnly) solo a sinistra").foregroundStyle(.red)
                Text("+ \(model.stats.rightOnly) solo a destra").foregroundStyle(.green)
            }
            Spacer()
            if let e = model.left.error ?? model.right.error {
                Text(e).foregroundStyle(.red)
            }
            Text("\(model.left.encodingName) · \(model.left.lineEnding == "\r\n" ? "CRLF" : "LF")")
            Text("|").foregroundStyle(.tertiary)
            Text("\(model.right.encodingName) · \(model.right.lineEnding == "\r\n" ? "CRLF" : "LF")")
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Mostra", selection: $model.filter) {
                ForEach(RowFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Righe da mostrare")
        }
        ToolbarItemGroup {
            Button { model.prevDiff() } label: { Label("Precedente", systemImage: "chevron.up") }
                .keyboardShortcut(.upArrow, modifiers: .option)
                .help("Differenza precedente (⌥↑)")
            Button { model.nextDiff() } label: { Label("Successiva", systemImage: "chevron.down") }
                .keyboardShortcut(.downArrow, modifiers: .option)
                .help("Differenza successiva (⌥↓)")
        }
        ToolbarItemGroup {
            Button { model.copySelection(to: .left) } label: { Label("Copia a sinistra", systemImage: "arrow.left.to.line") }
                .keyboardShortcut(.leftArrow, modifiers: .option)
                .disabled(model.selection.isEmpty || model.busy)
                .help("Copia le righe selezionate a sinistra (⌥←)")
            Button { model.copySelection(to: .right) } label: { Label("Copia a destra", systemImage: "arrow.right.to.line") }
                .keyboardShortcut(.rightArrow, modifiers: .option)
                .disabled(model.selection.isEmpty || model.busy)
                .help("Copia le righe selezionate a destra (⌥→)")
        }
        ToolbarItemGroup {
            Button { model.undo() } label: { Label("Annulla", systemImage: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo || model.busy)
                .help("Annulla l'ultima modifica (⌘Z)")
            Button { model.swapSides() } label: { Label("Scambia", systemImage: "arrow.left.arrow.right") }
                .help("Scambia i due lati")
            Button { model.reload() } label: { Label("Ricarica", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: .command)
                .help("Ricarica dal disco (⌘R)")
            Button { model.saveAll() } label: { Label("Salva", systemImage: "square.and.arrow.down") }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!(model.left.dirty || model.right.dirty))
                .help("Salva i lati modificati (⌘S)")
            Menu {
                Toggle("Ignora spazi e tabulazioni", isOn: $model.options.ignoreWhitespace)
                Toggle("Ignora maiuscole/minuscole", isOn: $model.options.ignoreCase)
                Divider()
                Button("Elimina le righe selezionate a sinistra") { model.deleteSelection(on: .left) }
                    .disabled(model.selection.isEmpty)
                Button("Elimina le righe selezionate a destra") { model.deleteSelection(on: .right) }
                    .disabled(model.selection.isEmpty)
                Divider()
                Button("Copia tutto a destra") { model.copyAll(to: .right) }
                Button("Copia tutto a sinistra") { model.copyAll(to: .left) }
                Divider()
                Button("Salva sinistra") { model.save(.left) }
                Button("Salva destra") { model.save(.right) }
            } label: {
                Label("Altro", systemImage: "ellipsis.circle")
            }
            .help("Opzioni di confronto, eliminazione righe, copia e salvataggio")
        }
    }
}

/// Striscia verticale con la mappa delle differenze. Clic per saltare.
private struct OverviewStrip: View {
    @ObservedObject var model: TextCompareModel

    var body: some View {
        Canvas { ctx, size in
            let total = CGFloat(max(model.rows.count, 1))
            for block in model.blocks {
                let y = CGFloat(block.lowerBound) / total * size.height
                let h = max(2, CGFloat(block.count) / total * size.height)
                let color: Color
                switch model.rows[block.lowerBound].kind {
                case .leftOnly: color = .red
                case .rightOnly: color = .green
                default: color = .orange
                }
                ctx.fill(Path(CGRect(x: 3, y: y, width: size.width - 6, height: h)), with: .color(color))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        let row = Int(location.y / max(geo.size.height, 1) * CGFloat(model.rows.count))
                        if let block = model.blocks.first(where: { $0.upperBound > row }), block.lowerBound <= row + max(1, model.rows.count / 100) {
                            model.select(block: block)
                        } else {
                            model.scrollTo(row: row)
                        }
                    }
            }
        )
        .help("Mappa delle differenze: clic per saltare")
    }
}

/// Le due righe selezionate per intero, una sopra l'altra, con le differenze evidenziate.
private struct DetailPane: View {
    @ObservedObject var model: TextCompareModel

    private func attributed(_ segments: InlineSegments, plain: String?, highlight: Bool) -> AttributedString {
        var out = AttributedString()
        if highlight {
            for s in segments {
                var a = AttributedString(s.text.replacingOccurrences(of: "\t", with: "    "))
                if s.changed { a.backgroundColor = Color.orange.opacity(0.45) }
                out.append(a)
            }
        } else {
            out = AttributedString((plain ?? "").replacingOccurrences(of: "\t", with: "    "))
        }
        return out
    }

    var body: some View {
        let rows = model.selectedRows
        VStack(alignment: .leading, spacing: 0) {
            if rows.count == 1, rows[0] < model.rows.count {
                let row = model.rows[rows[0]]
                let seg = row.kind == .changed ? model.inlineSegments(rows[0]) : (left: [], right: [])
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 2) {
                        line("◀", row.left == nil ? nil : attributed(seg.left, plain: row.left, highlight: row.kind == .changed))
                        line("▶", row.right == nil ? nil : attributed(seg.right, plain: row.right, highlight: row.kind == .changed))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                }
            } else {
                Text(rows.isEmpty
                     ? "Seleziona una riga per vederla per intero. Doppio clic per modificarla."
                     : "\(rows.count) righe selezionate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 52)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func line(_ marker: String, _ text: AttributedString?) -> some View {
        HStack(spacing: 6) {
            Text(marker).font(.caption2).foregroundStyle(.secondary)
            if let text {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Text("(riga assente)").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct EditSheet: View {
    @Local var target: EditTarget
    let apply: (String?, String?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Modifica riga").font(.headline)
            Text("Sinistra" + (target.hadLeft ? "" : " (assente: scrivi per inserirla)"))
                .font(.caption).foregroundStyle(.secondary)
            TextField("", text: $target.left)
                .font(.system(size: 12, design: .monospaced))
            Text("Destra" + (target.hadRight ? "" : " (assente: scrivi per inserirla)"))
                .font(.caption).foregroundStyle(.secondary)
            TextField("", text: $target.right)
                .font(.system(size: 12, design: .monospaced))
            HStack {
                Spacer()
                Button("Annulla") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Chiudi senza modificare (Esc)")
                Button("Applica") {
                    let l: String? = (!target.hadLeft && target.left.isEmpty) ? nil : target.left
                    let r: String? = (!target.hadRight && target.right.isEmpty) ? nil : target.right
                    apply(l, r)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .help("Applica la modifica alla riga (Invio)")
            }
        }
        .padding(18)
        .frame(width: 720)
    }
}
