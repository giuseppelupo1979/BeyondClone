import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Side {
    case left, right
    var other: Side { self == .left ? .right : .left }
    var label: String { self == .left ? "sinistra" : "destra" }
}

extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    var isImageFile: Bool {
        guard let type = UTType(filenameExtension: pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// Byte NUL nei primi 8 KB (escluso UTF-16 con BOM).
    var looksBinary: Bool {
        guard let h = try? FileHandle(forReadingFrom: self) else { return false }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 8192)) ?? Data()
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return false }
        return data.contains(0)
    }
}

enum Fmt {
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy HH:mm:ss"
        return f
    }()

    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func size(_ n: Int64) -> String { bytes.string(fromByteCount: n) }

    static func speed(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1 ? "—" : bytes.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(max(0, s)) s" }
        if s < 3600 { return "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \(s % 3600 / 60) min"
    }
}

enum Theme {
    static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    static let inlineBG = NSColor.systemOrange.withAlphaComponent(0.45)

    static func background(_ kind: RowKind, _ side: Side) -> NSColor? {
        switch kind {
        case .equal: return nil
        case .changed: return NSColor.systemOrange.withAlphaComponent(0.13)
        case .leftOnly: return side == .left ? NSColor.systemRed.withAlphaComponent(0.17) : NSColor.systemGray.withAlphaComponent(0.10)
        case .rightOnly: return side == .right ? NSColor.systemGreen.withAlphaComponent(0.17) : NSColor.systemGray.withAlphaComponent(0.10)
        }
    }

    static func marker(_ kind: RowKind) -> (String, NSColor) {
        switch kind {
        case .equal: return ("", .clear)
        case .changed: return ("≠", .systemOrange)
        case .leftOnly: return ("−", .systemRed)
        case .rightOnly: return ("+", .systemGreen)
        }
    }
}

func pickURL(directories: Bool) -> URL? {
    let p = NSOpenPanel()
    p.canChooseDirectories = directories
    p.canChooseFiles = !directories
    p.allowsMultipleSelection = false
    return p.runModal() == .OK ? p.url : nil
}

func confirmAlert(_ title: String, _ info: String, action: String) -> Bool {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = info
    a.alertStyle = .warning
    a.addButton(withTitle: action)
    a.addButton(withTitle: "Annulla")
    return a.runModal() == .alertFirstButtonReturn
}

func infoAlert(_ title: String, _ info: String) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = info
    a.runModal()
}

func loadURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL?] = Array(repeating: nil, count: providers.count)
    for (i, p) in providers.enumerated() {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            DispatchQueue.main.async {
                urls[i] = url
                group.leave()
            }
        }
    }
    group.notify(queue: .main) { completion(urls.compactMap { $0 }) }
}

/// Barra del percorso di un lato: mostra il file, permette di sceglierlo o trascinarlo.
struct PathField: View {
    let url: URL?
    var directories = false
    var dirty = false
    var placeholder = "Trascina qui o scegli…"
    let onPick: (URL) -> Void
    @Local private var targeted = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: directories ? "folder" : "doc")
                .foregroundStyle(.secondary)
            Text(url?.path ?? placeholder)
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(url == nil ? .secondary : .primary)
                .help(url?.path ?? "")
            if dirty {
                Text("modificato")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.25)))
            }
            Spacer(minLength: 4)
            Button("Scegli…") {
                if let u = pickURL(directories: directories) { onPick(u) }
            }
            .controlSize(.small)
            .help(directories ? "Scegli la cartella con il Finder" : "Scegli il file con il Finder")
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(targeted ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            loadURLs(providers) { urls in
                if let u = urls.first { onPick(u) }
            }
            return true
        }
    }
}

// MARK: - Tabella a celle disegnate (veloce anche con centinaia di migliaia di righe)

struct GridColumn {
    var title = ""
    var width: CGFloat
    var flexible = false
    var alignRight = false
}

struct GridCell {
    var text: NSAttributedString?
    var background: NSColor?
}

struct ScrollRequest: Equatable {
    var row: Int
    var token: Int
}

final class DrawCellView: NSView {
    var content = GridCell() { didSet { needsDisplay = true } }
    var alignRight = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if let bg = content.background {
            bg.setFill()
            bounds.fill(using: .sourceOver)
        }
        guard let t = content.text, t.length > 0 else { return }
        let size = t.size()
        let x = alignRight ? bounds.width - size.width - 6 : 4
        t.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))
    }
}

final class SoftRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.30).setFill()
        bounds.fill(using: .sourceOver)
    }
}

struct GridTable: NSViewRepresentable {
    var columns: [GridColumn]
    var rowCount: Int
    var version: Int
    var cell: (Int, Int) -> GridCell
    @Binding var selection: IndexSet
    var scrollRequest: ScrollRequest?
    var onDoubleClick: ((Int) -> Void)?
    var rowHeight: CGFloat = 17
    var showHeader = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .plain
        table.rowHeight = rowHeight
        table.intercellSpacing = .zero
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.backgroundColor = .textBackgroundColor
        table.headerView = showHeader ? NSTableHeaderView() : nil
        for (i, c) in columns.enumerated() {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(i)"))
            col.title = c.title
            col.width = c.width
            col.minWidth = c.flexible ? 80 : c.width
            col.maxWidth = c.flexible ? 100_000 : c.width
            col.resizingMask = c.flexible ? .autoresizingMask : []
            table.addTableColumn(col)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        scroll.borderType = .noBorder
        context.coordinator.table = table
        context.coordinator.rowCount = rowCount
        context.coordinator.version = version
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let table = c.table else { return }
        if c.version != version || c.rowCount != rowCount {
            c.version = version
            c.rowCount = rowCount
            c.suppress = true
            table.reloadData()
            c.suppress = false
        }
        let wanted = selection.filteredIndexSet { $0 < rowCount }
        if table.selectedRowIndexes != wanted {
            c.suppress = true
            table.selectRowIndexes(wanted, byExtendingSelection: false)
            c.suppress = false
        }
        if let s = scrollRequest, s.token != c.lastScrollToken {
            c.lastScrollToken = s.token
            if s.row >= 0, s.row < rowCount {
                let r = table.rect(ofRow: s.row)
                let visible = scroll.contentView.bounds
                if r.minY < visible.minY + rowHeight * 2 || r.maxY > visible.maxY - rowHeight * 2 {
                    let header = table.headerView?.frame.height ?? 0
                    let maxY = max(0, table.frame.height - visible.height)
                    let y = min(maxY, max(0, r.minY - visible.height / 3)) - header
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: GridTable
        weak var table: NSTableView?
        var version = 0
        var rowCount = 0
        var suppress = false
        var lastScrollToken = Int.min

        init(_ parent: GridTable) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let ci = Int(tableColumn.identifier.rawValue) else { return nil }
            let id = NSUserInterfaceItemIdentifier("cell")
            let view = (tableView.makeView(withIdentifier: id, owner: nil) as? DrawCellView) ?? {
                let v = DrawCellView(frame: .zero)
                v.identifier = id
                return v
            }()
            view.alignRight = parent.columns[ci].alignRight
            view.content = row < rowCount ? parent.cell(row, ci) : GridCell()
            return view
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SoftRowView() }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppress, let table else { return }
            let s = table.selectedRowIndexes
            if s != parent.selection {
                DispatchQueue.main.async { self.parent.selection = s }
            }
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let table, table.clickedRow >= 0 else { return }
            parent.onDoubleClick?(table.clickedRow)
        }
    }
}

/// Stato locale della vista. Sostituisce @State, che in questo SDK è una macro
/// il cui plugin manca nei Command Line Tools (serve Xcode).
@propertyWrapper
struct Local<Value>: DynamicProperty {
    private var storage: State<Value>

    init(wrappedValue: Value) {
        storage = State(initialValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}
