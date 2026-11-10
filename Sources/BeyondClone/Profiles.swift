import Foundation
import NetFS
import AppKit

// MARK: - Profilo

struct SyncProfile: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name = "Nuovo profilo"
    var left = ""
    var right = ""
    /// Server da montare se la cartella non è raggiungibile, es. smb://DS920.local/Foto
    var leftServer = ""
    var rightServer = ""
    var mode: SyncMode = .updateRight
    var deleteMode: DeleteMode = .archive
    var options = DirOptions()
    var lastRun: Date?
    var lastResult: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SyncProfile()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        left = try c.decodeIfPresent(String.self, forKey: .left) ?? ""
        right = try c.decodeIfPresent(String.self, forKey: .right) ?? ""
        leftServer = try c.decodeIfPresent(String.self, forKey: .leftServer) ?? ""
        rightServer = try c.decodeIfPresent(String.self, forKey: .rightServer) ?? ""
        mode = (try? c.decodeIfPresent(SyncMode.self, forKey: .mode)) ?? d.mode
        deleteMode = (try? c.decodeIfPresent(DeleteMode.self, forKey: .deleteMode)) ?? d.deleteMode
        options = (try? c.decodeIfPresent(DirOptions.self, forKey: .options)) ?? d.options
        lastRun = try? c.decodeIfPresent(Date.self, forKey: .lastRun)
        lastResult = try? c.decodeIfPresent(String.self, forKey: .lastResult)
    }

    var leftURL: URL? { left.isEmpty ? nil : URL(fileURLWithPath: left) }
    var rightURL: URL? { right.isEmpty ? nil : URL(fileURLWithPath: right) }
    var isComplete: Bool { !left.isEmpty && !right.isEmpty }
}

// MARK: - Archivio dei profili

@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published private(set) var profiles: [SyncProfile] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeyondClone", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profili.json")
    }()

    private init() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL), let list = try? dec.decode([SyncProfile].self, from: data) {
            profiles = list
        }
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(profiles) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func profile(_ id: UUID) -> SyncProfile? { profiles.first { $0.id == id } }

    func upsert(_ p: SyncProfile) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) {
            guard profiles[i] != p else { return }
            profiles[i] = p
        } else {
            profiles.append(p)
        }
        persist()
    }

    func delete(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        persist()
    }

    @discardableResult
    func duplicate(_ id: UUID) -> SyncProfile? {
        guard var p = profile(id) else { return nil }
        p.id = UUID()
        p.name += " (copia)"
        p.lastRun = nil
        p.lastResult = nil
        upsert(p)
        return p
    }

    func move(from: IndexSet, to: Int) {
        profiles.move(fromOffsets: from, toOffset: to)
        persist()
    }
}

// MARK: - NAS e volumi di rete

enum NASMount {
    /// Monta una share (smb://, afp://, nfs://). Se servono credenziali macOS mostra la sua finestra
    /// e può salvarle nel Portachiavi. Ritorna i punti di montaggio.
    static func mount(_ server: String) async throws -> [String] {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
            throw NSError(domain: "BeyondClone", code: 1, userInfo: [NSLocalizedDescriptionKey: "Indirizzo server non valido: \(server)"])
        }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let open = NSMutableDictionary()
                open[kNAUIOptionKey] = kNAUIOptionAllowUI
                var points: Unmanaged<CFArray>?
                let status = NetFSMountURLSync(url as CFURL, nil, nil, nil, open, nil, &points)
                let list = (points?.takeRetainedValue() as? [String]) ?? []
                if status == 0 || status == 17 {
                    RecentServers.add(server)
                    cont.resume(returning: list)
                } else {
                    let msg = status == -128 || status == 89 ? "Connessione annullata" : "Montaggio di \(server) non riuscito (codice \(status))"
                    cont.resume(throwing: NSError(domain: "BeyondClone", code: Int(status), userInfo: [NSLocalizedDescriptionKey: msg]))
                }
            }
        }
    }

    /// Indirizzo del server da cui è montato un volume di rete (senza password).
    static func serverURL(for url: URL) -> String? {
        VolumeInfo.of(url)?.server
    }
}

enum RecentServers {
    private static let key = "recentServers"
    static var list: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func add(_ s: String) {
        var l = list.filter { $0 != s }
        l.insert(s, at: 0)
        UserDefaults.standard.set(Array(l.prefix(10)), forKey: key)
    }
}

struct VolumeInfo: Identifiable, Hashable {
    let url: URL
    let name: String
    let isNetwork: Bool
    let isRemovable: Bool
    let free: Int64?
    let total: Int64?
    let server: String?
    var id: String { url.path }

    var symbol: String {
        if isNetwork { return "externaldrive.connected.to.line.below" }
        if isRemovable { return "externaldrive" }
        return "internaldrive"
    }

    private static let networkTypes: Set<String> = ["smbfs", "afpfs", "nfs", "webdav", "cifs", "ftp"]

    /// Punti di montaggio letti con getmntinfo(MNT_NOWAIT): dati già in memoria, non blocca mai
    /// nemmeno se un volume di rete non risponde.
    private static func mounts() -> [statfs] {
        var ptr: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&ptr, MNT_NOWAIT)
        guard n > 0, let ptr else { return [] }
        return Array(UnsafeBufferPointer(start: ptr, count: Int(n)))
    }

    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func make(_ m: statfs) -> VolumeInfo {
        let path = string(m.f_mntonname)
        let type = string(m.f_fstypename)
        let from = string(m.f_mntfromname)
        let isNet = networkTypes.contains(type)
        var server: String?
        if isNet, from.hasPrefix("//") {
            // //utente@server/condivisione → smb://server/condivisione (senza credenziali)
            var rest = String(from.dropFirst(2))
            if let at = rest.lastIndex(of: "@"), let slash = rest.firstIndex(of: "/"), at < slash { rest = String(rest[rest.index(after: at)...]) }
            let scheme = type == "afpfs" ? "afp" : (type == "webdav" ? "https" : "smb")
            server = "\(scheme)://\(rest)"
        } else if type == "nfs" {
            server = "nfs://" + from.replacingOccurrences(of: ":/", with: "/")
        }
        let bsize = Int64(m.f_bsize)
        let flags = UInt32(m.f_flags)
        let removable = !isNet && (flags & UInt32(MNT_LOCAL)) != 0 && path.hasPrefix("/Volumes/") && (flags & UInt32(MNT_ROOTFS)) == 0
        return VolumeInfo(url: URL(fileURLWithPath: path), name: path == "/" ? "Macintosh HD" : (path as NSString).lastPathComponent,
                          isNetwork: isNet, isRemovable: removable,
                          free: Int64(m.f_bavail) * bsize, total: Int64(m.f_blocks) * bsize, server: server)
    }

    static func of(_ url: URL) -> VolumeInfo? {
        let path = url.standardizedFileURL.path
        let best = mounts()
            .filter { let p = string($0.f_mntonname); return path == p || path.hasPrefix(p == "/" ? "/" : p + "/") }
            .max { string($0.f_mntonname).count < string($1.f_mntonname).count }
        return best.map(make)
    }

    static func mounted() -> [VolumeInfo] {
        mounts()
            .filter {
                let p = string($0.f_mntonname)
                let flags = UInt32($0.f_flags)
                return p.hasPrefix("/Volumes/") && (flags & UInt32(MNT_DONTBROWSE)) == 0
            }
            .map(make)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
