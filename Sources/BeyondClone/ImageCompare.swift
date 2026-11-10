import SwiftUI
import AppKit
import CoreImage

enum ImageMode: String, CaseIterable, Identifiable {
    case side = "Affiancate"
    case difference = "Differenza"
    case overlay = "Sovrapposte"
    var id: String { rawValue }
}

@MainActor
final class ImageCompareModel: ObservableObject {
    @Published var leftURL: URL?
    @Published var rightURL: URL?
    @Published private(set) var leftImage: NSImage?
    @Published private(set) var rightImage: NSImage?
    @Published private(set) var diffImage: NSImage?
    @Published private(set) var summary = ""
    @Published private(set) var identical: Bool?
    @Published private(set) var busy = false
    @Published var tolerance: Double = 0 { didSet { if tolerance != oldValue { reload() } } }

    private var generation = 0

    init(left: URL?, right: URL?) {
        leftURL = left
        rightURL = right
        reload()
    }

    var title: String { "\(leftURL?.lastPathComponent ?? "—") ↔ \(rightURL?.lastPathComponent ?? "—")" }

    func set(_ url: URL, side: Side) {
        if side == .left { leftURL = url } else { rightURL = url }
        reload()
    }

    nonisolated private static func load(_ url: URL?) -> CGImage? {
        guard let url, let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    nonisolated private static func pixels(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }

    /// Mappa delle differenze: pixel diversi in rosso su immagine sinistra attenuata.
    nonisolated private static func diff(_ l: CGImage, _ r: CGImage, tolerance: Int) -> (image: CGImage?, changed: Int, total: Int)? {
        guard l.width == r.width, l.height == r.height, l.width * l.height <= 80_000_000,
              let a = pixels(l), let b = pixels(r) else { return nil }
        let w = l.width, h = l.height
        var out = [UInt8](repeating: 255, count: w * h * 4)
        var changed = 0
        for p in 0..<(w * h) {
            let i = p * 4
            let d = max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])),
                        abs(Int(a[i + 2]) - Int(b[i + 2])), abs(Int(a[i + 3]) - Int(b[i + 3])))
            if d > tolerance {
                changed += 1
                out[i] = 255
                out[i + 1] = 30
                out[i + 2] = 60
            } else {
                let gray = UInt8((Int(a[i]) * 3 + Int(a[i + 1]) * 6 + Int(a[i + 2])) / 10)
                let faded = UInt8(160 + Int(gray) * 95 / 255)
                out[i] = faded
                out[i + 1] = faded
                out[i + 2] = faded
            }
        }
        let image = out.withUnsafeMutableBytes { ptr -> CGImage? in
            CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
        return (image, changed, w * h)
    }

    func reload() {
        generation += 1
        let gen = generation
        let l = leftURL, r = rightURL, tol = Int(tolerance)
        busy = true
        Task.detached(priority: .userInitiated) {
            let li = Self.load(l), ri = Self.load(r)
            var summary = ""
            var diffImage: CGImage?
            var identical: Bool?
            if let li, let ri {
                if let d = Self.diff(li, ri, tolerance: tol) {
                    diffImage = d.image
                    identical = d.changed == 0
                    let pct = Double(d.changed) / Double(max(d.total, 1)) * 100
                    summary = d.changed == 0
                        ? "Immagini identiche (\(li.width)×\(li.height))"
                        : String(format: "%d pixel diversi su %d (%.2f%%)", d.changed, d.total, pct)
                } else {
                    identical = false
                    summary = "Dimensioni diverse: \(li.width)×\(li.height) e \(ri.width)×\(ri.height)"
                }
            }
            let result = (li, ri, diffImage, summary, identical)
            await MainActor.run {
                guard gen == self.generation else { return }
                self.leftImage = result.0.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                self.rightImage = result.1.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                self.diffImage = result.2.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                self.summary = result.3
                self.identical = result.4
                self.busy = false
            }
        }
    }
}

struct ImageCompareView: View {
    @StateObject private var model: ImageCompareModel
    @Local private var mode: ImageMode = .side
    @Local private var opacity = 0.5

    init(left: URL?, right: URL?) {
        _model = StateObject(wrappedValue: ImageCompareModel(left: left, right: right))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PathField(url: model.leftURL) { model.set($0, side: .left) }
                Divider()
                PathField(url: model.rightURL) { model.set($0, side: .right) }
            }
            .frame(height: 30)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            HStack(spacing: 14) {
                if model.busy {
                    ProgressView().controlSize(.small)
                } else if let same = model.identical {
                    Label(model.summary, systemImage: same ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(same ? .green : .red)
                }
                Spacer()
                if mode == .overlay {
                    Text("Sinistra")
                    Slider(value: $opacity).frame(width: 180)
                    Text("Destra")
                }
                Text("Tolleranza: \(Int(model.tolerance))")
                Slider(value: $model.tolerance, in: 0...64, step: 1).frame(width: 140)
                    .help("Differenza per canale (0–255) sotto la quale due pixel contano come uguali")
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .frame(height: 28)
        }
        .navigationTitle(model.title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Vista", selection: $mode) {
                    ForEach(ImageMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Affiancate, mappa delle differenze in rosso, oppure sovrapposte con trasparenza")
            }
            ToolbarItem {
                Button { model.reload() } label: { Label("Ricarica", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Ricarica dal disco (⌘R)")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .side:
            HStack(spacing: 1) {
                pane(model.leftImage)
                pane(model.rightImage)
            }
        case .difference:
            if let d = model.diffImage {
                pane(d)
            } else {
                Text(model.leftImage == nil || model.rightImage == nil
                     ? "Scegli due immagini"
                     : "La mappa delle differenze richiede immagini delle stesse dimensioni")
                    .foregroundStyle(.secondary)
            }
        case .overlay:
            ZStack {
                pane(model.leftImage)
                pane(model.rightImage).opacity(opacity)
            }
        }
    }

    @ViewBuilder
    private func pane(_ image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Nessuna immagine")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
