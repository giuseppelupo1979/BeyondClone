import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Stile

enum DirStyle {
    static let nameFont = NSFont.systemFont(ofSize: 12.5)
    static let dirFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    static let metaFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
    static let glyphFont = NSFont.systemFont(ofSize: 11, weight: .bold)

    static let changed = NSColor.systemRed
    static let orphan = NSColor.systemPurple
    static let mismatch = NSColor.systemOrange

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yy  HH:mm"
        return f
    }()

    static func nameColor(_ n: FolderNode, _ side: Side) -> NSColor {
        switch n.status {
        case .same: return .labelColor
        case .pending: return .labelColor
        case .different: return n.typeMismatch ? mismatch : (n.isDir ? .labelColor : changed)
        case .leftNewer: return side == .left ? changed : .secondaryLabelColor
        case .rightNewer: return side == .right ? changed : .secondaryLabelColor
        case .leftOnly, .rightOnly: return orphan
        }
    }

    static func rowTint(_ n: FolderNode) -> NSColor? {
        switch n.status {
        case .leftOnly, .rightOnly: return orphan.withAlphaComponent(0.07)
        case .leftNewer, .rightNewer: return changed.withAlphaComponent(0.06)
        case .different: return n.isDir ? nil : (n.typeMismatch ? mismatch : changed).withAlphaComponent(0.06)
        default: return nil
        }
    }

    static func glyph(_ n: FolderNode) -> (String, NSColor) {
        if n.isDir, !n.complete { return ("⋯", .tertiaryLabelColor) }
        switch n.status {
        case .same: return ("=", .tertiaryLabelColor)
        case .different: return n.typeMismatch ? ("⇆", mismatch) : ("≠", changed)
        case .leftNewer: return ("›", changed)
        case .rightNewer: return ("‹", changed)
        case .leftOnly: return ("◀", orphan)
        case .rightOnly: return ("▶", orphan)
        case .pending: return ("⋯", .tertiaryLabelColor)
        }
    }

    private static var iconCache: [String: NSImage] = [:]

    static func icon(_ info: FileInfo) -> NSImage {
        let key: String
        if info.isDir {
            let ext = info.url.pathExtension.lowercased()
            key = ext.isEmpty ? "/dir" : "/dir." + ext
        } else {
            key = info.url.pathExtension.lowercased()
        }
        if let i = iconCache[key] { return i }
        let image: NSImage
        if info.isDir {
            let ext = info.url.pathExtension
            if !ext.isEmpty, let t = UTType(filenameExtension: ext), t.conforms(to: .package) {
                image = NSWorkspace.shared.icon(for: t)
            } else {
                image = NSWorkspace.shared.icon(for: .folder)
            }
        } else {
            image = NSWorkspace.shared.icon(for: UTType(filenameExtension: key) ?? .data)
        }
        image.size = NSSize(width: 16, height: 16)
        iconCache[key] = image
        return image
    }
}

// MARK: - Celle

final class DirCellView: NSView {
    enum Content {
        case empty
        case name(FileInfo?, String, NSColor, NSFont, indent: CGFloat, badge: (String, NSColor)?)
        case meta(String, NSColor)
        case glyph(String, NSColor)
    }

    var content: Content = .empty { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        switch content {
        case .empty:
            break
        case .name(let info, let text, let color, let font, let indent, let badge):
            var x = indent + 2
            if let info {
                DirStyle.icon(info).draw(in: NSRect(x: x, y: (h - 16) / 2, width: 16, height: 16),
                                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x += 21
            } else {
                return
            }
            var maxX = bounds.width - 6
            if let (b, bc) = badge {
                let attrs: [NSAttributedString.Key: Any] = [.font: DirStyle.badgeFont, .foregroundColor: bc]
                let s = NSAttributedString(string: b, attributes: attrs)
                let size = s.size()
                let pill = NSRect(x: bounds.width - size.width - 18, y: (h - 15) / 2, width: size.width + 10, height: 15)
                bc.withAlphaComponent(0.14).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 7.5, yRadius: 7.5).fill()
                s.draw(at: NSPoint(x: pill.minX + 5, y: pill.minY + (15 - size.height) / 2))
                maxX = pill.minX - 6
            }
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingMiddle
            let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
            let th = s.size().height
            s.draw(with: NSRect(x: x, y: (h - th) / 2, width: max(0, maxX - x), height: th + 2),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        case .meta(let text, let color):
            let s = NSAttributedString(string: text, attributes: [.font: DirStyle.metaFont, .foregroundColor: color])
            let size = s.size()
            s.draw(at: NSPoint(x: bounds.width - size.width - 8, y: (h - size.height) / 2))
        case .glyph(let g, let color):
            let s = NSAttributedString(string: g, attributes: [.font: DirStyle.glyphFont, .foregroundColor: color])
            let size = s.size()
            if color != .tertiaryLabelColor {
                let pill = NSRect(x: (bounds.width - 22) / 2, y: (h - 16) / 2, width: 22, height: 16)
                color.withAlphaComponent(0.15).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
            }
            s.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (h - size.height) / 2))
        }
    }
}

final class DirRowView: NSTableRowView {
    var tint: NSColor?

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if let tint, !isSelected {
            tint.setFill()
            bounds.fill(using: .sourceOver)
        }
    }
}

final class DirOutlineView: NSOutlineView {
    var onKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    convenience init(_ title: String, symbol: String? = nil, enabled: Bool = true, _ handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.handler = handler
        target = self
        isEnabled = enabled
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @objc private func fire() { handler?() }
}

// MARK: - Vista ad albero

struct DirOutline: NSViewRepresentable {
    @ObservedObject var session: FolderSession
    var onOpenFiles: (FileInfo, FileInfo) -> Void

    enum Col: String, CaseIterable {
        case lname, lsize, ldate, mid, rname, rsize, rdate
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let ov = DirOutlineView()
        ov.style = .fullWidth
        ov.rowHeight = 22
        ov.intercellSpacing = NSSize(width: 0, height: 0)
        ov.usesAlternatingRowBackgroundColors = true
        ov.allowsMultipleSelection = true
        ov.indentationPerLevel = 14
        ov.autoresizesOutlineColumn = false
        ov.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        ov.headerView = NSTableHeaderView()
        ov.gridStyleMask = []
        let specs: [(Col, String, CGFloat, Bool)] = [
            (.lname, "Sinistra", 320, true), (.lsize, "Dimensione", 84, false), (.ldate, "Modificato", 116, false),
            (.mid, "", 40, false),
            (.rname, "Destra", 320, true), (.rsize, "Dimensione", 84, false), (.rdate, "Modificato", 116, false),
        ]
        for (col, title, width, flexible) in specs {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.rawValue))
            c.title = title
            c.width = width
            c.minWidth = flexible ? 140 : (col == .mid ? 40 : 60)
            c.maxWidth = flexible ? 4000 : (col == .mid ? 40 : 200)
            c.resizingMask = flexible ? [.autoresizingMask, .userResizingMask] : (col == .mid ? [] : .userResizingMask)
            if col == .lsize || col == .rsize || col == .ldate || col == .rdate {
                c.headerCell.alignment = .right
            }
            switch col {
            case .lname: c.headerToolTip = "Elementi della cartella di sinistra. Doppio clic su una cartella per aprirla, su un file per confrontarne il contenuto"
            case .rname: c.headerToolTip = "Elementi della cartella di destra"
            case .lsize, .rsize: c.headerToolTip = "Dimensione del file o, per le cartelle, del loro contenuto"
            case .ldate, .rdate: c.headerToolTip = "Data di ultima modifica; in rosso il lato più recente"
            case .mid: c.headerToolTip = "Stato: = uguali, ≠ diversi, › ‹ più recente a sinistra/destra, ◀ ▶ presente da un solo lato, ⋯ in analisi"
            }
            ov.addTableColumn(c)
            if col == .lname { ov.outlineTableColumn = c }
        }
        ov.dataSource = context.coordinator
        ov.delegate = context.coordinator
        ov.target = context.coordinator
        ov.doubleAction = #selector(Coordinator.doubleClick(_:))
        let menu = NSMenu()
        menu.delegate = context.coordinator
        ov.menu = menu
        ov.onKey = { [weak coord = context.coordinator] e in coord?.key(e) ?? false }

        let scroll = NSScrollView()
        scroll.documentView = ov
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        context.coordinator.outline = ov
        context.coordinator.version = session.treeVersion
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let ov = c.outline else { return }
        if c.rootID != session.root.map(ObjectIdentifier.init) {
            c.rootID = session.root.map(ObjectIdentifier.init)
            c.wantExpand.removeAll()
            c.reload(ov, keepSelection: false)
        } else if c.version != session.treeVersion {
            c.reload(ov, keepSelection: true)
        }
        c.version = session.treeVersion
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: DirOutline
        weak var outline: DirOutlineView?
        var version = -1
        var rootID: ObjectIdentifier?
        var suppress = false
        var wantExpand = Set<ObjectIdentifier>()
        private var expandedNodes: [ObjectIdentifier: FolderNode] = [:]

        private var observer: NSObjectProtocol?

        init(_ parent: DirOutline) {
            self.parent = parent
            super.init()
            let id = parent.session.id
            observer = NotificationCenter.default.addObserver(forName: .outlineCommand, object: nil, queue: .main) { [weak self] note in
                guard (note.object as? UUID) == id, let cmd = note.userInfo?["cmd"] as? String else { return }
                MainActor.assumeIsolated {
                    if cmd == "expand" { self?.expandAll() } else { self?.collapseAll() }
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        var session: FolderSession { parent.session }

        func reload(_ ov: NSOutlineView, keepSelection: Bool) {
            suppress = true
            ov.reloadData()
            // Riapre le cartelle chieste mentre non erano ancora lette.
            for (id, node) in expandedNodes where wantExpand.contains(id) && node.listed {
                if !session.visibleChildren(node).isEmpty {
                    ov.expandItem(node)
                    wantExpand.remove(id)
                }
            }
            if keepSelection {
                let rows = IndexSet(session.selection.compactMap { n -> Int? in
                    let r = ov.row(forItem: n)
                    return r >= 0 ? r : nil
                })
                ov.selectRowIndexes(rows, byExtendingSelection: false)
            } else {
                expandedNodes.removeAll()
            }
            suppress = false
        }

        private func node(_ item: Any?) -> FolderNode? {
            item as? FolderNode ?? session.root
        }

        // MARK: Dati

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let n = node(item) else { return 0 }
            return session.visibleChildren(n).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            let kids = session.visibleChildren(node(item)!)
            return index < kids.count ? kids[index] : FolderNode(name: "", relPath: "", left: nil, right: nil, status: .same)
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let n = item as? FolderNode, n.isDir else { return false }
            return !n.listed || !session.visibleChildren(n).isEmpty
        }

        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let n = notification.userInfo?["NSObject"] as? FolderNode else { return }
            expandedNodes[ObjectIdentifier(n)] = n
            if !n.listed {
                wantExpand.insert(ObjectIdentifier(n))
                session.prioritize(n)
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let n = notification.userInfo?["NSObject"] as? FolderNode else { return }
            expandedNodes[ObjectIdentifier(n)] = nil
            wantExpand.remove(ObjectIdentifier(n))
        }

        // MARK: Celle

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let r = DirRowView()
            if let n = item as? FolderNode { r.tint = DirStyle.rowTint(n) }
            return r
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let tableColumn, let col = Col(rawValue: tableColumn.identifier.rawValue), let n = item as? FolderNode else { return nil }
            let id = NSUserInterfaceItemIdentifier("c")
            let v = (outlineView.makeView(withIdentifier: id, owner: nil) as? DirCellView) ?? {
                let v = DirCellView(frame: .zero)
                v.identifier = id
                return v
            }()
            v.content = content(n, col, outlineView)
            v.toolTip = tooltip(n, col)
            return v
        }

        private func badge(_ n: FolderNode) -> (String, NSColor)? {
            guard n.isDir, n.complete, n.isDirBoth else { return nil }
            let d = n.tally.diffs
            return d > 0 ? ("\(d)", DirStyle.changed) : nil
        }

        private func content(_ n: FolderNode, _ col: Col, _ ov: NSOutlineView) -> DirCellView.Content {
            switch col {
            case .lname, .rname:
                let side: Side = col == .lname ? .left : .right
                let info = n.info(side)
                let indent: CGFloat = side == .left ? 0 : CGFloat(ov.level(forItem: n)) * ov.indentationPerLevel + 14
                let font = n.isDir ? DirStyle.dirFont : DirStyle.nameFont
                let text = info?.name ?? ""
                return .name(info, text, DirStyle.nameColor(n, side), font, indent: indent, badge: side == .left ? badge(n) : nil)
            case .lsize, .rsize:
                let side: Side = col == .lsize ? .left : .right
                guard let info = n.info(side) else { return .empty }
                if info.isDir {
                    guard n.complete else { return .meta("…", .tertiaryLabelColor) }
                    let bytes = side == .left ? n.tally.leftBytes : n.tally.rightBytes
                    return .meta(Fmt.size(bytes), .tertiaryLabelColor)
                }
                return .meta(Fmt.size(info.size), .secondaryLabelColor)
            case .ldate, .rdate:
                let side: Side = col == .ldate ? .left : .right
                guard let info = n.info(side), !info.isDir, let d = info.modified else { return .empty }
                let newerHere = (side == .left && n.status == .leftNewer) || (side == .right && n.status == .rightNewer)
                return .meta(DirStyle.dateFormatter.string(from: d), newerHere ? DirStyle.changed : .secondaryLabelColor)
            case .mid:
                let (g, c) = DirStyle.glyph(n)
                return .glyph(g, c)
            }
        }

        private func tooltip(_ n: FolderNode, _ col: Col) -> String {
            switch col {
            case .mid, .lsize, .rsize: return Self.describe(n)
            case .lname, .ldate: return n.left.map { "\($0.url.path)\n\(Self.describe(n))" } ?? "Non presente a sinistra"
            case .rname, .rdate: return n.right.map { "\($0.url.path)\n\(Self.describe(n))" } ?? "Non presente a destra"
            }
        }

        static func describe(_ n: FolderNode) -> String {
            if n.isDir, !n.complete { return "Cartella in analisi" }
            switch n.status {
            case .same: return n.isDir ? "Cartelle identiche" : "File uguali"
            case .different:
                if n.typeMismatch { return "Da un lato è un file, dall'altro una cartella" }
                if n.isDir { return "Contiene \(n.tally.diffs) differenze: \(n.tally.changed) modificati, \(n.tally.leftOnly) solo a sinistra, \(n.tally.rightOnly) solo a destra" }
                return "Diversi, con la stessa data"
            case .leftNewer: return "Più recente a sinistra"
            case .rightNewer: return "Più recente a destra"
            case .leftOnly: return "Presente solo a sinistra"
            case .rightOnly: return "Presente solo a destra"
            case .pending: return "In analisi"
            }
        }

        // MARK: Selezione e azioni

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !suppress, let ov = outline else { return }
            let nodes = ov.selectedRowIndexes.compactMap { ov.item(atRow: $0) as? FolderNode }
            DispatchQueue.main.async { self.session.selection = nodes }
        }

        @objc func doubleClick(_ sender: Any?) {
            guard let ov = outline, ov.clickedRow >= 0, let n = ov.item(atRow: ov.clickedRow) as? FolderNode else { return }
            if n.isDir {
                if ov.isItemExpanded(n) { ov.collapseItem(n) } else { ov.expandItem(n) }
            } else if let l = n.left, let r = n.right {
                parent.onOpenFiles(l, r)
            } else if let only = n.left ?? n.right {
                NSWorkspace.shared.open(only.url)
            }
        }

        func key(_ e: NSEvent) -> Bool {
            guard let ov = outline else { return false }
            let nodes = ov.selectedRowIndexes.compactMap { ov.item(atRow: $0) as? FolderNode }
            guard !nodes.isEmpty else { return false }
            if e.modifierFlags.contains(.option) {
                if e.keyCode == 124 { session.prepareCopy(nodes, to: .right); return true }
                if e.keyCode == 123 { session.prepareCopy(nodes, to: .left); return true }
            }
            return false
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let ov = outline else { return }
            let nodes = ov.selectedRowIndexes.compactMap { ov.item(atRow: $0) as? FolderNode }
            guard !nodes.isEmpty else { return }
            let s = session
            let busy = s.isRunning
            let hasLeft = nodes.contains { $0.left != nil }, hasRight = nodes.contains { $0.right != nil }
            menu.addItem(ClosureMenuItem("Copia a destra  ⌥→", symbol: "arrow.right.to.line", enabled: hasLeft && !busy) { s.prepareCopy(nodes, to: .right) })
            menu.addItem(ClosureMenuItem("Copia a sinistra  ⌥←", symbol: "arrow.left.to.line", enabled: hasRight && !busy) { s.prepareCopy(nodes, to: .left) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Elimina a sinistra…", symbol: "trash", enabled: hasLeft && !busy) { s.prepareDelete(nodes, on: .left) })
            menu.addItem(ClosureMenuItem("Elimina a destra…", symbol: "trash", enabled: hasRight && !busy) { s.prepareDelete(nodes, on: .right) })
            menu.addItem(.separator())
            let names = nodes.count == 1 ? "«\(nodes[0].name)»" : "\(nodes.count) nomi"
            menu.addItem(ClosureMenuItem("Escludi \(names) dal confronto", symbol: "eye.slash") { s.exclude(nodes) })
            menu.addItem(.separator())
            if nodes.count == 1, let n = nodes.first, !n.isDir, let l = n.left, let r = n.right {
                menu.addItem(ClosureMenuItem("Confronta il contenuto dei due file", symbol: "doc.text.magnifyingglass") { [weak self] in
                    self?.parent.onOpenFiles(l, r)
                })
            }
            menu.addItem(ClosureMenuItem("Mostra a sinistra nel Finder", symbol: "folder", enabled: hasLeft) {
                NSWorkspace.shared.activateFileViewerSelecting(nodes.compactMap { $0.left?.url })
            })
            menu.addItem(ClosureMenuItem("Mostra a destra nel Finder", symbol: "folder", enabled: hasRight) {
                NSWorkspace.shared.activateFileViewerSelecting(nodes.compactMap { $0.right?.url })
            })
            menu.addItem(ClosureMenuItem("Copia percorso relativo", symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(nodes.map(\.relPath).joined(separator: "\n"), forType: .string)
            })
        }

        func expandAll() { outline?.expandItem(nil, expandChildren: true) }
        func collapseAll() { outline?.collapseItem(nil, collapseChildren: true) }
    }
}
