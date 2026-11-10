import Foundation

enum RowKind {
    case equal, changed, leftOnly, rightOnly
}

struct DiffRow {
    var kind: RowKind
    var left: String?
    var right: String?
    var leftNo: Int?
    var rightNo: Int?
}

struct CompareOptions: Equatable {
    var ignoreWhitespace = false
    var ignoreCase = false
}

/// Segmenti di una riga: testo + flag "diverso dall'altro lato".
typealias InlineSegments = [(text: String, changed: Bool)]

enum DiffEngine {
    // MARK: - API

    /// Coppie (indice in a, indice in b) di elementi abbinati, in ordine crescente.
    static func matches<T: Hashable>(_ a: [T], _ b: [T], patience: Bool = true) -> [(Int, Int)] {
        var table: [T: Int32] = [:]
        table.reserveCapacity(a.count + b.count)
        func intern(_ x: T) -> Int32 {
            if let v = table[x] { return v }
            let v = Int32(table.count)
            table[x] = v
            return v
        }
        let ia = a.map(intern)
        let ib = b.map(intern)
        var out: [(Int, Int)] = []
        out.reserveCapacity(min(a.count, b.count))
        diff(ia, ib, 0, ia.count, 0, ib.count, patience ? 0 : Int.max, &out)
        return out
    }

    /// Allinea due testi riga per riga.
    static func rows(left: [String], right: [String], options: CompareOptions = CompareOptions()) -> [DiffRow] {
        let m: [(Int, Int)]
        if options == CompareOptions() {
            m = matches(left, right)
        } else {
            m = matches(left.map { key($0, options) }, right.map { key($0, options) })
        }
        var rows: [DiffRow] = []
        rows.reserveCapacity(max(left.count, right.count))
        var i = 0, j = 0
        func gap(_ ai: Int, _ bj: Int) {
            let common = min(ai - i, bj - j)
            for k in 0..<common {
                rows.append(DiffRow(kind: .changed, left: left[i + k], right: right[j + k], leftNo: i + k + 1, rightNo: j + k + 1))
            }
            i += common
            j += common
            while i < ai {
                rows.append(DiffRow(kind: .leftOnly, left: left[i], right: nil, leftNo: i + 1, rightNo: nil))
                i += 1
            }
            while j < bj {
                rows.append(DiffRow(kind: .rightOnly, left: nil, right: right[j], leftNo: nil, rightNo: j + 1))
                j += 1
            }
        }
        for (ai, bj) in m {
            gap(ai, bj)
            rows.append(DiffRow(kind: .equal, left: left[ai], right: right[bj], leftNo: ai + 1, rightNo: bj + 1))
            i = ai + 1
            j = bj + 1
        }
        gap(left.count, right.count)
        return rows
    }

    /// Differenze a livello di carattere tra due righe.
    static func inline(_ l: String, _ r: String) -> (left: InlineSegments, right: InlineSegments) {
        let a = Array(l), b = Array(r)
        if a.count > 2000 || b.count > 2000 || a.isEmpty || b.isEmpty {
            return ([(l, true)], [(r, true)])
        }
        let m = matches(a, b, patience: false)
        if m.count * 4 < max(a.count, b.count) {
            return ([(l, true)], [(r, true)])
        }
        var ma = [Bool](repeating: true, count: a.count)
        var mb = [Bool](repeating: true, count: b.count)
        for (x, y) in m {
            ma[x] = false
            mb[y] = false
        }
        return (segments(a, ma), segments(b, mb))
    }

    // MARK: - Interni

    private static func key(_ s: String, _ o: CompareOptions) -> String {
        var s = s
        if o.ignoreWhitespace { s = String(s.filter { !$0.isWhitespace }) }
        if o.ignoreCase { s = s.lowercased() }
        return s
    }

    private static func segments(_ chars: [Character], _ mask: [Bool]) -> InlineSegments {
        var out: InlineSegments = []
        var start = 0
        while start < chars.count {
            var end = start + 1
            while end < chars.count, mask[end] == mask[start] { end += 1 }
            out.append((String(chars[start..<end]), mask[start]))
            start = end
        }
        return out
    }

    private static func diff(_ a: [Int32], _ b: [Int32], _ aLo0: Int, _ aHi0: Int, _ bLo0: Int, _ bHi0: Int,
                             _ depth: Int, _ out: inout [(Int, Int)]) {
        var aLo = aLo0, aHi = aHi0, bLo = bLo0, bHi = bHi0
        while aLo < aHi, bLo < bHi, a[aLo] == b[bLo] {
            out.append((aLo, bLo))
            aLo += 1
            bLo += 1
        }
        var suffix = 0
        while aLo < aHi, bLo < bHi, a[aHi - 1] == b[bHi - 1] {
            aHi -= 1
            bHi -= 1
            suffix += 1
        }
        if aLo < aHi, bLo < bHi {
            let anchors = depth < 24 ? patienceAnchors(a, b, aLo, aHi, bLo, bHi) : []
            if !anchors.isEmpty {
                var ca = aLo, cb = bLo
                for (x, y) in anchors {
                    diff(a, b, ca, x, cb, y, depth + 1, &out)
                    out.append((x, y))
                    ca = x + 1
                    cb = y + 1
                }
                diff(a, b, ca, aHi, cb, bHi, depth + 1, &out)
            } else if let m = myers(a, b, aLo, aHi, bLo, bHi) {
                out.append(contentsOf: m)
            }
        }
        for k in 0..<suffix {
            out.append((aHi + k, bHi + k))
        }
    }

    private struct Occ {
        var ca = 0, ia = 0, cb = 0, ib = 0
    }

    /// Ancore "patience": elementi unici su entrambi i lati, nella sottosequenza crescente più lunga.
    private static func patienceAnchors(_ a: [Int32], _ b: [Int32], _ aLo: Int, _ aHi: Int, _ bLo: Int, _ bHi: Int) -> [(Int, Int)] {
        var info: [Int32: Occ] = [:]
        info.reserveCapacity(aHi - aLo)
        for i in aLo..<aHi {
            var o = info[a[i]] ?? Occ()
            o.ca += 1
            o.ia = i
            info[a[i]] = o
        }
        for j in bLo..<bHi {
            guard var o = info[b[j]] else { continue }
            o.cb += 1
            o.ib = j
            info[b[j]] = o
        }
        var pairs: [(Int, Int)] = []
        for i in aLo..<aHi {
            if let o = info[a[i]], o.ca == 1, o.cb == 1 { pairs.append((i, o.ib)) }
        }
        if pairs.isEmpty { return [] }
        var tails: [Int] = []
        var prev = [Int](repeating: -1, count: pairs.count)
        for (idx, p) in pairs.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if pairs[tails[mid]].1 < p.1 { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { prev[idx] = tails[lo - 1] }
            if lo == tails.count { tails.append(idx) } else { tails[lo] = idx }
        }
        var res: [(Int, Int)] = []
        var cur = tails.last ?? -1
        while cur >= 0 {
            res.append(pairs[cur])
            cur = prev[cur]
        }
        return res.reversed()
    }

    /// Myers O(ND) con traccia. Ritorna nil se la distanza supera maxD.
    private static func myers(_ a: [Int32], _ b: [Int32], _ aLo: Int, _ aHi: Int, _ bLo: Int, _ bHi: Int,
                              maxD: Int = 3000) -> [(Int, Int)]? {
        let n = aHi - aLo, m = bHi - bLo
        let maxv = min(n + m, maxD)
        let off = maxv + 1
        var v = [Int32](repeating: 0, count: 2 * maxv + 3)
        var trace: [[Int32]] = []
        var found = -1
        outer: for d in 0...maxv {
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[off + k - 1] < v[off + k + 1]) {
                    x = Int(v[off + k + 1])
                } else {
                    x = Int(v[off + k - 1]) + 1
                }
                var y = x - k
                while x < n, y < m, a[aLo + x] == b[bLo + y] {
                    x += 1
                    y += 1
                }
                v[off + k] = Int32(x)
                if x >= n, y >= m {
                    found = d
                    break outer
                }
                k += 2
            }
            trace.append(Array(v[(off - d)...(off + d)]))
        }
        guard found >= 0 else { return nil }
        var res: [(Int, Int)] = []
        var x = n, y = m
        var d = found
        while d > 0 {
            let t = trace[d - 1]
            let o = d - 1
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && t[o + k - 1] < t[o + k + 1]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let px = Int(t[o + prevK])
            let py = px - prevK
            while x > px, y > py {
                x -= 1
                y -= 1
                res.append((aLo + x, bLo + y))
            }
            x = px
            y = py
            d -= 1
        }
        while x > 0, y > 0 {
            x -= 1
            y -= 1
            res.append((aLo + x, bLo + y))
        }
        return res.reversed()
    }
}

// MARK: - Autotest (BeyondClone --selftest)

enum SelfTest {
    static func run() {
        var failures = 0
        func check(_ cond: Bool, _ msg: String) {
            if !cond {
                failures += 1
                print("FAIL: \(msg)")
            }
        }
        func lcs(_ a: [Int], _ b: [Int]) -> Int {
            var dp = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
            for i in 0..<a.count {
                for j in 0..<b.count {
                    dp[i + 1][j + 1] = a[i] == b[j] ? dp[i][j] + 1 : max(dp[i][j + 1], dp[i + 1][j])
                }
            }
            return dp[a.count][b.count]
        }
        func valid(_ m: [(Int, Int)], _ a: [Int], _ b: [Int]) -> Bool {
            var pi = -1, pj = -1
            for (i, j) in m {
                if i <= pi || j <= pj || i >= a.count || j >= b.count || a[i] != b[j] { return false }
                pi = i
                pj = j
            }
            return true
        }
        var rng = SystemRandomNumberGenerator()
        for round in 0..<3000 {
            let alphabet = [2, 4, 20][round % 3]
            let a = (0..<Int.random(in: 0...40, using: &rng)).map { _ in Int.random(in: 0..<alphabet, using: &rng) }
            let b = (0..<Int.random(in: 0...40, using: &rng)).map { _ in Int.random(in: 0..<alphabet, using: &rng) }
            let exact = DiffEngine.matches(a, b, patience: false)
            check(valid(exact, a, b), "myers non valido \(a) \(b)")
            check(exact.count == lcs(a, b), "myers non ottimo \(a) \(b)")
            let pat = DiffEngine.matches(a, b, patience: true)
            check(valid(pat, a, b), "patience non valido \(a) \(b)")

            let l = a.map(String.init), r = b.map(String.init)
            let rows = DiffEngine.rows(left: l, right: r)
            check(rows.compactMap(\.left) == l, "ricostruzione sinistra")
            check(rows.compactMap(\.right) == r, "ricostruzione destra")
            for row in rows where row.kind == .equal {
                check(row.left == row.right, "riga uguale con testi diversi")
            }
        }
        let rows = DiffEngine.rows(left: ["a", "b", "c", "d"], right: ["a", "x", "c", "d", "e"])
        check(rows.map(\.kind) == [.equal, .changed, .equal, .equal, .rightOnly], "caso base: \(rows.map(\.kind))")
        let opt = DiffEngine.rows(left: ["Foo  Bar"], right: ["foo bar"], options: CompareOptions(ignoreWhitespace: true, ignoreCase: true))
        check(opt.map(\.kind) == [.equal], "opzioni ignora")
        let inl = DiffEngine.inline("let value = 10", "let value = 20")
        check(inl.left.filter(\.changed).map(\.text) == ["1"], "inline: \(inl.left)")

        // File grande: 60k righe con modifiche sparse.
        var big1 = (0..<60000).map { "riga numero \($0)" }
        var big2 = big1
        for i in stride(from: 100, to: 60000, by: 997) { big2[i] = "modificata \(i)" }
        big2.removeSubrange(30000..<30050)
        big1.insert(contentsOf: ["x", "y", "z"], at: 5)
        let t0 = Date()
        let bigRows = DiffEngine.rows(left: big1, right: big2)
        let dt = Date().timeIntervalSince(t0)
        check(bigRows.compactMap(\.left) == big1 && bigRows.compactMap(\.right) == big2, "ricostruzione file grande")
        print(String(format: "file grande: %d righe in %.3fs", bigRows.count, dt))
        failures += SyncSelfTest.run()
        print(failures == 0 ? "SELFTEST OK" : "SELFTEST FALLITO (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }
}
