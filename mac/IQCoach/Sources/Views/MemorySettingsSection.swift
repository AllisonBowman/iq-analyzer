import SwiftUI

/// Settings: what the coach remembers (spec §8 item 4). Counts and bytes per tier, the window and budgets, each
/// camera's photos and state, and the controls; each control says what it does before it does it.
struct MemorySettingsSection: View {
    let model: AppModel
    @State private var previewBytes: Int64?
    @State private var earlierBytes: Int64?
    @State private var earlierCount = 0
    @State private var refresh = 0
    @State private var confirmingCompact = false
    @State private var confirmingClear = false
    @State private var confirmingForgetAll = false
    @State private var confirmingEarlier = false
    @State private var forgetting: CameraMemory?
    @State private var note: String?

    private var memory: MemorySnapshot? { model.memory }
    private var busy: Bool { model.isAnalyzing || model.isMaintaining }

    var body: some View {
        Group {
            memorySection
            if earlierBytes != nil || FileManager.default.fileExists(atPath: model.earlierCopies.path) {
                earlierSection
            }
        }
        .task(id: "\(refresh)|\(model.memory?.loadedAt.timeIntervalSince1970 ?? 0)|\(model.isAnalyzing)") { await measureFolders() }
    }

    private var memorySection: some View {
        Section {
            if let m = memory {
                tiers(m)
                cameras(m)
            } else {
                Text(model.memoryDatabase.exists ? "The memory has not been read yet." : "Nothing yet: the memory is created by the first analysis.")
                    .foregroundStyle(.secondary)
            }
            if let e = model.memoryError {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            controls
            if let note { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        } header: {
            Text("What the coach remembers")
        } footer: {
            Text("The memory is \(model.memoryDatabase.url.path); previews are in \(model.previews.files.directory.path). The analyzer is the memory's only writer; your photos and your Photos library are never changed.")
                .foregroundStyle(.secondary)
        }
    }

    private func measureFolders() async {
        let previews = model.previews, earlier = model.earlierCopies
        let (p, e, n) = await Task.detached(priority: .utility) { () -> (Int64, Int64?, Int) in
            let exists = FileManager.default.fileExists(atPath: earlier.path)
            return (previews.totalBytes(), exists ? EarlierCopies.size(of: earlier) : nil, exists ? EarlierCopies.files(in: earlier).count : 0)
        }.value
        previewBytes = p
        earlierBytes = e
        earlierCount = n
    }

    private static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    private static func capture(_ ts: Double?) -> String { ts.map { Fmt.date(MemoryStore.captureDate($0)) } ?? "—" }

    @ViewBuilder private func tiers(_ m: MemorySnapshot) -> some View {
        let s = m.stats
        LabeledContent("Photos remembered") {
            Text(s.measured.formatted() + (s.notCapture + s.failed > 0 ? " (plus \(s.notCapture.formatted()) not captures, \(s.failed.formatted()) not measurable)" : ""))
                .monospacedDigit()
        }
        LabeledContent("Records in the window") {
            Text("\(s.records.formatted()), newest \(m.window.formatted()) per camera · \(Self.bytes(s.recordBytes))").monospacedDigit()
        }
        LabeledContent("Details kept") {
            Text("\(s.details.formatted()) · \(Self.bytes(s.detailBytes))" + (m.detailBudgetBytes.map { " of \(Self.bytes($0))" } ?? "")).monospacedDigit()
        }
        LabeledContent("Monthly summaries") {
            Text("\(s.buckets.formatted()) holding \(Fmt.count(s.bucketPhotos, "earlier photo")) · \(Self.bytes(s.bucketBytes))").monospacedDigit()
        }
        LabeledContent("Database") { Text(Self.bytes(s.databaseBytes)).monospacedDigit() }
        LabeledContent("Previews") {
            Text(previewBytes.map { "\(Self.bytes($0)) of \(Self.bytes(PreviewStore.defaultBudget))" } ?? "…").monospacedDigit()
        }
        LabeledContent("Captured") { Text("\(Self.capture(s.oldestCapture)) to \(Self.capture(s.newestCapture))").monospacedDigit() }
        if m.undecodable > 0 {
            Label("\(Fmt.count(m.undecodable, "record")) could not be read and \(m.undecodable == 1 ? "is" : "are") not shown.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func cameras(_ m: MemorySnapshot) -> some View {
        if !m.cameras.isEmpty {
            Disclosure(title: "Per camera (\(m.cameras.count))") {
                ForEach(m.cameras) { c in
                    LabeledContent(c.camera) {
                        Text("\(c.remembered.formatted()) · \(freshness(c)?.word ?? "undated")").monospacedDigit()
                    }
                }
            }
        }
    }

    /// The camera screen's state: from the library's newest photo when it shows the memory, else the ledger's.
    private func freshness(_ c: CameraMemory) -> CameraFreshness? {
        if model.isShowingMemory, let cam = model.library?.camera(c.camera) { return cam.freshness() }
        return CameraFreshness(lastDate: c.newestCapture.map(MemoryStore.captureDate))
    }

    @ViewBuilder private var controls: some View {
        HStack {
            Button("Compact Now…") { confirmingCompact = true }
                .disabled(busy || memory == nil)
                .confirmationDialog("Compact the memory?", isPresented: $confirmingCompact) {
                    Button("Compact Now") { model.compactMemory() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Photos beyond the newest \(memory?.window ?? MemorySnapshot.defaultWindow) of each camera are folded into monthly summaries and their full records deleted; edge and noise details beyond their budget are deleted. Nothing is measured again, and the coaching does not change. The analyzer also does this after every run.")
                }
            Button("Clear Previews…") { confirmingClear = true }
                .disabled(busy)
                .confirmationDialog("Clear the previews?", isPresented: $confirmingClear) {
                    Button("Clear Previews", role: .destructive) {
                        Task {
                            let r = await model.clearPreviews()
                            note = "Deleted \(Fmt.count(r.removedFiles, "preview file")) (\(Self.bytes(r.freedBytes)))."
                            refresh += 1
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Pictures of remembered photos disappear until they come back: those from your Photos library are rebuilt when you open them, while Photos has the original on this Mac; any other picked photo comes back when you choose it again (Choose Photos…). Imported earlier copies that were removed do not come back. \(previewBytes.map(Self.bytes) ?? "Their space") is freed. Measurements are kept.")
                }
        }
        HStack {
            Menu("Forget a Camera…") {
                ForEach(memory?.cameras ?? []) { c in
                    Button("\(c.camera) (\(Fmt.count(c.remembered, "photo")))") { forgetting = c }
                }
            }
            .fixedSize()
            .disabled(busy || (memory?.cameras.isEmpty ?? true))
            .confirmationDialog("Forget \(forgetting?.camera ?? "this camera")?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                                presenting: forgetting) { c in
                Button("Forget \(c.camera)", role: .destructive) { model.forget(camera: c) }
                Button("Cancel", role: .cancel) {}
            } message: { c in
                Text("Its \(Fmt.count(c.remembered, "remembered photo")), their records, monthly summaries and previews are deleted, and its coaching disappears. The next analysis that meets these photos measures them again. Your photos are not touched.")
            }
            Button("Forget Everything…", role: .destructive) { confirmingForgetAll = true }
                .disabled(busy || !model.memoryDatabase.exists)
                .help(model.isAnalyzing ? "Wait for the analysis to finish." : "Delete the memory and every preview")
                .confirmationDialog("Forget everything?", isPresented: $confirmingForgetAll) {
                    Button("Forget Everything", role: .destructive) { Task { await model.forgetEverything(); refresh += 1 } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Every remembered photo (\(memory?.stats.assets.formatted() ?? "all")), its records, summaries and previews are deleted: the coach starts empty and the next analysis measures every photo again. Your photos, your Photos library and your preferences are not touched.")
                }
        }
    }

    private var earlierSection: some View {
        Section {
            LabeledContent("Earlier copies") {
                Text(earlierBytes.map { "\(earlierCount == 1 ? "1 file" : "\(earlierCount.formatted()) files") · \(Self.bytes($0))" } ?? "…").monospacedDigit()
            }
            Button("Import and Remove…") { confirmingEarlier = true }
                .disabled(busy || earlierCount == 0)
                .confirmationDialog("Import and remove the earlier copies?", isPresented: $confirmingEarlier) {
                    Button("Import and Remove", role: .destructive) { model.importEarlierCopies() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The copies are measured into the memory (known contents are not measured again) and given previews; then each copy whose content the memory holds is deleted, along with empty run folders. Copies that could not be measured or given a preview are kept. Your Photos library is not touched.")
                }
        } header: {
            Text("Earlier copies")
        } footer: {
            Text("Earlier versions of IQ Coach copied originals to \(model.earlierCopies.path); the memory makes these copies unnecessary.")
                .foregroundStyle(.secondary)
        }
    }
}
