import SwiftUI
import UniformTypeIdentifiers

enum SessionKind: String, Codable, CaseIterable {
    case text, folder, hex, image

    var title: String {
        switch self {
        case .text: return "Confronto testo"
        case .folder: return "Confronto cartelle"
        case .hex: return "Confronto esadecimale"
        case .image: return "Confronto immagini"
        }
    }

    var subtitle: String {
        switch self {
        case .text: return "Due file affiancati, differenze riga per riga e dentro la riga"
        case .folder: return "Due alberi di cartelle, copia e sincronizzazione"
        case .hex: return "File binari byte per byte"
        case .image: return "Affiancate, differenza, sovrapposizione"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "doc.text"
        case .folder: return "folder"
        case .hex: return "number.square"
        case .image: return "photo.on.rectangle"
        }
    }

    static func detect(_ l: URL, _ r: URL) -> SessionKind {
        if l.isDirectory && r.isDirectory { return .folder }
        if l.isImageFile && r.isImageFile { return .image }
        if l.looksBinary || r.looksBinary { return .hex }
        return .text
    }
}

struct SessionSpec: Codable, Hashable {
    var id = UUID()
    var kind: SessionKind?
    var left: String?
    var right: String?
    var profileID: UUID?

    var leftURL: URL? { left.map { URL(fileURLWithPath: $0) } }
    var rightURL: URL? { right.map { URL(fileURLWithPath: $0) } }

    init(kind: SessionKind? = nil, left: URL? = nil, right: URL? = nil, profileID: UUID? = nil) {
        self.kind = kind
        self.left = left?.path
        self.right = right?.path
        self.profileID = profileID
    }
}

enum AppLaunch {
    private static var consumed = false

    /// Sessione iniziale da riga di comando: --left <percorso> --right <percorso> [--kind text|folder|hex|image]
    static func takeInitial() -> SessionSpec? {
        if consumed { return nil }
        consumed = true
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let l = value("--left"), let r = value("--right") else { return nil }
        let lu = URL(fileURLWithPath: l), ru = URL(fileURLWithPath: r)
        let kind = value("--kind").flatMap(SessionKind.init(rawValue:)) ?? SessionKind.detect(lu, ru)
        return SessionSpec(kind: kind, left: lu, right: ru)
    }
}

struct BeyondCloneApp: App {
    var body: some Scene {
        WindowGroup("BeyondClone", id: "main") {
            MainWindow()
        }
        .defaultSize(width: 1440, height: 860)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nuova finestra") {
                    NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        // Confronto del contenuto di due file (doppio clic su una coppia nell'albero).
        WindowGroup("Confronto file", for: SessionSpec.self) { $spec in
            FileCompareRoot(spec: spec ?? SessionSpec())
        }
        .defaultSize(width: 1280, height: 800)
    }
}

struct FileCompareRoot: View {
    let spec: SessionSpec

    var body: some View {
        Group {
            switch spec.kind {
            case .hex:
                HexCompareView(left: spec.leftURL, right: spec.rightURL)
            case .image:
                ImageCompareView(left: spec.leftURL, right: spec.rightURL)
            default:
                TextCompareView(left: spec.leftURL, right: spec.rightURL)
            }
        }
        .frame(minWidth: 900, minHeight: 520)
    }
}
