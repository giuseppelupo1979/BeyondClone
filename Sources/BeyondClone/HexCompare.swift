import SwiftUI
import AppKit

@MainActor
final class HexCompareModel: ObservableObject {
    @Published var leftURL: URL?
    @Published var rightURL: URL?
    @Published private(set) var version = 0
    @Published private(set) var diffRows: [Int] = []
    @Published private(set) var diffBytes = 0
    @Published private(set) var busy = false
    @Published var onlyDiffs = false { didSet { selection = IndexSet(); version += 1 } }
    @Published var selection = IndexSet()
    @Published var scroll: ScrollRequest?

    private var leftData = Data()
    private var rightData = Data()
    private var generation = 0
    private var scrollToken = 0

    init(left: URL?, right: URL?) {
        leftURL = left
        rightURL = right
        reload()
    }

    var title: String { "\(leftURL?.lastPathComponent ?? "—") ↔ \(rightURL?.lastPathComponent ?? "—")" }
    var leftSize: Int { leftData.count }
    var rightSize: Int { rightData.count }
    var totalRows: Int { (max(leftData.count, rightData.count) + 15) / 16 }
    var rowCount: Int { onlyDiffs ? diffRows.count : totalRows }

    func set(_ url: URL, side: Side) {
        if side == .left { leftURL = url } else { rightURL = url }
        reload()
    }

    func reload() {
        generation += 1
        let gen = generation
        let l = leftURL, r = rightURL
        busy = true
        Task.detached(priority: .userInitiated) {
            let ld = l.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) } ?? Data()
            let rd = r.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) } ?? Data()
            let (rows, bytes) = Self.compare(ld, rd)
            await MainActor.run {
                guard gen == self.generation else { return }
                self.leftData = ld
                self.rightData = rd
                self.diffRows = rows
                self.diffBytes = bytes
                self.busy = false
                self.selection = IndexSet()
                self.version += 1
            }
        }
    }

    nonisolated private static func compare(_ a: Data, _ b: Data) -> (rows: [Int], bytes: Int) {
        var rows: [Int] = []
        var bytes = 0
        let common = min(a.count, b.count)
        a.withUnsafeBytes { (pa: UnsafeRawBufferPointer) in
            b.withUnsafeBytes { (pb: UnsafeRawBufferPointer) in
                var last = -1
                for i in 0..<common where pa[i] != pb[i] {
                    bytes += 1
                    let row = i >> 4
                    if row != last {
                        rows.append(row)
                        last = row
                    }
                }
            }
        }
        let longer = max(a.count, b.count)
        if longer > common {
            bytes += longer - common
            var row = common >> 4
            if rows.last == row { row += 1 }
            let end = (longer + 15) >> 4
            if row < end { rows.append(contentsOf: row..<end) }
        }
        return (rows, bytes)
    }

    private func dataRow(_ vis: Int) -> Int { onlyDiffs ? diffRows[vis] : vis }

    func jump(forward: Bool) {
        guard !diffRows.isEmpty else { return }
        let current = selection.first.map(dataRow) ?? (forward ? -1 : Int.max)
        let target: Int?
        if forward {
            target = diffRows.first(where: { $0 > current })
        } else {
            target = diffRows.last(where: { $0 < current })
        }
        guard let t = target else { return }
        let vis = onlyDiffs ? (diffRows.firstIndex(of: t) ?? 0) : t
        selection = IndexSet(integer: vis)
        scrollToken += 1
        scroll = ScrollRequest(row: vis, token: scrollToken)
    }

    private static let hexDigits = Array("0123456789ABCDEF")
    private static let normal: [NSAttributedString.Key: Any] = [.font: Theme.mono, .foregroundColor: NSColor.labelColor]
    private static let diff: [NSAttributedString.Key: Any] = [
        .font: Theme.mono, .foregroundColor: NSColor.systemRed, .backgroundColor: NSColor.systemRed.withAlphaComponent(0.18),
    ]

    func cell(_ vis: Int, _ col: Int) -> GridCell {
        guard vis < rowCount else { return GridCell() }
        let row = dataRow(vis)
        let offset = row * 16
        if col == 0 {
            return GridCell(text: NSAttributedString(string: String(format: "%08X", offset), attributes: [
                .font: Theme.mono, .foregroundColor: NSColor.secondaryLabelColor,
            ]), background: NSColor.windowBackgroundColor.withAlphaComponent(0.6))
        }
        let mine = col <= 2 ? leftData : rightData
        let other = col <= 2 ? rightData : leftData
        let hex = col == 1 || col == 3
        let out = NSMutableAttributedString()
        for i in 0..<16 {
            let p = offset + i
            guard p < mine.count else { break }
            let byte = mine[p]
            let differs = p >= other.count || other[p] != byte
            let s: String
            if hex {
                s = String([Self.hexDigits[Int(byte >> 4)], Self.hexDigits[Int(byte & 15)]])
            } else {
                s = (byte >= 32 && byte < 127) ? String(UnicodeScalar(byte)) : "·"
            }
            out.append(NSAttributedString(string: s, attributes: differs ? Self.diff : Self.normal))
            if hex { out.append(NSAttributedString(string: i == 7 ? "  " : " ", attributes: Self.normal)) }
        }
        return GridCell(text: out, background: nil)
    }
}

struct HexCompareView: View {
    @StateObject private var model: HexCompareModel

    init(left: URL?, right: URL?) {
        _model = StateObject(wrappedValue: HexCompareModel(left: left, right: right))
    }

    private static let columns = [
        GridColumn(title: "Offset", width: 80),
        GridColumn(title: "Sinistra", width: 370, flexible: true),
        GridColumn(title: "ASCII", width: 136),
        GridColumn(title: "Destra", width: 370, flexible: true),
        GridColumn(title: "ASCII", width: 136),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PathField(url: model.leftURL) { model.set($0, side: .left) }
                Divider()
                PathField(url: model.rightURL) { model.set($0, side: .right) }
            }
            .frame(height: 30)
            Divider()
            GridTable(
                columns: Self.columns,
                rowCount: model.rowCount,
                version: model.version,
                cell: { [model] r, c in model.cell(r, c) },
                selection: $model.selection,
                scrollRequest: model.scroll,
                showHeader: true
            )
            Divider()
            HStack(spacing: 14) {
                if model.busy {
                    ProgressView().controlSize(.small)
                    Text("Confronto in corso…")
                } else if model.diffBytes == 0 {
                    Label("I due file sono identici", systemImage: "checkmark.circle").foregroundStyle(.green)
                } else {
                    Text("\(model.diffBytes) byte diversi in \(model.diffRows.count) righe").foregroundStyle(.red)
                }
                Spacer()
                Text("Sinistra: \(Fmt.size(Int64(model.leftSize)))")
                Text("Destra: \(Fmt.size(Int64(model.rightSize)))")
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .frame(height: 24)
        }
        .navigationTitle(model.title)
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $model.onlyDiffs) { Label("Solo differenze", systemImage: "line.3.horizontal.decrease.circle") }
                    .help("Mostra solo le righe con byte diversi")
                Button { model.jump(forward: false) } label: { Label("Precedente", systemImage: "chevron.up") }
                    .keyboardShortcut(.upArrow, modifiers: .option)
                    .help("Differenza precedente (⌥↑)")
                Button { model.jump(forward: true) } label: { Label("Successiva", systemImage: "chevron.down") }
                    .keyboardShortcut(.downArrow, modifiers: .option)
                    .help("Differenza successiva (⌥↓)")
                Button { model.reload() } label: { Label("Ricarica", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Ricarica dal disco (⌘R)")
            }
        }
    }
}
