import Foundation

/// Autotest del motore cartelle (BeyondClone --selftest).
enum SyncSelfTest {
    static func run() -> Int {
        var failures = 0
        func check(_ cond: Bool, _ msg: String) {
            if !cond {
                failures += 1
                print("FAIL sync: \(msg)")
            }
        }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("bc-selftest-\(UUID().uuidString)")
        let a = base.appendingPathComponent("A"), b = base.appendingPathComponent("B")
        defer { try? fm.removeItem(at: base) }
        func write(_ root: URL, _ rel: String, _ text: String, age: TimeInterval = 0) {
            let u = root.appendingPathComponent(rel)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: u, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: u.path)
        }
        func read(_ root: URL, _ rel: String) -> String? {
            try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
        }
        func setup() {
            try? fm.removeItem(at: base)
            write(a, "uguale.txt", "x", age: 10000)
            write(b, "uguale.txt", "x", age: 10000)
            write(a, "nuovo_a_sinistra.txt", "nuovo", age: 10)
            write(a, "sub/piu_recente.txt", "recente", age: 10)
            write(b, "sub/piu_recente.txt", "vecchio!", age: 50000)
            write(b, "piu_recente_a_destra.txt", "destra", age: 10)
            write(a, "piu_recente_a_destra.txt", "sinistra vecchio", age: 50000)
            write(b, "solo_destra/extra.txt", "extra", age: 10)
            write(a, "profonda/a/b/c/d.txt", String(repeating: "z", count: 300_000), age: 10)
            write(a, ".DS_Store", "junk")
            write(a, "ora_legale.txt", "h", age: 20000)
            write(b, "ora_legale.txt", "h", age: 20000 + 3600)
        }
        var opts = DirOptions()
        opts.excludes = ".DS_Store"
        let roots = Planner.Roots(left: a, right: b)
        func scan() -> FolderNode { (try? Tree.scanSync(left: a, right: b, options: opts)) ?? FolderNode.root(a, b) }
        func execute(_ plan: SyncPlan, _ mode: DeleteMode) -> SyncResult {
            let exec = SyncExecutor(plan: plan, deleteMode: mode, parallel: 3, cancel: CancelFlag(), log: nil, onProgress: { _ in })
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var out = SyncResult()
            Task.detached {
                out = await exec.run()
                sem.signal()
            }
            sem.wait()
            return out
        }

        // Analisi: conteggi e stati.
        setup()
        var root = scan()
        check(root.complete, "radice non completata")
        check(root.tally.leftOnly == 2, "orfani sinistra: \(root.tally.leftOnly)")
        check(root.tally.rightOnly == 1, "orfani destra: \(root.tally.rightOnly)")
        check(root.tally.changed == 2, "modificati: \(root.tally.changed)")
        check(root.tally.same == 2, "uguali (con ora legale): \(root.tally.same)")

        // Specchia a destra con archivio.
        var res = execute(Planner.plan(.mirrorRight, root, roots: roots), .archive)
        check(res.errors.isEmpty, "mirror errori \(res.errors)")
        root = scan()
        check(root.status == .same, "mirror: non allineate (\(root.tally))")
        check(read(b, "sub/piu_recente.txt") == "recente", "mirror: contenuto")
        check(read(b, "profonda/a/b/c/d.txt")?.count == 300_000, "mirror: file profondo")
        check(!fm.fileExists(atPath: b.appendingPathComponent("solo_destra").path), "mirror: extra non eliminato")
        let archived = res.archiveFolders.first ?? ""
        check(fm.fileExists(atPath: archived + "/solo_destra/extra.txt"), "mirror: extra non archiviato")
        check(fm.fileExists(atPath: archived + "/sub/piu_recente.txt"), "mirror: sovrascritto non archiviato")
        check(!fm.fileExists(atPath: b.appendingPathComponent(".DS_Store").path), "mirror: escluso copiato")
        check(Planner.plan(.mirrorRight, root, roots: roots).isEmpty, "mirror: secondo passaggio non vuoto")
        let leftovers = (try? fm.subpathsOfDirectory(atPath: b.path))?.filter { $0.hasSuffix(DirLister.partSuffix) } ?? []
        check(leftovers.isEmpty, "file temporanei rimasti: \(leftovers)")

        // Aggiorna destra: non elimina e non tocca il più recente.
        setup()
        res = execute(Planner.plan(.updateRight, scan(), roots: roots), .archive)
        check(read(b, "nuovo_a_sinistra.txt") == "nuovo", "update: nuovo non copiato")
        check(read(b, "solo_destra/extra.txt") == "extra", "update: extra eliminato")
        check(read(b, "piu_recente_a_destra.txt") == "destra", "update: sovrascritto il più recente")

        // Aggiorna entrambe.
        setup()
        res = execute(Planner.plan(.updateBoth, scan(), roots: roots), .permanent)
        check(res.errors.isEmpty, "both errori \(res.errors)")
        check(scan().status == .same, "both: non allineate")
        check(read(a, "piu_recente_a_destra.txt") == "destra", "both: verso sinistra")
        check(read(a, "solo_destra/extra.txt") == "extra", "both: orfano destro")

        // Date mantenute.
        let da = (try? fm.attributesOfItem(atPath: a.appendingPathComponent("nuovo_a_sinistra.txt").path))?[.modificationDate] as? Date
        let db = (try? fm.attributesOfItem(atPath: b.appendingPathComponent("nuovo_a_sinistra.txt").path))?[.modificationDate] as? Date
        check(da != nil && db != nil && abs(da!.timeIntervalSince(db!)) < 1, "date non mantenute")

        // Maiuscole diverse: con l'opzione attiva i nomi si abbinano e non si duplicano.
        setup()
        write(a, "Foto/IMG.JPG", "1", age: 10)
        write(b, "foto/img.jpg", "1", age: 10)
        opts.caseInsensitive = true
        root = scan()
        let foto = root.children.first { $0.name.lowercased() == "foto" }
        check(foto?.isDirBoth == true && foto?.status == .same, "maiuscole: non abbinate")
        opts.caseInsensitive = false

        // Cartella non raggiungibile.
        do {
            _ = try Tree.scanSync(left: a, right: base.appendingPathComponent("manca"), options: opts)
            check(false, "analisi su cartella mancante non fallisce")
        } catch {}

        // Copia con avanzamento e interruzione.
        let big = base.appendingPathComponent("grande.bin"), copyDst = base.appendingPathComponent("copia.bin")
        fm.createFile(atPath: big.path, contents: Data(count: 8_000_000))
        nonisolated(unsafe) var seen: Int64 = 0
        try? SyncExecutor.copyFile(big, copyDst, cancel: CancelFlag()) { seen += $0 }
        check(seen == 8_000_000, "byte riportati: \(seen)")
        let stop = CancelFlag()
        stop.cancel()
        do {
            try SyncExecutor.copyFile(big, base.appendingPathComponent("stop.bin"), cancel: stop) { _ in }
            check(false, "copia annullata non fallisce")
        } catch {}

        print(failures == 0 ? "SYNC SELFTEST OK" : "SYNC SELFTEST FALLITO (\(failures))")
        return failures
    }
}
