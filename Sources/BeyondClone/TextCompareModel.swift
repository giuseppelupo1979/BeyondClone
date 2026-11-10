import SwiftUI
import AppKit

enum RowFilter: String, CaseIterable, Identifiable {
    case all = "Tutte"
    case diffs = "Differenze"
    case same = "Uguali"
    var id: String { rawValue }
}

struct TextSide {
    var url: URL?
    var encoding: String.Encoding = .utf8
    var lineEnding = "\n"
    var trailingNewline = true
    var dirty = false
    var error: String?

    var encodingName: String {
        switch encoding {
        case .utf8: return "UTF-8"
        case .utf16: return "UTF-16"
        case .isoLatin1: return "Latin-1"
        default: return "\(encoding)"
        }
    }
}

struct TextStats {
    var blocks = 0, changed = 0, leftOnly = 0, rightOnly = 0
}

@MainActor
final class TextCompareModel: ObservableObject {
    @Published var left = TextSide()
    @Published var right = TextSide()
    @Published private(set) var rows: [DiffRow] = []
    @Published private(set) var visible: [Int] = []
    @Published private(set) var blocks: [Range<Int>] = []
    @Published private(set) var stats = TextStats()
    @Published private(set) var version = 0
    @Published private(set) var busy = false
    @Published private(set) var canUndo = false
    @Published var filter: RowFilter = .all { didSet { rebuildVisible() } }
    @Published var options = CompareOptions() { didSet { if options != oldValue { rediff() } } }
    @Published var selection = IndexSet()
    @Published var scroll: ScrollRequest?

    private var leftLines: [String] = []
    private var rightLines: [String] = []
    private var undoStack: [(l: [String], r: [String], ld: Bool, rd: Bool)] = []
    private var generation = 0
    private var scrollToken = 0
    private var inlineCache: [Int: (left: InlineSegments, right: InlineSegments)] = [:]

    init(left: URL?, right: URL?) {
        if let left { load(left, side: .left) }
        if let right { load(right, side: .right) }
    }

    var title: String {
        let l = left.url?.lastPathComponent ?? "—"
        let r = right.url?.lastPathComponent ?? "—"
        return "\(l) ↔ \(r)"
    }

    // MARK: - Caricamento e salvataggio

    nonisolated static func read(_ url: URL) -> (lines: [String], side: TextSide) {
        var side = TextSide(url: url)
        guard let data = try? Data(contentsOf: url) else {
            side.error = "Impossibile leggere il file"
            return ([], side)
        }
        var text: String
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) {
            text = s
            side.encoding = .utf16
        } else if let s = String(data: data, encoding: .utf8) {
            text = s
        } else {
            text = String(data: data, encoding: .isoLatin1) ?? ""
            side.encoding = .isoLatin1
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let (lines, ending, trailing) = split(text)
        side.lineEnding = ending
        side.trailingNewline = trailing
        return (lines, side)
    }

    nonisolated static func split(_ text: String) -> (lines: [String], ending: String, trailing: Bool) {
        if text.isEmpty { return ([], "\n", true) }
        let ending = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var trailing = false
        if lines.last == "" {
            lines.removeLast()
            trailing = true
        }
        return (lines, ending, trailing)
    }

    func load(_ url: URL, side: Side) {
        busy = true
        Task.detached(priority: .userInitiated) {
            let result = Self.read(url)
            await MainActor.run {
                if side == .left {
                    self.left = result.side
                    self.leftLines = result.lines
                } else {
                    self.right = result.side
                    self.rightLines = result.lines
                }
                self.undoStack.removeAll()
                self.canUndo = false
                self.rediff()
            }
        }
    }

    func reload() {
        if left.dirty || right.dirty {
            guard confirmAlert("Ricaricare dal disco?", "Le modifiche non salvate andranno perse.", action: "Ricarica") else { return }
        }
        if let u = left.url { load(u, side: .left) }
        if let u = right.url { load(u, side: .right) }
    }

    func paste(side: Side) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let (lines, ending, trailing) = Self.split(text)
        pushUndo()
        if side == .left {
            leftLines = lines
            left.lineEnding = ending
            left.trailingNewline = trailing
            left.dirty = true
        } else {
            rightLines = lines
            right.lineEnding = ending
            right.trailingNewline = trailing
            right.dirty = true
        }
        rediff()
    }

    func save(_ side: Side) {
        var info = side == .left ? left : right
        let lines = side == .left ? leftLines : rightLines
        if info.url == nil {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "senza titolo.txt"
            guard panel.runModal() == .OK, let u = panel.url else { return }
            info.url = u
        }
        guard let url = info.url else { return }
        var text = lines.joined(separator: info.lineEnding)
        if info.trailingNewline, !lines.isEmpty { text += info.lineEnding }
        do {
            guard let data = text.data(using: info.encoding) ?? text.data(using: .utf8) else { return }
            try data.write(to: url, options: .atomic)
            info.dirty = false
            if side == .left { left = info } else { right = info }
        } catch {
            infoAlert("Salvataggio non riuscito", error.localizedDescription)
        }
    }

    func saveAll() {
        if left.dirty { save(.left) }
        if right.dirty { save(.right) }
    }

    // MARK: - Diff

    private func rediff() {
        generation += 1
        let gen = generation
        let l = leftLines, r = rightLines, o = options
        busy = true
        Task.detached(priority: .userInitiated) {
            let rows = DiffEngine.rows(left: l, right: r, options: o)
            await MainActor.run {
                guard gen == self.generation else { return }
                self.apply(rows)
            }
        }
    }

    private func apply(_ newRows: [DiffRow]) {
        rows = newRows
        inlineCache.removeAll()
        var b: [Range<Int>] = []
        var s = TextStats()
        var start: Int?
        for (i, row) in newRows.enumerated() {
            switch row.kind {
            case .equal:
                if let st = start {
                    b.append(st..<i)
                    start = nil
                }
                continue
            case .changed: s.changed += 1
            case .leftOnly: s.leftOnly += 1
            case .rightOnly: s.rightOnly += 1
            }
            if start == nil { start = i }
        }
        if let st = start { b.append(st..<newRows.count) }
        s.blocks = b.count
        blocks = b
        stats = s
        busy = false
        rebuildVisible()
    }

    private func rebuildVisible() {
        switch filter {
        case .all: visible = Array(rows.indices)
        case .diffs: visible = rows.indices.filter { rows[$0].kind != .equal }
        case .same: visible = rows.indices.filter { rows[$0].kind == .equal }
        }
        selection = IndexSet()
        version += 1
    }

    // MARK: - Navigazione

    /// Indice visibile della prima riga >= row.
    private func visibleIndex(atOrAfter row: Int) -> Int? {
        var lo = 0, hi = visible.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if visible[mid] < row { lo = mid + 1 } else { hi = mid }
        }
        return lo < visible.count ? lo : nil
    }

    var selectedRows: [Int] {
        selection.compactMap { $0 < visible.count ? visible[$0] : nil }
    }

    func select(block: Range<Int>) {
        var set = IndexSet()
        guard let first = visibleIndex(atOrAfter: block.lowerBound) else { return }
        var i = first
        while i < visible.count, visible[i] < block.upperBound {
            set.insert(i)
            i += 1
        }
        guard !set.isEmpty else { return }
        selection = set
        scrollTo(visibleRow: first)
    }

    func scrollTo(visibleRow: Int) {
        scrollToken += 1
        scroll = ScrollRequest(row: visibleRow, token: scrollToken)
    }

    func scrollTo(row: Int) {
        if let v = visibleIndex(atOrAfter: row) ?? (visible.isEmpty ? nil : visible.count - 1) {
            scrollTo(visibleRow: v)
        }
    }

    func nextDiff() {
        let cur = selectedRows.last ?? -1
        if let b = blocks.first(where: { $0.lowerBound > cur }) { select(block: b) }
    }

    func prevDiff() {
        let cur = selectedRows.first ?? rows.count
        if let b = blocks.last(where: { $0.upperBound <= cur }) { select(block: b) }
    }

    // MARK: - Modifiche

    private func pushUndo() {
        undoStack.append((leftLines, rightLines, left.dirty, right.dirty))
        if undoStack.count > 100 { undoStack.removeFirst() }
        canUndo = true
    }

    func undo() {
        guard !busy, let u = undoStack.popLast() else { return }
        leftLines = u.l
        rightLines = u.r
        left.dirty = u.ld
        right.dirty = u.rd
        canUndo = !undoStack.isEmpty
        rediff()
    }

    private func commit(left newLeft: [String], right newRight: [String]) {
        pushUndo()
        if newLeft != leftLines {
            leftLines = newLeft
            left.dirty = true
        }
        if newRight != rightLines {
            rightLines = newRight
            right.dirty = true
        }
        rediff()
    }

    /// Copia le righe selezionate sul lato indicato (le righe assenti nell'origine vengono rimosse).
    func copySelection(to dest: Side) {
        guard !busy else { return }
        let sel = Set(selectedRows)
        guard !sel.isEmpty else { return }
        if dest == .right {
            let newRight = rows.indices.compactMap { sel.contains($0) ? rows[$0].left : rows[$0].right }
            commit(left: leftLines, right: newRight)
        } else {
            let newLeft = rows.indices.compactMap { sel.contains($0) ? rows[$0].right : rows[$0].left }
            commit(left: newLeft, right: rightLines)
        }
    }

    func copyAll(to dest: Side) {
        guard !busy else { return }
        if dest == .right { commit(left: leftLines, right: leftLines) } else { commit(left: rightLines, right: rightLines) }
    }

    func deleteSelection(on side: Side) {
        guard !busy else { return }
        let sel = Set(selectedRows)
        guard !sel.isEmpty else { return }
        if side == .left {
            commit(left: rows.indices.compactMap { sel.contains($0) ? nil : rows[$0].left }, right: rightLines)
        } else {
            commit(left: leftLines, right: rows.indices.compactMap { sel.contains($0) ? nil : rows[$0].right })
        }
    }

    func edit(row index: Int, left newLeft: String?, right newRight: String?) {
        guard !busy, index < rows.count else { return }
        var copy = rows
        copy[index].left = newLeft
        copy[index].right = newRight
        commit(left: copy.compactMap(\.left), right: copy.compactMap(\.right))
    }

    func swapSides() {
        guard !busy else { return }
        swap(&left, &right)
        swap(&leftLines, &rightLines)
        undoStack.removeAll()
        canUndo = false
        rediff()
    }

    // MARK: - Celle

    func inlineSegments(_ index: Int) -> (left: InlineSegments, right: InlineSegments) {
        if let c = inlineCache[index] { return c }
        let row = rows[index]
        let r = DiffEngine.inline(row.left ?? "", row.right ?? "")
        inlineCache[index] = r
        return r
    }

    private static func display(_ s: String, limit: Int = 600) -> String {
        var t = s.count > limit ? String(s.prefix(limit)) + "…" : s
        if t.contains("\t") { t = t.replacingOccurrences(of: "\t", with: "    ") }
        return t
    }

    private func textCell(_ index: Int, _ side: Side) -> GridCell {
        let row = rows[index]
        let bg = Theme.background(row.kind, side)
        guard let text = side == .left ? row.left : row.right else { return GridCell(text: nil, background: bg) }
        let base: [NSAttributedString.Key: Any] = [.font: Theme.mono, .foregroundColor: NSColor.labelColor]
        if row.kind == .changed {
            let seg = inlineSegments(index)
            let out = NSMutableAttributedString()
            var budget = 600
            for s in side == .left ? seg.left : seg.right {
                if budget <= 0 { break }
                var attrs = base
                if s.changed { attrs[.backgroundColor] = Theme.inlineBG }
                let piece = Self.display(s.text, limit: budget)
                budget -= piece.count
                out.append(NSAttributedString(string: piece, attributes: attrs))
            }
            return GridCell(text: out, background: bg)
        }
        return GridCell(text: NSAttributedString(string: Self.display(text), attributes: base), background: bg)
    }

    private func numberCell(_ n: Int?, _ kind: RowKind, _ side: Side) -> GridCell {
        let bg = Theme.background(kind, side) ?? NSColor.windowBackgroundColor.withAlphaComponent(0.6)
        guard let n else { return GridCell(text: nil, background: bg) }
        return GridCell(text: NSAttributedString(string: "\(n)", attributes: [
            .font: Theme.gutterFont, .foregroundColor: NSColor.secondaryLabelColor,
        ]), background: bg)
    }

    func cell(_ vis: Int, _ col: Int) -> GridCell {
        guard vis < visible.count else { return GridCell() }
        let index = visible[vis]
        let row = rows[index]
        switch col {
        case 0: return numberCell(row.leftNo, row.kind, .left)
        case 1: return textCell(index, .left)
        case 2:
            let (glyph, color) = Theme.marker(row.kind)
            return GridCell(text: NSAttributedString(string: glyph, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: color,
            ]), background: NSColor.windowBackgroundColor)
        case 3: return numberCell(row.rightNo, row.kind, .right)
        default: return textCell(index, .right)
        }
    }
}
