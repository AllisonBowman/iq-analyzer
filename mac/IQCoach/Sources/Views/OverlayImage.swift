import SwiftUI

/// What to draw over a photo.
enum PhotoOverlay: Hashable, Sendable {
    case none, clipping, focusMap, subject
    /// A line through the centre at the given tilt in degrees (positive: right end lower).
    case horizon(Double)

    static let pickable: [PhotoOverlay] = [.none, .clipping, .focusMap, .subject]

    var title: String {
        switch self {
        case .none: "None"
        case .clipping: "Clipping"
        case .focusMap: "Focus map"
        case .subject: "Subject"
        case .horizon: "Horizon"
        }
    }
}

/// One photo with an optional overlay. Used large on the photo screen and at 96 pt on the editing-advice cards.
struct OverlayImage: View {
    let path: String?
    var overlay: PhotoOverlay = .none
    let photo: PhotoRecord
    var salientBox: CGRect?
    /// nil: fit the column width, up to `maxHeight`. Otherwise a square box of this size with the picture fitted inside.
    var boxSize: CGFloat?
    var maxHeight: CGFloat = 420

    @State private var image: CGImage?
    @State private var mask: ClippingMask?
    @Environment(\.isSnapshot) private var isSnapshot

    static let loadPixel = 800

    private var shownImage: CGImage? {
        guard let path else { return nil }
        if isSnapshot { return ThumbnailStore.loadSynchronously(path: path, maxPixel: Self.loadPixel) }
        return image ?? ThumbnailStore.cached(path: path, maxPixel: Self.loadPixel)
    }

    private var shownMask: ClippingMask? {
        if isSnapshot, let img = shownImage { return ClippingMask.make(from: img) }
        return mask
    }

    var body: some View {
        Group {
            if let img = shownImage {
                Image(decorative: img, scale: 1)
                    .resizable().scaledToFit()
                    .overlay { overlayLayer }
                    .clipShape(RoundedRectangle(cornerRadius: boxSize == nil ? 8 : 6, style: .continuous))
                    .frame(maxWidth: boxSize ?? .infinity, maxHeight: boxSize ?? maxHeight)
            } else {
                placeholder
            }
        }
        .frame(width: boxSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isImage)
        .task(id: path) {
            guard !isSnapshot else { return }
            image = nil; mask = nil
            guard let path else { return }
            if let hit = ThumbnailStore.cached(path: path, maxPixel: Self.loadPixel) { image = hit; return }
            let img = await ThumbnailStore.shared.image(path: path, maxPixel: Self.loadPixel)
            if !Task.isCancelled { image = img }
        }
        .task(id: "\(path ?? "")|\(overlay == .clipping)|\(image != nil)") {
            guard !isSnapshot, overlay == .clipping, let path, let img = image else { return }
            let m = await ClippingMaskStore.shared.mask(path: path, source: img)
            if !Task.isCancelled { mask = m }
        }
    }

    private var accessibilityText: String {
        let base = "Photo \(photo.file)"
        return overlay == .none ? base : "\(base) with \(overlay.title.lowercased()) overlay"
    }

    private var placeholder: some View {
        let s = boxSize ?? 160
        return ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.15))
            VStack(spacing: 6) {
                Image(systemName: "photo").font(boxSize == nil ? .largeTitle : .title3).foregroundStyle(.secondary)
                if boxSize == nil {
                    Text(photo.path == nil ? "No file path in these results"
                         : (FileManager.default.fileExists(atPath: photo.path ?? "") ? "Loading preview…" : "File not found at its recorded path"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: boxSize ?? .infinity, minHeight: s, maxHeight: boxSize ?? s)
    }

    @ViewBuilder private var overlayLayer: some View {
        switch overlay {
        case .none:
            EmptyView()
        case .clipping:
            if let m = shownMask {
                Image(decorative: m.image, scale: 1).resizable().interpolation(.none).opacity(0.5)
            }
        case .focusMap:
            FocusOverlay(map: photo.structureFocusMap, cx: photo.structureFocusCX, cy: photo.structureFocusCY)
        case .subject:
            SubjectOverlay(salientBox: salientBox, thick: boxSize == nil)
        case .horizon(let deg):
            HorizonOverlay(degrees: deg, thick: boxSize == nil)
        }
    }

    /// The caption that goes under a large image for each overlay; nil when there is nothing to say.
    static func caption(for overlay: PhotoOverlay, photo p: PhotoRecord, hasSalientBox: Bool) -> String? {
        switch overlay {
        case .none:
            return nil
        case .clipping:
            guard p.clipHighPct != nil || p.clipLowPct != nil else { return "Clipping was not measured for this photo." }
            return "Red: blown highlights (\(Fmt.pct(p.clipHighPct ?? 0, 2)) of pixels). Blue: crushed shadows (\(Fmt.pct(p.clipLowPct ?? 0, 2)))."
        case .focusMap:
            return Structure.focusCaption(p) ?? "Focus map needs a results file from iqa 0.2 or later."
        case .subject:
            var s = hasSalientBox ? "Salient subject (Vision) and the rule-of-thirds grid" : "The rule-of-thirds grid (the salient subject appears once Vision has read the photo)"
            if let d = p.structureThirdsDistance { s += "; thirds distance \(Fmt.num(d, 2))" }
            return s
        case .horizon(let deg):
            return "The line shows the tilt found in this photo: \(Fmt.num(abs(deg), 1))°."
        }
    }
}

private struct FocusOverlay: View {
    let map: [[Double]]?
    let cx: Double?
    let cy: Double?

    var body: some View {
        Canvas { ctx, size in
            if let map, let cols = map.first?.count, !map.isEmpty, cols > 0 {
                let rows = map.count
                let cw = size.width / CGFloat(cols), ch = size.height / CGFloat(rows)
                for r in 0..<rows {
                    for c in 0..<min(cols, map[r].count) {
                        let v = min(max(map[r][c], 0), 1)
                        let rect = CGRect(x: CGFloat(c) * cw, y: CGFloat(r) * ch, width: cw, height: ch)
                        ctx.fill(Path(rect), with: .color(.blue.opacity(v * 0.6)))
                    }
                }
            }
            if let cx, let cy {
                let d: CGFloat = max(10, min(size.width, size.height) * 0.06)
                let rect = CGRect(x: cx * size.width - d / 2, y: cy * size.height - d / 2, width: d, height: d)
                ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -1, dy: -1)), with: .color(.black.opacity(0.6)), lineWidth: 3)
                ctx.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct SubjectOverlay: View {
    let salientBox: CGRect?
    let thick: Bool

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let line = Color.white.opacity(0.3)
            for f in [1.0 / 3, 2.0 / 3] {
                var v = Path(); v.move(to: CGPoint(x: f * w, y: 0)); v.addLine(to: CGPoint(x: f * w, y: h))
                var hz = Path(); hz.move(to: CGPoint(x: 0, y: f * h)); hz.addLine(to: CGPoint(x: w, y: f * h))
                ctx.stroke(v, with: .color(line), lineWidth: 1)
                ctx.stroke(hz, with: .color(line), lineWidth: 1)
            }
            let r: CGFloat = thick ? 4 : 2
            for fx in [1.0 / 3, 2.0 / 3] {
                for fy in [1.0 / 3, 2.0 / 3] {
                    ctx.fill(Path(ellipseIn: CGRect(x: fx * w - r, y: fy * h - r, width: 2 * r, height: 2 * r)), with: .color(.white.opacity(0.85)))
                }
            }
            if let b = salientBox {
                let rect = CGRect(x: b.minX * w, y: b.minY * h, width: b.width * w, height: b.height * h)
                let p = Path(roundedRect: rect, cornerRadius: 6)
                ctx.stroke(p, with: .color(.black.opacity(0.5)), lineWidth: thick ? 4 : 3)
                ctx.stroke(p, with: .color(.yellow), lineWidth: thick ? 2 : 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct HorizonOverlay: View {
    let degrees: Double
    let thick: Bool

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let mid = CGPoint(x: w / 2, y: h / 2)
            var level = Path(); level.move(to: CGPoint(x: 0, y: mid.y)); level.addLine(to: CGPoint(x: w, y: mid.y))
            ctx.stroke(level, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            // Positive tilt: the right end is lower, which is larger y on screen.
            let dy = tan(degrees * .pi / 180) * (w / 2)
            var tilt = Path(); tilt.move(to: CGPoint(x: 0, y: mid.y - dy)); tilt.addLine(to: CGPoint(x: w, y: mid.y + dy))
            ctx.stroke(tilt, with: .color(.black.opacity(0.5)), lineWidth: thick ? 4 : 3)
            ctx.stroke(tilt, with: .color(.yellow), lineWidth: thick ? 2 : 1.5)
        }
        .allowsHitTesting(false)
    }
}

/// Segmented overlay chooser; a row of capsules in PNG snapshots, where AppKit controls cannot draw.
struct OverlayPicker: View {
    @Binding var selection: PhotoOverlay
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            HStack(spacing: 8) {
                ForEach(PhotoOverlay.pickable, id: \.self) { o in
                    Text(o.title).font(.callout.weight(o == selection ? .semibold : .regular))
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(o == selection ? AnyShapeStyle(.selection) : AnyShapeStyle(.fill.quaternary), in: Capsule())
                }
            }
        } else {
            Picker("Overlay", selection: $selection) {
                ForEach(PhotoOverlay.pickable, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Picture overlay")
        }
    }
}

extension EditingAdvice {
    /// The overlay that shows this advice on the photo; `.none` (the plain picture) when there is no useful one.
    func overlay(for photo: PhotoRecord) -> PhotoOverlay {
        if id.hasPrefix("highlights") || id.hasPrefix("shadows") { return .clipping }
        if id.hasPrefix("shallow") || id.hasPrefix("thirds") { return .focusMap }
        if id.hasPrefix("straighten"), let t = photo.structureHorizonTiltDeg { return .horizon(t) }
        return .none
    }
}
