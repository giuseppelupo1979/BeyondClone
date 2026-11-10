namespace BeyondClone.Core;

public enum RowKind { Equal, Changed, LeftOnly, RightOnly }

public sealed class DiffRow
{
    public RowKind Kind;
    public string? Left, Right;
    public int? LeftNo, RightNo;
}

public sealed record DiffOptions(bool IgnoreWhitespace = false, bool IgnoreCase = false);

public readonly record struct Segment(string Text, bool Changed);

/// <summary>Diff riga per riga (ancore "patience" + Myers) e diff dentro la riga.</summary>
public static class TextDiff
{
    /// <summary>Coppie (indice in a, indice in b) di elementi abbinati, in ordine crescente.</summary>
    public static List<(int A, int B)> Matches<T>(IReadOnlyList<T> a, IReadOnlyList<T> b, bool patience = true) where T : notnull
    {
        var table = new Dictionary<T, int>(a.Count + b.Count);
        int Intern(T x)
        {
            if (table.TryGetValue(x, out var v)) return v;
            v = table.Count;
            table[x] = v;
            return v;
        }
        var ia = new int[a.Count];
        var ib = new int[b.Count];
        for (int i = 0; i < a.Count; i++) ia[i] = Intern(a[i]);
        for (int i = 0; i < b.Count; i++) ib[i] = Intern(b[i]);
        var outList = new List<(int, int)>(Math.Min(a.Count, b.Count));
        Diff(ia, ib, 0, ia.Length, 0, ib.Length, patience ? 0 : int.MaxValue, outList);
        return outList;
    }

    public static List<DiffRow> Rows(IReadOnlyList<string> left, IReadOnlyList<string> right, DiffOptions? options = null)
    {
        var o = options ?? new DiffOptions();
        var m = o == new DiffOptions()
            ? Matches(left, right)
            : Matches(left.Select(s => Key(s, o)).ToList(), right.Select(s => Key(s, o)).ToList());
        var rows = new List<DiffRow>(Math.Max(left.Count, right.Count));
        int i = 0, j = 0;
        void Gap(int ai, int bj)
        {
            int common = Math.Min(ai - i, bj - j);
            for (int k = 0; k < common; k++)
                rows.Add(new DiffRow { Kind = RowKind.Changed, Left = left[i + k], Right = right[j + k], LeftNo = i + k + 1, RightNo = j + k + 1 });
            i += common; j += common;
            for (; i < ai; i++) rows.Add(new DiffRow { Kind = RowKind.LeftOnly, Left = left[i], LeftNo = i + 1 });
            for (; j < bj; j++) rows.Add(new DiffRow { Kind = RowKind.RightOnly, Right = right[j], RightNo = j + 1 });
        }
        foreach (var (ai, bj) in m)
        {
            Gap(ai, bj);
            rows.Add(new DiffRow { Kind = RowKind.Equal, Left = left[ai], Right = right[bj], LeftNo = ai + 1, RightNo = bj + 1 });
            i = ai + 1; j = bj + 1;
        }
        Gap(left.Count, right.Count);
        return rows;
    }

    /// <summary>Differenze a livello di carattere tra due righe.</summary>
    public static (List<Segment> Left, List<Segment> Right) Inline(string l, string r)
    {
        if (l.Length > 2000 || r.Length > 2000 || l.Length == 0 || r.Length == 0)
            return ([new Segment(l, true)], [new Segment(r, true)]);
        var a = l.ToCharArray();
        var b = r.ToCharArray();
        var m = Matches(a, b, patience: false);
        if (m.Count * 4 < Math.Max(a.Length, b.Length)) return ([new Segment(l, true)], [new Segment(r, true)]);
        var ma = Enumerable.Repeat(true, a.Length).ToArray();
        var mb = Enumerable.Repeat(true, b.Length).ToArray();
        foreach (var (x, y) in m) { ma[x] = false; mb[y] = false; }
        return (Segments(a, ma), Segments(b, mb));
    }

    static string Key(string s, DiffOptions o)
    {
        if (o.IgnoreWhitespace) s = string.Concat(s.Where(c => !char.IsWhiteSpace(c)));
        if (o.IgnoreCase) s = s.ToLowerInvariant();
        return s;
    }

    static List<Segment> Segments(char[] chars, bool[] mask)
    {
        var res = new List<Segment>();
        int start = 0;
        while (start < chars.Length)
        {
            int end = start + 1;
            while (end < chars.Length && mask[end] == mask[start]) end++;
            res.Add(new Segment(new string(chars, start, end - start), mask[start]));
            start = end;
        }
        return res;
    }

    static void Diff(int[] a, int[] b, int aLo, int aHi, int bLo, int bHi, int depth, List<(int, int)> outList)
    {
        while (aLo < aHi && bLo < bHi && a[aLo] == b[bLo]) { outList.Add((aLo, bLo)); aLo++; bLo++; }
        int suffix = 0;
        while (aLo < aHi && bLo < bHi && a[aHi - 1] == b[bHi - 1]) { aHi--; bHi--; suffix++; }
        if (aLo < aHi && bLo < bHi)
        {
            var anchors = depth < 24 ? PatienceAnchors(a, b, aLo, aHi, bLo, bHi) : [];
            if (anchors.Count > 0)
            {
                int ca = aLo, cb = bLo;
                foreach (var (x, y) in anchors)
                {
                    Diff(a, b, ca, x, cb, y, depth + 1, outList);
                    outList.Add((x, y));
                    ca = x + 1; cb = y + 1;
                }
                Diff(a, b, ca, aHi, cb, bHi, depth + 1, outList);
            }
            else if (Myers(a, b, aLo, aHi, bLo, bHi) is { } m) outList.AddRange(m);
        }
        for (int k = 0; k < suffix; k++) outList.Add((aHi + k, bHi + k));
    }

    /// <summary>Elementi unici su entrambi i lati, nella sottosequenza crescente più lunga.</summary>
    static List<(int, int)> PatienceAnchors(int[] a, int[] b, int aLo, int aHi, int bLo, int bHi)
    {
        var info = new Dictionary<int, (int ca, int ia, int cb, int ib)>();
        for (int i = aLo; i < aHi; i++)
        {
            info.TryGetValue(a[i], out var o);
            o.ca++; o.ia = i;
            info[a[i]] = o;
        }
        for (int j = bLo; j < bHi; j++)
        {
            if (!info.TryGetValue(b[j], out var o)) continue;
            o.cb++; o.ib = j;
            info[b[j]] = o;
        }
        var pairs = new List<(int, int)>();
        for (int i = aLo; i < aHi; i++)
            if (info.TryGetValue(a[i], out var o) && o.ca == 1 && o.cb == 1) pairs.Add((i, o.ib));
        if (pairs.Count == 0) return [];
        var tails = new List<int>();
        var prev = new int[pairs.Count];
        for (int idx = 0; idx < pairs.Count; idx++)
        {
            int lo = 0, hi = tails.Count;
            while (lo < hi)
            {
                int mid = (lo + hi) / 2;
                if (pairs[tails[mid]].Item2 < pairs[idx].Item2) lo = mid + 1; else hi = mid;
            }
            prev[idx] = lo > 0 ? tails[lo - 1] : -1;
            if (lo == tails.Count) tails.Add(idx); else tails[lo] = idx;
        }
        var res = new List<(int, int)>();
        for (int cur = tails[^1]; cur >= 0; cur = prev[cur]) res.Add(pairs[cur]);
        res.Reverse();
        return res;
    }

    /// <summary>Myers O(ND) con traccia. Null se la distanza supera maxD.</summary>
    static List<(int, int)>? Myers(int[] a, int[] b, int aLo, int aHi, int bLo, int bHi, int maxD = 3000)
    {
        int n = aHi - aLo, m = bHi - bLo;
        int maxv = Math.Min(n + m, maxD);
        int off = maxv + 1;
        var v = new int[2 * maxv + 3];
        var trace = new List<int[]>();
        int found = -1;
        for (int d = 0; d <= maxv && found < 0; d++)
        {
            for (int k = -d; k <= d; k += 2)
            {
                int x = (k == -d || (k != d && v[off + k - 1] < v[off + k + 1])) ? v[off + k + 1] : v[off + k - 1] + 1;
                int y = x - k;
                while (x < n && y < m && a[aLo + x] == b[bLo + y]) { x++; y++; }
                v[off + k] = x;
                if (x >= n && y >= m) { found = d; break; }
            }
            if (found < 0) trace.Add(v[(off - d)..(off + d + 1)]);
        }
        if (found < 0) return null;
        var res = new List<(int, int)>();
        int px2 = n, py2 = m;
        for (int d = found; d > 0; d--)
        {
            var t = trace[d - 1];
            int o = d - 1;
            int k = px2 - py2;
            int prevK = (k == -d || (k != d && t[o + k - 1] < t[o + k + 1])) ? k + 1 : k - 1;
            int px = t[o + prevK];
            int py = px - prevK;
            while (px2 > px && py2 > py) { px2--; py2--; res.Add((aLo + px2, bLo + py2)); }
            px2 = px; py2 = py;
        }
        while (px2 > 0 && py2 > 0) { px2--; py2--; res.Add((aLo + px2, bLo + py2)); }
        res.Reverse();
        return res;
    }
}
