import SwiftUI

struct PhotoDetailView: View {
    let photo: PhotoRecord
    @State private var editor: Editor = .applePhotos
    @State private var overlay: PhotoOverlay
    @State private var content: ContentState = .idle
    @Environment(\.isSnapshot) private var isSnapshot

    init(photo: PhotoRecord, initialOverlay: PhotoOverlay = .none) {
        self.photo = photo
        _overlay = State(initialValue: initialOverlay)
    }

    private var advice: [EditingAdvice] { EditingRules.advice(for: photo) }

    var body: some View {
        formOrStack {
            block(nil) {
                imageSection
                VStack(alignment: .leading, spacing: 4) {
                    Text(photo.file).font(.headline).lineLimit(2).truncationMode(.middle)
                    Text([photo.camera, photo.lens].compactMap { $0 }.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                    Text(settingsLine).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            block("What is in the picture") {
                ContentSectionBody(state: content)
            }
            block("Structure") {
                StructureSectionBody(photo: photo, salientBox: content.summary?.salientBox)
            }
            block("Sharpness") {
                row(.sharpnessLWPH); row(.sharpnessCPP); row(.overshoot)
            }
            block("Noise") {
                row(.snr); row(.whiteness)
                if photo.noisePeriodicSuspect == true {
                    Label("A repeating pattern was found in the flat areas, so the noise figure describes the pattern.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                }
            }
            block("Exposure and colour") {
                row(.highlightClip); row(.shadowClip); row(.dynamicRange); row(.tonalRange); row(.whiteBalance); row(.colorfulness)
            }
            block("Editing advice") {
                editorPicker
            }
            if EditingRules.isNothingToFix(advice) {
                block(nil) { Label(EditingRules.nothingToFixText, systemImage: "checkmark.seal") }
            } else {
                ForEach(advice) { a in
                    block(title(for: a)) { adviceCard(a) }
                }
            }
        }
        .onChange(of: photo.id) { overlay = .none }
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

    private var settingsLine: String {
        var parts: [String] = []
        if let i = photo.iso { parts.append("ISO \(Fmt.int(i))") }
        if let e = photo.exposureS { parts.append(Fmt.shutter(e)) }
        if let f = photo.fNumber { parts.append("f/\(Fmt.num(f, 1))") }
        if let d = photo.date { parts.append(d.formatted(date: .abbreviated, time: .shortened)) }
        return parts.joined(separator: " · ")
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
                    Text(e.rawValue).font(.callout.weight(e == editor ? .semibold : .regular))
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(e == editor ? AnyShapeStyle(.selection) : AnyShapeStyle(.fill.quaternary), in: Capsule())
                }
            }
        } else {
            Picker("Editor", selection: $editor) {
                ForEach(Editor.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Editing app")
        }
    }

    private func title(for a: EditingAdvice) -> String {
        a.metric?.displayName ?? (a.id.hasPrefix("dark") ? "Exposure: dark" : a.id.hasPrefix("bright") ? "Exposure: bright"
            : a.id.hasPrefix("straighten") ? "Horizon" : a.id.hasPrefix("thirds") ? "Composition"
            : a.id.hasPrefix("shallow") ? "Shallow depth of field" : "Moire")
    }

    @ViewBuilder private func adviceCard(_ a: EditingAdvice) -> some View {
        HStack(alignment: .top, spacing: 12) {
            OverlayImage(path: photo.path, overlay: a.overlay(for: photo), photo: photo, salientBox: nil, boxSize: 96)
            VStack(alignment: .leading, spacing: 8) {
                Text(a.finding).fixedSize(horizontal: false, vertical: true)
                Text("In \(editor.rawValue)").font(.subheadline.weight(.semibold))
                Text(a.text(for: editor)).font(.callout).fixedSize(horizontal: false, vertical: true)
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
        let v = m.value(of: photo)
        LabeledContent {
            HStack(spacing: 8) {
                if let v {
                    Text(valueText(m, v)).monospacedDigit()
                    if let b = m.band(for: v) { BandCapsule(band: b) }
                } else {
                    Text("Not measured").foregroundStyle(.secondary)
                }
                InfoButton(metric: m)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(m.displayName)
                Text(m.shortMeaning).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func valueText(_ m: Metric, _ v: Double) -> String {
        if m == .dynamicRange && photo.drSNR4LowerBound == true { return "At least " + m.format(v) }
        return m.format(v)
    }
}
