import SwiftUI
import AppKit

/// Layer 5: what to do to this picture, in what order, and what to leave alone; then the measurements.
struct PhotoDetailView: View {
    let photo: PhotoRecord
    var camera: CameraGroup?
    var library: PhotoLibrary?
    var intents: Set<IntentTag> = []
    var editor: Editor = .applePhotos
    var setEditor: ((Editor) -> Void)?
    /// Adds or removes an intent tag on this photo.
    var toggleIntent: ((IntentTag) -> Void)?
    @State private var localEditor: Editor?
    @State private var overlay: PhotoOverlay
    @State private var content: ContentState = .idle
    @State private var shownAnyway: Set<String> = []
    @Environment(\.isSnapshot) private var isSnapshot

    init(photo: PhotoRecord, camera: CameraGroup? = nil, library: PhotoLibrary? = nil, intents: Set<IntentTag> = [],
         editor: Editor = .applePhotos, setEditor: ((Editor) -> Void)? = nil, toggleIntent: ((IntentTag) -> Void)? = nil,
         initialOverlay: PhotoOverlay = .none) {
        self.photo = photo
        self.camera = camera
        self.library = library
        self.intents = intents
        self.editor = editor
        self.setEditor = setEditor
        self.toggleIntent = toggleIntent
        _overlay = State(initialValue: initialOverlay)
    }

    private var currentEditor: Editor { localEditor ?? editor }

    var context: PhotoContext {
        PhotoContext(camera: camera, library: library, visionHorizonDeg: content.summary?.horizonDegrees, intents: intents)
    }

    private var advice: PhotoAdvice { EditingRules.advice(for: photo, context: context) }

    var body: some View {
        let a = advice
        formOrStack {
            block(nil) {
                imageSection
                VStack(alignment: .leading, spacing: 4) {
                    Text(photo.file).font(.headline).lineLimit(2).truncationMode(.middle)
                    Text([photo.camera, photo.lens].compactMap { $0 }.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                    Text(settingsLine).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                if !intents.isEmpty { intentCapsules }
            }
            let usual = camera.map { UsualComparison.lines(for: photo, camera: $0) } ?? []
            if !usual.isEmpty {
                block("Against your other photos") {
                    ForEach(usual) { u in
                        Label(u.text, systemImage: Self.symbol(u.measure))
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            block("Do first") {
                editorPicker
                if a.nothingToFix {
                    Label(EditingRules.nothingToFixText, systemImage: "checkmark.seal")
                } else {
                    ForEach(Array(a.doFirst.enumerated()), id: \.element.id) { i, adv in
                        adviceCard(adv, number: i + 1)
                    }
                }
            }
            if !a.also.isEmpty {
                block(nil) {
                    Disclosure(title: "Also (\(a.also.count))") {
                        ForEach(a.also) { adviceCard($0, number: nil) }
                    }
                }
            }
            if !a.silenced.isEmpty {
                block(nil) {
                    Disclosure(title: "You marked as intended (\(a.silenced.count))") {
                        ForEach(a.silenced) { adv in
                            if shownAnyway.contains(adv.id) {
                                adviceCard(adv, number: nil)
                            } else {
                                HStack {
                                    Text("\(adv.title) · \(adv.silencedBy?.word ?? "")").foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Show Anyway") { shownAnyway.insert(adv.id) }
                                }
                            }
                        }
                    }
                }
            }
            block(nil) {
                Disclosure(title: "Checked, nothing to do (\(a.checked.count))") {
                    Text(a.checked.map(\.text).joined(separator: " · ")).font(.callout).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !a.notMeasured.isEmpty {
                    Disclosure(title: "Not measured (\(a.notMeasured.count))") {
                        ForEach(a.notMeasured, id: \.self) { Text($0.text).font(.callout).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
            block("Measurements") {
                Text("Sharpness").font(.subheadline.weight(.semibold))
                row(.sharpnessLWPH); row(.overshoot)
                Text("Noise").font(.subheadline.weight(.semibold)).padding(.top, 4)
                row(.snr); row(.whiteness)
                if let note = PhotoReading.noiseNote(photo) {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Exposure and colour").font(.subheadline.weight(.semibold)).padding(.top, 4)
                row(.highlightClip); row(.shadowClip); row(.dynamicRange); row(.tonalRange); row(.whiteBalance); row(.colorfulness)
            }
            block("Structure") {
                StructureSectionBody(photo: photo, salientBox: content.summary?.salientBox)
            }
            block("What is in the picture") {
                ContentSectionBody(state: content)
            }
        }
        .toolbar {
            if !isSnapshot {
                ToolbarItem {
                    Button {
                        let md = MarkdownExport.editingSteps(for: photo, advice: a, editor: currentEditor, library: library)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(md, forType: .string)
                    } label: {
                        Label("Copy Editing Steps", systemImage: "checklist")
                    }
                    .help("Copy this photo's editing steps as a Markdown checklist")
                }
            }
        }
        .onChange(of: photo.id) { overlay = .none; shownAnyway = [] }
        .task(id: photo.id) {
            content = .idle
            guard !isSnapshot else { return }
            guard let path = photo.path, !path.isEmpty else { content = .noFile; return }
            content = .loading
            let result = await ContentIdentifier.shared.summary(path: path)
            if !Task.isCancelled { content = .done(result) }
        }
    }

    @ViewBuilder private func formOrStack<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        if isSnapshot {
            VStack(alignment: .leading, spacing: 16) { c() }.padding(16)
        } else {
            Form { c() }.formStyle(.grouped)
        }
    }

    @ViewBuilder private func block<C: View>(_ title: String?, @ViewBuilder _ c: () -> C) -> some View {
        if isSnapshot {
            VStack(alignment: .leading, spacing: 8) {
                if let title { Text(title).font(.headline) }
                c()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
        } else if let title {
            Section(title) { c() }
        } else {
            Section { c() }
        }
    }

    private static func symbol(_ m: UsualComparison.Measure) -> String {
        switch m {
        case .highlights: "sun.max"
        case .shadows: "moon"
        case .snr: "waveform"
        case .sharpness: "scope"
        }
    }

    private var settingsLine: String {
        var parts: [String] = []
        if let i = photo.iso { parts.append(Fmt.iso(i)) }
        if let e = photo.exposureS { parts.append(Fmt.shutter(e)) }
        if let f = photo.fNumber { parts.append("f/\(Fmt.num(f, 1))") }
        if let d = photo.date { parts.append(d.formatted(date: .abbreviated, time: .shortened)) }
        return parts.joined(separator: " · ")
    }

    /// The photographer's intent tags, each removable.
    private var intentCapsules: some View {
        FlowLayout(spacing: 6) {
            ForEach(IntentTag.allCases.filter(intents.contains)) { tag in
                HStack(spacing: 4) {
                    Label(tag.word, systemImage: "hand.raised").font(.callout)
                    if let toggleIntent {
                        Button { toggleIntent(tag) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .help("Remove \(tag.word)")
                            .accessibilityLabel("Remove \(tag.word)")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(.fill.tertiary, in: Capsule())
            }
        }
    }

    /// The photo is the centre of the screen: large, with an overlay chooser and a caption under it.
    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            OverlayImage(path: photo.path, overlay: overlay, photo: photo, salientBox: content.summary?.salientBox)
            OverlayPicker(selection: $overlay)
            if let caption = OverlayImage.caption(for: overlay, photo: photo, hasSalientBox: content.summary?.salientBox != nil) {
                Text(caption).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var editorPicker: some View {
        if isSnapshot {
            HStack(spacing: 8) {
                ForEach(Editor.allCases) { e in
                    Text(e.rawValue).font(.callout.weight(e == currentEditor ? .semibold : .regular))
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(e == currentEditor ? AnyShapeStyle(.selection) : AnyShapeStyle(.fill.quaternary), in: Capsule())
                }
            }
        } else {
            Picker("Editor", selection: Binding(get: { currentEditor }, set: { e in
                if let setEditor { setEditor(e) } else { localEditor = e }
            })) {
                ForEach(Editor.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Editing app")
        }
    }

    @ViewBuilder private func adviceCard(_ a: EditingAdvice, number: Int?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            OverlayImage(path: photo.path, overlay: a.overlay(for: photo), photo: photo, salientBox: nil, boxSize: 96)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(number.map { "\($0). \(a.title)" } ?? a.title).font(.headline)
                    GradeCapsule(grade: a.grade)
                    Spacer()
                    if let tag = a.silencedBy, let toggleIntent, !intents.contains(tag) {
                        Menu {
                            Button(tag.menuTitle) { toggleIntent(tag) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("More")
                    }
                }
                Text(a.finding).fixedSize(horizontal: false, vertical: true)
                if let note = a.note {
                    Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("In \(currentEditor.rawValue)").font(.subheadline.weight(.semibold))
                Text(a.text(for: currentEditor)).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let c = a.caution {
                    Label(c, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private func row(_ m: Metric) -> some View {
        let shown = MeasuredValue.photoText(m, photo)
        let context = m.evidenceText(photo: photo).map { ("In this photo", $0) }
        LabeledContent {
            HStack(spacing: 8) {
                MeasuredValue(text: shown.text, dimmed: !shown.counted)
                if shown.counted, let b = PhotoReading.band(m, photo) { BandCapsule(band: b) }
                InfoButton(metric: m, context: context)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(m.displayName).help(m.shortMeaning)
                if (m == .sharpnessLWPH), photo.hasSharpnessFigure, let r = photo.p80RangeLWPH {
                    Text("This photo's range \(Fmt.int(r.lowerBound))–\(Fmt.int(r.upperBound)) LW/PH").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text(m.shortMeaning).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The evidence word of one piece of photo advice.
struct GradeCapsule: View {
    let grade: EvidenceGrade
    var body: some View {
        Label(grade.word, systemImage: grade.symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(.fill.tertiary, in: Capsule())
            .help(grade.definition)
            .accessibilityLabel("\(grade.word) evidence")
    }
}

/// How one photo's measurements are shown: with the analyzer's validity gates, so a figure the camera medians
/// leave out is not banded as if it counted. Pure, so the tests can pin it.
enum PhotoReading {
    /// The band for a photo's row, or nil when the metric is unbanded or the reading does not count.
    /// Both sharpness rows take the per-pixel band (LW/PH is capped by the picture height).
    static func band(_ m: Metric, _ p: PhotoRecord) -> Band? {
        if notCountedText(m, p) != nil { return nil }
        switch m {
        case .sharpnessLWPH, .sharpnessCPP: return p.mtf50P80CPP.flatMap { Metric.sharpnessCPP.band(for: $0) }
        case .snr: return p.snrIsClean ? p.snrMidgreyDB.flatMap { m.band(for: $0) } : nil
        default: return m.value(of: p).flatMap { m.band(for: $0) }
        }
    }

    /// Replaces the value when it rests on too few edges: "— · only 1 edge, not enough to count".
    static func notCountedText(_ m: Metric, _ p: PhotoRecord) -> String? {
        guard [.sharpnessLWPH, .sharpnessCPP, .overshoot].contains(m), m.value(of: p) != nil, !p.hasSharpnessFigure else { return nil }
        return "— · only \(Fmt.count(p.edgesMeasured ?? 0, "edge")), not enough to count"
    }

    /// Why the noise figure is not a sensor-noise reading, when it is not.
    static func noiseNote(_ p: PhotoRecord) -> String? {
        guard p.snrMidgreyDB != nil else { return nil }
        if p.snrMidgreyExtrapolated == true {
            return "Measured at a different grey level and extrapolated to mid-grey, so it is not banded and the camera medians leave it out."
        }
        if p.noiseTextureSuspect == true {
            return "The flat areas are texture or heavy smoothing rather than sensor noise (whiteness above \(Fmt.num(Metric.whitenessTexture, 1))), so the figure is not banded and the camera medians leave it out."
        }
        if p.noisePeriodicSuspect == true {
            return "A repeating pattern was found in the flat areas. Where it covered a minority of them it was removed before measuring; otherwise the figure describes the pattern. The camera medians leave this photo out."
        }
        return nil
    }

    /// "2,608 LW/PH · Good · 5 edges", or "— · 1 edge" when too few edges were measured to count.
    static func sharpnessText(_ p: PhotoRecord) -> String {
        guard let v = p.mtf50P80LWPH else { return "Not measured" }
        let edges = Fmt.count(p.edgesMeasured ?? 0, "edge")
        guard p.hasSharpnessFigure else { return "— · \(edges)" }
        return Metric.sharpnessLWPH.format(v) + (band(.sharpnessLWPH, p).map { " · \($0.word)" } ?? "") + " · \(edges)"
    }

    /// The SNR with its band, or without one (and "not counted") when the reading is left out of the medians.
    static func snrText(_ p: PhotoRecord) -> String {
        guard let v = p.snrMidgreyDB else { return "Not measured" }
        guard p.snrIsClean else { return Metric.snr.format(v) + " · not counted" }
        return Metric.snr.format(v) + (Metric.snr.band(for: v).map { " · \($0.word)" } ?? "")
    }
}
