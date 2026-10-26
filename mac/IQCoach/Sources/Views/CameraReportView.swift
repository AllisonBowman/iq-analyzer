import SwiftUI

/// A camera's screen, in order of attention (spec §2): the one thing, the report card with coverage lines, the
/// coaching cards with their three disclosures, then content, charts and the photos.
struct CameraReportView: View {
    let camera: CameraGroup
    @Binding var selectedPhotoID: PhotoRecord.ID?
    var library: PhotoLibrary?
    /// Preferences to use instead of the app's (snapshots and fixtures).
    var prefsOverride: UserPreferences?
    var choosePhotos: (() -> Void)?
    /// The day freshness is measured to (fixtures pin it).
    var now: Date = .now
    @Environment(AppModel.self) private var model: AppModel?
    @State private var settingAside: Insight?
    @State private var startingCheck: Insight?

    private var prefs: UserPreferences { prefsOverride ?? model?.preferences.prefs ?? UserPreferences() }
    private var setAside: ((Insight) -> Void)? { model == nil ? nil : { settingAside = $0 } }
    private var bringBack: ((SetAsideCard) -> Void)? { model.map { m in { m.preferences.bringBack($0.id) } } }
    private var startCheck: ((Insight) -> Void)? { model == nil ? nil : { startingCheck = $0 } }
    private var checks: [CaptureCheck] { prefs.checks.filter { $0.camera == camera.model && $0.status != .dropped } }

    private var s: CameraSummary { camera.summary }
    private var output: CoachingOutput { CoachingEngine.output(for: camera, prefs: prefs) }
    private var isSparse: Bool { camera.photos.count < CameraRules.minPhotos }

    var body: some View {
        ScrollViewReader { proxy in
            MaybeScroll {
                VStack(alignment: .leading, spacing: 32) {
                    if let banner = CameraFreshness.banner(camera: camera.model, lastDate: s.lastDate, now: now),
                       let state = CameraFreshness(lastDate: s.lastDate, now: now) {
                        FreshnessBanner(state: state, text: banner)
                    }
                    header
                    if isSparse {
                        sparseBody
                    } else {
                        let out = output
                        if let one = out.oneThing {
                            OneThingCard(camera: camera, oneThing: one,
                                         openProof: { id in withAnimation { proxy.scrollTo(id, anchor: .top) } },
                                         startCheck: startCheck, setAside: setAside, choosePhotos: choosePhotos)
                        }
                        ForEach(checks) { c in
                            CheckCard(check: c,
                                      finish: model.map { m in { m.preferences.setStatus(.finished, check: c.id) } },
                                      drop: model.map { m in { m.preferences.setStatus(.dropped, check: c.id) } })
                        }
                        reportCard
                        coaching(out)
                        CameraContentRow(camera: camera)
                        charts
                    }
                    photosSection
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(item: $settingAside) { i in
            SetAsideSheet(insight: i) { note in model?.preferences.setAside(i, note: note) }
        }
        .sheet(item: $startingCheck) { i in
            StartCheckSheet(insight: i, camera: camera, library: library, intents: prefs.intents) { model?.preferences.startCheck($0) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(camera.model).font(.largeTitle.weight(.bold)).accessibilityAddTraits(.isHeader)
            Text(provenance).font(.callout).foregroundStyle(.secondary)
            // Only beside the memory's own window: beside a results.json opened from a file, the archive is neither
            // "earlier" nor a different set of photos.
            if model?.isShowingMemory == true, let earlier = model?.memory?.archiveSummary(camera: camera.model, currentKey: model?.currentAnalyzerKey) {
                Text(earlier.sentence + ".").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .help("From the monthly summaries of the photos that left the newest \(model?.memory?.window ?? MemorySnapshot.defaultWindow); the coaching reads only the newest.")
                if let left = earlier.leftOutSentence {
                    Text(left).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            let names = CameraRules.lensNames(camera.lenses)
            let lensText = camera.lenses.map { camera.isPhone ? (names[$0.name] ?? $0.name) : $0.name }.joined(separator: ", ")
            Text("\(Fmt.count(camera.lenses.count, "lens")): \(lensText)")
                .font(.callout).foregroundStyle(.secondary)
            RecentPhotoStrip(camera: camera, selectedPhotoID: $selectedPhotoID).padding(.top, 8)
        }
    }

    /// "From results.json, written 23 Oct 2026 at 04:36 · 206 photos, shot 19 Jun to 12 Oct 2026"
    private var provenance: String {
        var t = "From \(library?.sourceName ?? "results")"
        if let d = library?.sourceDate { t += ", written \(Fmt.date(d)) at \(d.formatted(date: .omitted, time: .shortened))" }
        t += " · \(Fmt.count(camera.photos.count, "photo"))"
        if let a = s.firstDate, let b = s.lastDate { t += ", shot \(Fmt.date(a)) to \(Fmt.date(b))" }
        return t
    }

    private var reportCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Report card", subtitle: "Each figure says how many of the \(Fmt.count(camera.photos.count, "photo")) it rests on.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                // Banded on the per-pixel figure: LW/PH is capped by the picture height, so it carries no band of its own.
                if s.hasSharpnessFigure, let lwph = s.sharpnessLWPH {
                    MetricTile(metric: .sharpnessCPP, title: "In-focus sharpness", value: s.sharpnessCPP,
                               shownAs: MeasuredValue.text(.sharpnessLWPH, lwph), evidence: s.sharpnessCaption,
                               context: Metric.sharpnessLWPH.evidenceText(camera: s))
                } else {
                    MetricTile(metric: .sharpnessLWPH, title: "In-focus sharpness", value: nil, notEnough: CameraSummary.notEnoughText,
                               evidence: s.sharpnessCaption, context: Metric.sharpnessLWPH.evidenceText(camera: s))
                }
                MetricTile(metric: .snr, title: "Noise (SNR)", value: s.hasSNRFigure ? s.snr : nil,
                           notEnough: s.hasSNRFigure ? nil : CameraSummary.notEnoughText, evidence: s.snrCaption,
                           context: Metric.snr.evidenceText(camera: s))
                MetricTile(metric: .highlightClip, title: "Blown highlights", value: s.clipHighMedian,
                           evidence: s.clipCaption ?? Metric.highlightClip.shortMeaning, context: Metric.highlightClip.evidenceText(camera: s))
                MetricTile(metric: .overshoot, title: "Sharpening halo", value: s.hasOvershootFigure ? s.overshoot : nil,
                           notEnough: s.hasOvershootFigure ? nil : CameraSummary.notEnoughText, evidence: s.overshootCaption,
                           context: Metric.overshoot.evidenceText(camera: s))
                MetricTile(metric: .whiteBalance, title: "Colour lean", value: s.wbLean, evidence: s.leanCaption, banded: false,
                           context: Metric.whiteBalance.evidenceText(camera: s))
                MetricTile(metric: .dynamicRange, title: "Dynamic range", value: s.dynamicRange,
                           qualifier: s.dynamicRangeIsLowerBound ? .atLeast : .none, evidence: s.dynamicRangeCaption, banded: false,
                           context: Metric.dynamicRange.evidenceText(camera: s))
            }
        }
    }

    private func coaching(_ out: CoachingOutput) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Coaching", subtitle: "What this camera does, how sure each finding is, and what to do about it: at the camera, once in settings, or in the editor.")
            if out.cards.isEmpty {
                Text("No finding here is firm enough to act on yet; see Needs more photos below.").foregroundStyle(.secondary)
            }
            ForEach(out.cards) { InsightCard(insight: $0, camera: camera, startCheck: startCheck, setAside: setAside) }
            if !out.needsMorePhotos.isEmpty {
                Disclosure(title: "Needs more photos (\(out.needsMorePhotos.count))") {
                    ForEach(out.needsMorePhotos) { InsightCard(insight: $0, camera: camera) }
                }
            }
            if !out.setAside.isEmpty {
                Disclosure(title: "You set aside (\(out.setAside.count))") {
                    ForEach(out.setAside) { SetAsideRow(card: $0, bringBack: bringBack) }
                }
            }
            if !out.silent.isEmpty {
                Disclosure(title: "\(Fmt.count(out.silent.count, "check")) had nothing to say") {
                    ForEach(out.silent) { c in
                        Text(c.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var sparseBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                Text(SparseSummary.text(for: camera))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            } label: {
                Text("What these photos say").font(.headline)
            }
            ContentUnavailableView {
                Label("Coaching starts at \(CameraRules.minPhotos) photos", systemImage: "camera.metering.unknown")
            } description: {
                Text("This camera has \(Fmt.count(camera.photos.count, "photo")). Medians and coaching need \(CameraRules.minPhotos).")
            } actions: {
                if let choosePhotos { Button("Choose Photos to Analyze…", action: choosePhotos).disabled(model?.isBusy == true) }
            }
        }
    }

    private var charts: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "Charts")
            SNRvsISOChart(camera: camera)
            LensSharpnessChart(camera: camera)
            ClippingChart(camera: camera)
        }
    }

    private var photosSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Photos", subtitle: "Choose a photo to see its measurements and per-photo editing steps.")
            PhotoTable(photos: camera.photos, selection: $selectedPhotoID)
        }
    }
}

extension CameraGroup {
    /// Photos that have a file path, newest first.
    func recentPhotos(_ limit: Int) -> [PhotoRecord] {
        photos.filter { $0.path != nil }
            .sorted { ($0.date ?? .distantPast) != ($1.date ?? .distantPast) ? ($0.date ?? .distantPast) > ($1.date ?? .distantPast) : $0.file < $1.file }
            .prefix(limit).map { $0 }
    }

    /// The newest photo with a path: stands in for the camera in the library overview.
    var representativePhoto: PhotoRecord? { recentPhotos(1).first }
}

/// Up to eight recent photos of the camera at 96 pt; choosing one opens its measurements.
struct RecentPhotoStrip: View {
    let camera: CameraGroup
    @Binding var selectedPhotoID: PhotoRecord.ID?
    @Environment(\.isSnapshot) private var isSnapshot
    static let count = 8

    var body: some View {
        let photos = camera.recentPhotos(Self.count)
        if !photos.isEmpty {
            let strip = HStack(spacing: 10) {
                ForEach(photos) { p in
                    Button { selectedPhotoID = p.id } label: {
                        PhotoThumb(path: p.path, maxPixel: 256).frame(width: 96, height: 96)
                    }
                    .buttonStyle(.plain)
                    .help("Show \(p.file)")
                    .accessibilityLabel("Open \(p.file)")
                }
            }
            if isSnapshot { strip } else { ScrollView(.horizontal, showsIndicators: false) { strip } }
        }
    }
}

/// The sentence a Resting or Dormant camera's screen opens with (spec §8 item 1).
struct FreshnessBanner: View {
    let state: CameraFreshness
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state == .dormant ? "moon.zzz.fill" : "moon.zzz")
                .font(.title2).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(state.word) camera").font(.headline)
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
