import SwiftUI

/// An ⓘ button whose popover holds a title and a definition in plain text.
struct TextInfoButton: View {
    let title: String
    let text: String
    @State private var shown = false
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        } else {
            Button { shown.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .help("What is \(title)?")
                .accessibilityLabel("About \(title)")
                .popover(isPresented: $shown, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title).font(.headline)
                        Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .frame(width: 360)
                }
        }
    }
}

/// Loading state of the Vision pass for one photo.
enum ContentState: Sendable {
    case idle, loading, noFile
    case done(ContentSummary)

    var summary: ContentSummary? { if case .done(let s) = self, s.available { return s } else { return nil } }
}

/// "What is in the picture": Vision labels as capsules and a one-line summary.
struct ContentSectionBody: View {
    let state: ContentState
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .noFile:
                Text("No file to analyze").foregroundStyle(.secondary)
            case .idle:
                Text(isSnapshot ? "Identified when the app is running." : "Waiting to identify…").foregroundStyle(.secondary)
            case .loading:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Identifying…").foregroundStyle(.secondary) }
            case .done(let s):
                if !s.available {
                    Label(s.reason ?? "Content could not be identified.", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else {
                    if s.labels.isEmpty {
                        Text("Nothing was identified with enough confidence.").foregroundStyle(.secondary)
                    } else {
                        LabelCapsules(labels: s.labels)
                    }
                    if let line = s.summaryLine {
                        Text(line).font(.callout)
                            .accessibilityLabel("Also found: \(line)")
                    }
                }
            }
            Text("Identified on this Mac by Apple's Vision framework; nothing leaves the computer.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LabelCapsules: View {
    let labels: [ContentLabel]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(labels, id: \.self) { l in
                HStack(spacing: 4) {
                    Text(l.label.replacingOccurrences(of: "_", with: " "))
                    Text(Fmt.share(l.confidence)).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(.fill.tertiary, in: Capsule())
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Wraps its children onto as many lines as the width needs.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(width: bounds.width, subviews: subviews)
        for (i, f) in r.frames.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        var frames: [CGRect] = []
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: s))
            x += s.width + spacing; rowH = max(rowH, s.height); maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowH), frames)
    }
}

/// 4 x 6 focus map; opacity follows the value. The Vision salient box is drawn on top when known.
struct FocusMapView: View {
    let map: [[Double]]
    var aspect: Double = 1.5
    var salientBox: CGRect?
    var maxWidth: CGFloat = 330

    var body: some View {
        Canvas { ctx, size in
            let rows = map.count, cols = map.first?.count ?? 0
            guard rows > 0, cols > 0 else { return }
            let gap: CGFloat = 2
            let cw = size.width / CGFloat(cols), ch = size.height / CGFloat(rows)
            for r in 0..<rows {
                for c in 0..<min(cols, map[r].count) {
                    let v = min(max(map[r][c], 0), 1)
                    let rect = CGRect(x: CGFloat(c) * cw + gap / 2, y: CGFloat(r) * ch + gap / 2, width: cw - gap, height: ch - gap)
                    let path = Path(roundedRect: rect, cornerRadius: 4)
                    ctx.fill(path, with: .color(.accentColor.opacity(0.06 + 0.94 * v)))
                    ctx.stroke(path, with: .color(.secondary.opacity(0.35)), lineWidth: 0.5)
                }
            }
            if let b = salientBox {
                let rect = CGRect(x: b.minX * size.width, y: b.minY * size.height, width: b.width * size.width, height: b.height * size.height)
                ctx.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(.primary), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: maxWidth)
        .accessibilityHidden(true)
    }
}

/// "Structure": focus map with caption, then orientation, horizon, surface and focus-split rows.
struct StructureSectionBody: View {
    let photo: PhotoRecord
    let salientBox: CGRect?

    var body: some View {
        if !photo.hasStructure {
            Label(Structure.missingText, systemImage: "info.circle").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    if let map = photo.structureFocusMap {
                        FocusMapView(map: map, aspect: aspect, salientBox: salientBox, maxWidth: 120)
                            .frame(width: 120)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        if let c = Structure.focusCaption(photo) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(c).fixedSize(horizontal: false, vertical: true)
                                if let f = photo.structureFocusFraction, f < 0.8 { TextInfoButton(title: "Focus fraction", text: Structure.focusFractionDefinition + " " + Structure.focusPositionDefinition + " " + Structure.thirdsDefinition) }
                                else { TextInfoButton(title: "Focus fraction", text: Structure.focusFractionDefinition) }
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if photo.structureFocusMap != nil, salientBox != nil {
                            Text("Dashed box: the most eye-catching object, found by Apple's Vision framework.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let o = Structure.orientation(photo) {
                    rowView("Orientation", o, definition: Structure.orientationDefinition)
                }
                horizonRow
                if let s = Structure.surfaceText(photo) {
                    rowView("Picture surface", s, definition: Structure.surfaceDefinition)
                }
                if let sp = Structure.splitText(photo) {
                    rowView("In-focus and background", sp, definition: Structure.splitDefinition)
                }
            }
        }
    }

    private var aspect: Double {
        if let w = photo.width, let h = photo.height, w > 0, h > 0 { return Double(w) / Double(h) }
        return 1.5
    }

    private var horizonRow: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(Structure.horizonText(photo)).monospacedDigit()
                if let t = photo.structureHorizonTiltDeg { BandCapsule(band: Structure.horizonBand(t)) }
                TextInfoButton(title: "Horizon tilt", text: Structure.horizonDefinition)
            }
        } label: { Text("Horizon tilt") }
        .accessibilityElement(children: .combine)
    }

    private func rowView(_ title: String, _ value: String, definition: String) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(value).monospacedDigit().multilineTextAlignment(.trailing)
                TextInfoButton(title: title, text: definition)
            }
        } label: { Text(title) }
        .accessibilityElement(children: .combine)
    }
}

/// "What you photograph": the top labels across a camera's photos. Classification only, at most 60 photos, newest first.
struct CameraContentRow: View {
    let camera: CameraGroup
    @State private var top: [String] = []
    @State private var bestPath: [String: String] = [:]
    @Environment(AppModel.self) private var model: AppModel?
    @State private var done = 0
    @State private var total = 0
    @Environment(\.isSnapshot) private var isSnapshot

    static let maxPhotos = 60
    static let topCount = 6

    static func candidates(_ photos: [PhotoRecord]) -> [String] {
        photos.filter { $0.path != nil }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .prefix(maxPhotos).compactMap(\.path)
    }

    var body: some View {
        Group {
            if !top.isEmpty || (total > 0 && done < total) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "What you photograph")
                    if top.isEmpty {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading \(done) of \(total) photos…").foregroundStyle(.secondary) }
                    } else {
                        FlowLayout(spacing: 16) {
                            ForEach(top, id: \.self) { l in labelWithPhoto(l) }
                        }
                        Text("Most common labels over the newest \(done) of this camera's photos. Identified on this Mac by Apple's Vision framework; nothing leaves the computer.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .task(id: camera.id) {
            top = []; done = 0; total = 0; bestPath = [:]
            guard !isSnapshot else { return }
            let paths = Self.candidates(camera.photos)
            total = paths.count
            var counts: [String: (n: Int, conf: Double)] = [:]
            var best: [String: (conf: Double, path: String)] = [:]
            for path in paths {
                if Task.isCancelled { return }
                // labels(path:) is cached per path by ContentIdentifier; its confidences also say which photo shows a label best.
                if let labels = await ContentIdentifier.shared.labels(path: path) {
                    for l in labels {
                        let e = counts[l.label] ?? (0, 0); counts[l.label] = (e.n + 1, e.conf + l.confidence)
                        if l.confidence > (best[l.label]?.conf ?? -1) { best[l.label] = (l.confidence, path) }
                    }
                }
                done += 1
                if done % 5 == 0 || done == total { top = Self.rank(counts); bestPath = best.mapValues(\.path) }
            }
            top = Self.rank(counts)
            bestPath = best.mapValues(\.path)
        }
    }

    /// A label capsule under the thumbnail of the photo that scored that label highest.
    @ViewBuilder private func labelWithPhoto(_ l: String) -> some View {
        let path = bestPath[l]
        let photo = path.flatMap { p in camera.photos.first { $0.path == p } }
        VStack(spacing: 6) {
            Button { if let photo { model?.selectedPhotoID = photo.id } } label: {
                PhotoThumb(path: path, maxPixel: 256).frame(width: 96, height: 96)
            }
            .buttonStyle(.plain)
            .disabled(photo == nil)
            .help(photo.map { "Show \($0.file), the photo that best matches \(l)" } ?? "")
            Text(l.replacingOccurrences(of: "_", with: " ")).font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(.fill.tertiary, in: Capsule())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(l.replacingOccurrences(of: "_", with: " ")), best example \(photo?.file ?? "none")")
    }

    static func rank(_ counts: [String: (n: Int, conf: Double)]) -> [String] {
        counts.sorted { $0.value.n != $1.value.n ? $0.value.n > $1.value.n : ($0.value.conf != $1.value.conf ? $0.value.conf > $1.value.conf : $0.key < $1.key) }
            .prefix(topCount).map(\.key)
    }
}
