using System.Diagnostics;
using BeyondClone.Core;

// Autotest del motore di BeyondClone per Windows. Esce con codice 0 se tutto passa.
int failures = 0;
void Check(bool cond, string msg)
{
    if (!cond) { failures++; Console.WriteLine("FAIL: " + msg); }
}

// ---------- Diff del testo ----------
static int Lcs(int[] a, int[] b)
{
    var dp = new int[a.Length + 1, b.Length + 1];
    for (int i = 0; i < a.Length; i++)
        for (int j = 0; j < b.Length; j++)
            dp[i + 1, j + 1] = a[i] == b[j] ? dp[i, j] + 1 : Math.Max(dp[i, j + 1], dp[i + 1, j]);
    return dp[a.Length, b.Length];
}
static bool Valid(List<(int A, int B)> m, int[] a, int[] b)
{
    int pi = -1, pj = -1;
    foreach (var (i, j) in m)
    {
        if (i <= pi || j <= pj || i >= a.Length || j >= b.Length || a[i] != b[j]) return false;
        pi = i; pj = j;
    }
    return true;
}
var rng = new Random(7);
for (int round = 0; round < 3000; round++)
{
    int alphabet = new[] { 2, 4, 20 }[round % 3];
    var a = Enumerable.Range(0, rng.Next(0, 41)).Select(_ => rng.Next(alphabet)).ToArray();
    var b = Enumerable.Range(0, rng.Next(0, 41)).Select(_ => rng.Next(alphabet)).ToArray();
    var exact = TextDiff.Matches(a, b, patience: false);
    Check(Valid(exact, a, b), "myers non valido");
    Check(exact.Count == Lcs(a, b), $"myers non ottimo [{string.Join(",", a)}] [{string.Join(",", b)}]");
    Check(Valid(TextDiff.Matches(a, b), a, b), "patience non valido");
    var l = a.Select(x => x.ToString()).ToList();
    var r = b.Select(x => x.ToString()).ToList();
    var rows = TextDiff.Rows(l, r);
    Check(rows.Where(x => x.Left != null).Select(x => x.Left!).SequenceEqual(l), "ricostruzione sinistra");
    Check(rows.Where(x => x.Right != null).Select(x => x.Right!).SequenceEqual(r), "ricostruzione destra");
}
var basic = TextDiff.Rows(["a", "b", "c", "d"], ["a", "x", "c", "d", "e"]);
Check(basic.Select(x => x.Kind).SequenceEqual([RowKind.Equal, RowKind.Changed, RowKind.Equal, RowKind.Equal, RowKind.RightOnly]), "caso base");
Check(TextDiff.Rows(["Foo  Bar"], ["foo bar"], new DiffOptions(true, true)).Single().Kind == RowKind.Equal, "opzioni ignora");
Check(TextDiff.Inline("let value = 10", "let value = 20").Left.Where(s => s.Changed).Select(s => s.Text).SequenceEqual(["1"]), "diff in riga");
var big1 = Enumerable.Range(0, 60000).Select(i => $"riga numero {i}").ToList();
var big2 = big1.ToList();
for (int i = 100; i < 60000; i += 997) big2[i] = $"modificata {i}";
big2.RemoveRange(30000, 50);
big1.InsertRange(5, ["x", "y", "z"]);
var sw = Stopwatch.StartNew();
var bigRows = TextDiff.Rows(big1, big2);
Console.WriteLine($"file grande: {bigRows.Count} righe in {sw.Elapsed.TotalSeconds:0.000}s");
Check(bigRows.Where(x => x.Left != null).Select(x => x.Left!).SequenceEqual(big1), "ricostruzione file grande");

// ---------- Motore cartelle ----------
var baseDir = Path.Combine(Path.GetTempPath(), "bc-selftest-" + Guid.NewGuid().ToString("N"));
var A = Path.Combine(baseDir, "A");
var B = Path.Combine(baseDir, "B");
void Write(string root, string rel, string text, double age = 0)
{
    var p = Path.Combine(root, rel);
    Directory.CreateDirectory(Path.GetDirectoryName(p)!);
    File.WriteAllText(p, text);
    File.SetLastWriteTimeUtc(p, DateTime.UtcNow.AddSeconds(-age));
}
string? Read(string root, string rel) { var p = Path.Combine(root, rel); return File.Exists(p) ? File.ReadAllText(p) : null; }
void Setup()
{
    if (Directory.Exists(baseDir)) Directory.Delete(baseDir, true);
    Write(A, "uguale.txt", "x", 10000); Write(B, "uguale.txt", "x", 10000);
    Write(A, "nuovo_a_sinistra.txt", "nuovo", 10);
    Write(A, @"sub\piu_recente.txt", "recente", 10); Write(B, @"sub\piu_recente.txt", "vecchio!", 50000);
    Write(B, "piu_recente_a_destra.txt", "destra", 10); Write(A, "piu_recente_a_destra.txt", "sinistra vecchio", 50000);
    Write(B, @"solo_destra\extra.txt", "extra", 10);
    Write(A, @"profonda\a\b\c\d.txt", new string('z', 300_000), 10);
    Write(A, "desktop.ini", "junk");
    Write(A, "ora_legale.txt", "h", 20000); Write(B, "ora_legale.txt", "h", 20000 + 3600);
}
var opts = new DirOptions { Excludes = "desktop.ini" };
var roots = new Roots(A, B);
FolderNode Scan() => Tree.ScanSync(A, B, opts);
SyncResult Exec(SyncPlan plan, DeleteMode mode) =>
    new SyncExecutor(plan, mode, 3, CancellationToken.None, null, _ => { }).RunAsync().GetAwaiter().GetResult();

try
{
    Setup();
    var root = Scan();
    Check(root.Complete, "radice non completata");
    Check(root.Tally.LeftOnly == 2, $"orfani sinistra: {root.Tally.LeftOnly}");
    Check(root.Tally.RightOnly == 1, $"orfani destra: {root.Tally.RightOnly}");
    Check(root.Tally.Changed == 2, $"modificati: {root.Tally.Changed}");
    Check(root.Tally.Same == 2, $"uguali (con ora legale): {root.Tally.Same}");

    var res = Exec(Planner.Plan(SyncMode.MirrorRight, root, roots), DeleteMode.Archive);
    Check(res.Errors.Count == 0, "mirror errori: " + string.Join("; ", res.Errors));
    root = Scan();
    Check(root.Status == NodeStatus.Same, "mirror: non allineate");
    Check(Read(B, @"sub\piu_recente.txt") == "recente", "mirror: contenuto");
    Check(Read(B, @"profonda\a\b\c\d.txt")?.Length == 300_000, "mirror: file profondo");
    Check(!Directory.Exists(Path.Combine(B, "solo_destra")), "mirror: extra non eliminato");
    var archived = res.ArchiveFolders.FirstOrDefault() ?? "";
    Check(File.Exists(Path.Combine(archived, @"solo_destra\extra.txt")), "mirror: extra non archiviato");
    Check(File.Exists(Path.Combine(archived, @"sub\piu_recente.txt")), "mirror: sovrascritto non archiviato");
    Check(!File.Exists(Path.Combine(B, "desktop.ini")), "mirror: escluso copiato");
    Check(Planner.Plan(SyncMode.MirrorRight, root, roots).IsEmpty, "mirror: secondo passaggio non vuoto");
    Check(!Directory.EnumerateFiles(B, "*" + DirLister.PartSuffix, SearchOption.AllDirectories).Any(), "file temporanei rimasti");

    Setup();
    Exec(Planner.Plan(SyncMode.UpdateRight, Scan(), roots), DeleteMode.Archive);
    Check(Read(B, "nuovo_a_sinistra.txt") == "nuovo", "update: nuovo non copiato");
    Check(Read(B, @"solo_destra\extra.txt") == "extra", "update: extra eliminato");
    Check(Read(B, "piu_recente_a_destra.txt") == "destra", "update: sovrascritto il più recente");

    Setup();
    res = Exec(Planner.Plan(SyncMode.UpdateBoth, Scan(), roots), DeleteMode.Permanent);
    Check(res.Errors.Count == 0, "both errori: " + string.Join("; ", res.Errors));
    Check(Scan().Status == NodeStatus.Same, "both: non allineate");
    Check(Read(A, "piu_recente_a_destra.txt") == "destra", "both: verso sinistra");
    Check(Read(A, @"solo_destra\extra.txt") == "extra", "both: orfano destro");
    var da = File.GetLastWriteTimeUtc(Path.Combine(A, "nuovo_a_sinistra.txt"));
    var db = File.GetLastWriteTimeUtc(Path.Combine(B, "nuovo_a_sinistra.txt"));
    Check(Math.Abs((da - db).TotalSeconds) < 1, "date non mantenute");

    // Cestino: un file locale va nel Cestino, non resta sul disco.
    Setup();
    res = Exec(Planner.Plan(SyncMode.MirrorRight, Scan(), roots), DeleteMode.RecycleBin);
    Check(res.Errors.Count == 0, "cestino errori: " + string.Join("; ", res.Errors));
    Check(!Directory.Exists(Path.Combine(B, "solo_destra")), "cestino: extra non eliminato");

    // Maiuscole diverse.
    Setup();
    Write(A, @"Foto\IMG.JPG", "1", 10);
    Write(B, @"foto\img.jpg", "1", 10);
    root = Scan();
    var foto = root.Children.FirstOrDefault(c => c.Name.Equals("foto", StringComparison.OrdinalIgnoreCase));
    Check(foto is { IsDirBoth: true, Status: NodeStatus.Same }, "maiuscole: non abbinate");

    try { Tree.ScanSync(A, Path.Combine(baseDir, "manca"), opts); Check(false, "cartella mancante non fallisce"); }
    catch (SyncError) { }

    // Copia con avanzamento e interruzione.
    var bigFile = Path.Combine(baseDir, "grande.bin");
    File.WriteAllBytes(bigFile, new byte[8_000_000]);
    long seen = 0;
    SyncExecutor.CopyFile(bigFile, Path.Combine(baseDir, "copia.bin"), CancellationToken.None, n => seen += n);
    Check(seen == 8_000_000, $"byte riportati: {seen}");
    using var cts = new CancellationTokenSource();
    cts.Cancel();
    try { SyncExecutor.CopyFile(bigFile, Path.Combine(baseDir, "stop.bin"), cts.Token, _ => { }); Check(false, "copia annullata non fallisce"); }
    catch (OperationCanceledException) { }

    // Velocità di analisi su un albero grande.
    var bigA = Path.Combine(baseDir, "bigA");
    for (int y = 0; y < 40; y++)
        for (int d = 0; d < 25; d++)
        {
            var dir = Path.Combine(bigA, $"{2000 + y}", $"cartella {d:00}");
            Directory.CreateDirectory(dir);
            for (int i = 0; i < 20; i++) File.WriteAllText(Path.Combine(dir, $"IMG_{i:0000}.jpg"), "x");
        }
    sw.Restart();
    var bigRoot = Tree.ScanSync(bigA, bigA, opts);
    Console.WriteLine($"analisi: {bigRoot.Tally.LeftFiles} file per lato in {sw.Elapsed.TotalSeconds:0.00}s (sequenziale)");
    Check(bigRoot.Status == NodeStatus.Same, "albero grande non uguale a se stesso");
}
finally
{
    try { Directory.Delete(baseDir, true); } catch { }
}

Console.WriteLine(failures == 0 ? "SELFTEST OK" : $"SELFTEST FALLITO ({failures})");
return failures == 0 ? 0 : 1;
