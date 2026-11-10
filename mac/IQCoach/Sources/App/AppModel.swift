import SwiftUI
import PhotosUI
import Observation

enum SidebarItem: Hashable, Sendable {
    case library
    case camera(String)
}

struct AnalysisProgress: Equatable, Sendable {
    var done = 0
    var total = 0
    var lines: [String] = []
    var finished = false
    var failure: String?
    /// "Remembered: 35 already measured, 5 new", once the run is done.
    var summary: String?
}

extension EnvironmentValues {
    /// True while rendering PNG snapshots, where AppKit-backed controls (Table, segmented Picker) cannot draw.
    @Entry var isSnapshot: Bool = false
}

@MainActor @Observable
final class AppModel {
    var library: PhotoLibrary?
    var sidebarSelection: SidebarItem? = .library
    var selectedPhotoID: PhotoRecord.ID?
    var errorMessage: String?
    var isImporting = false
    var isChoosingFolder = false
    var isPickingPhotos = false
    var pickedPhotos: [PhotosPickerItem] = []
    static let maxPickedPhotos = 20
    var progress: AnalysisProgress?
    /// The photographer's set-aside cards, intent tags, editor and checks.
    let preferences: PreferencesStore

    /// What the memory held at the last read (nil before the first analysis, or after Forget Everything).
    private(set) var memory: MemorySnapshot?
    /// Why the last read of the memory failed, for Settings.
    private(set) var memoryError: String?
    /// True from the start of an analysis until its process has exited (a cancelled run is stopped, not abandoned).
    private(set) var isAnalyzing = false
    /// True while a compact or forget command runs.
    private(set) var isMaintaining = false
    /// The analyzer key from the last validation: fresher than the memory's when the analyzer was updated since.
    private(set) var validatedKey: String?

    let memoryDirectory: URL
    let previews: PreviewStore
    let staging: Staging
    let earlierCopies: URL

    nonisolated static let memorySourceName = "memory"
    /// Previews made at once after a batch.
    nonisolated static let previewConcurrency = 3

    init(preferences: PreferencesStore = PreferencesStore(), memoryDirectory: URL = MemoryDatabase.defaultDirectory,
         previews: PreviewStore = .shared, staging: Staging = Staging(), earlierCopies: URL = EarlierCopies.defaultDirectory) {
        self.preferences = preferences
        self.memoryDirectory = memoryDirectory
        self.previews = previews
        self.staging = staging
        self.earlierCopies = earlierCopies
    }

    /// The metric the Glossary window opens on (set by a popover's Open the Glossary button).
    var glossaryMetric: Metric?
    private var analysisTask: Task<Void, Never>?

    static let defaultPython = "~/Developer/iq-analyzer/.venv/bin/python"
    static let defaultRepo = "~/Developer/iq-analyzer"

    var memoryDatabase: MemoryDatabase { MemoryDatabase(directory: memoryDirectory) }
    var memoryStore: MemoryStore { MemoryStore(database: memoryDatabase, previews: previews.files, staging: staging.root) }
    /// The key photos are compared against: the validated one, else the one the memory's last run wrote.
    var currentAnalyzerKey: String? { validatedKey ?? memory?.currentAnalyzerKey }
    var isShowingMemory: Bool { library?.sourceName == Self.memorySourceName }
    /// An analysis (still stopping, perhaps) or a compact or forget is running: no other may start.
    var isBusy: Bool { isAnalyzing || isMaintaining }
    /// The content ids in the memory's window, whose previews a trim never evicts.
    var windowContents: Set<String> { Set(memory?.records.compactMap(\.sha256) ?? []) }

    var selectedCamera: CameraGroup? {
        guard case .camera(let m)? = sidebarSelection else { return nil }
        return library?.camera(m)
    }

    var selectedPhoto: PhotoRecord? {
        guard let id = selectedPhotoID else { return nil }
        return selectedCamera?.photos.first { $0.id == id }
    }

    private func makeRunner() -> AnalyzerRunner {
        let defaults = UserDefaults.standard
        return AnalyzerRunner(python: defaults.string(forKey: "pythonPath") ?? Self.defaultPython,
                              repo: defaults.string(forKey: "repoPath") ?? Self.defaultRepo)
    }

    // MARK: Loading

    /// At launch: leftovers of an interrupted batch are swept, the library becomes the memory's window, and the
    /// previews are brought within their bound (rebuilds and Vision results grow them between analyses).
    func launch() async {
        let staging = self.staging
        _ = await Task.detached(priority: .utility) { staging.sweep() }.value
        var readable = true
        if memoryDatabase.exists { readable = await loadMemory() }
        // Without a readable memory the window is unknown, so nothing is trimmed until it can be read.
        if readable { _ = await previews.trim(keep: windowContents) }
    }

    /// True when the process is the host of a test run (xcodebuild launches the app with these set). The window then
    /// skips `launch()`: the tests make their memories in temporary folders, and the host must not sweep, read or trim
    /// the photographer's real ones in ~/Library.
    nonisolated static var isTestHost: Bool {
        let env = ProcessInfo.processInfo.environment
        return ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"].contains { env[$0] != nil }
    }

    /// Opens any results.json as a file, as before the memory ("Open Results…").
    func load(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let photos = try PhotoRecord.decodeAll(from: data)
            guard !photos.isEmpty else {
                errorMessage = "\(url.lastPathComponent) has no photo rows. Choose the results.json that python -m iqa analyze wrote."
                return
            }
            let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            show(PhotoLibrary(sourceName: url.lastPathComponent, photos: photos, sourceDate: written), keepSelection: false)
        } catch {
            errorMessage = "Could not read \(url.lastPathComponent) as iqa results: \(error.localizedDescription)"
        }
    }

    /// Reads the memory off the main thread and makes its window the library. With `onlyIfShown`, the library is
    /// replaced only when it already shows the memory (or nothing), so a results.json opened from a file stays on
    /// screen while Settings still sees the new snapshot. Returns false when the memory could not be read.
    @discardableResult
    func loadMemory(keepSelection: Bool = false, onlyIfShown: Bool = false) async -> Bool {
        let store = memoryStore
        do {
            let snap = try await Task.detached(priority: .userInitiated) { try store.load() }.value
            memory = snap
            memoryError = nil
            await previews.register(photoKit: snap.photoKitLocators)
            if snap.records.isEmpty {
                if isShowingMemory { library = nil }
            } else if !onlyIfShown || isShowingMemory || library == nil {
                let written = memoryDatabase.companionFiles.prefix(2)
                    .compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }.max()
                show(PhotoLibrary(sourceName: Self.memorySourceName, photos: snap.records, sourceDate: written), keepSelection: keepSelection)
            }
            return true
        } catch {
            memoryError = error.localizedDescription
            return false
        }
    }

    private func show(_ lib: PhotoLibrary, keepSelection: Bool) {
        library = lib
        preferences.ingest(lib)
        if keepSelection, case .camera(let m)? = sidebarSelection, let cam = lib.camera(m) {
            if let id = selectedPhotoID, !cam.photos.contains(where: { $0.id == id }) { selectedPhotoID = nil }
        } else {
            sidebarSelection = .library
            selectedPhotoID = nil
        }
    }

    // MARK: Analysing

    private var lineSink: @Sendable (String) -> Void {
        { [weak self] line in Task { @MainActor in self?.record(line: line) } }
    }

    /// Why no analysis may start now, or nil when one may.
    static func busyMessage(isAnalyzing: Bool, isMaintaining: Bool) -> String? {
        if isAnalyzing { return "The previous analysis is still stopping. Try again in a moment." }
        if isMaintaining { return "The memory is being compacted or a camera forgotten. Try again when that finishes." }
        return nil
    }

    /// Runs one batch: validate (which also gives the analyzer key), make a staging folder, do `work`, read the memory,
    /// then delete the staging folder and trim the previews whether the batch worked or not. While an earlier run is
    /// still stopping (a download or previews do not stop at once) or the memory is maintained, it says so instead.
    private func startAnalysis(_ work: @escaping @MainActor (AnalyzerRunner, AnalyzerRunner.Check, StagedBatch) async throws -> BatchOutcome) {
        if let busy = Self.busyMessage(isAnalyzing: isAnalyzing, isMaintaining: isMaintaining) {
            errorMessage = busy
            return
        }
        let runner = makeRunner()
        progress = AnalysisProgress()
        isAnalyzing = true
        analysisTask = Task { [weak self] in
            guard let self else { return }
            var batch: StagedBatch?
            do {
                let check = try await runner.validate()
                self.validatedKey = check.analyzerKey
                let b = try self.staging.newBatch()
                batch = b
                let outcome = try await work(runner, check, b)
                // No memory file means the analyzer had nothing to do (every photo was skipped before importing).
                if self.memoryDatabase.exists, !(await self.loadMemory()) {
                    // The analyzer ran but its memory could not be read: show this run's results file instead.
                    let json = b.out.appendingPathComponent("results.json")
                    if FileManager.default.fileExists(atPath: json.path) { self.load(url: json) }
                    self.errorMessage = "The photos were measured, but the memory could not be read: \(self.memoryError ?? "unknown error"). This run's results are shown instead."
                }
                self.progress?.summary = outcome.summary
                self.progress?.finished = true
            } catch is CancellationError {
                self.progress = nil
            } catch {
                self.progress?.failure = error.localizedDescription
                self.progress?.finished = true
            }
            if let batch { try? self.staging.remove(batch) }
            _ = await self.previews.trim(keep: self.windowContents)
            self.isAnalyzing = false
            self.analysisTask = nil
        }
    }

    /// Measures a folder in place (its files are never moved or deleted); their real paths are the previews.
    func analyze(folder: URL) {
        let db = memoryDatabase.url
        let sink = lineSink
        startAnalysis { runner, _, batch in
            try await runner.analyze(paths: [folder], out: batch.out, memory: db, sources: nil, onLine: sink)
        }
    }

    /// Considers the newest `count` camera captures in the Photos library (PhotoKit, read-only): known ones cost
    /// nothing, new ones are copied to staging, measured, given a preview and deleted.
    func analyzeFromPhotos(count: Int) {
        let store = memoryStore
        let sink = lineSink
        startAnalysis { [weak self] runner, check, batch in
            guard let self else { throw CancellationError() }
            let known = try await Task.detached { try store.knownSources(kind: .photokit) }.value
            let r = try await PhotosImporter.exportNewest(count: count, known: known, currentKey: check.analyzerKey, batch: batch, onLine: sink)
            let outcome = try await self.measure(r, runner: runner, batch: batch)
            guard r.considered > 0 else { throw PhotosImportError.nothingToExport }
            return outcome
        }
    }

    /// Analyses the photos chosen in the system Photos picker (up to `maxPickedPhotos`).
    func analyze(picked items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        pickedPhotos = []
        let store = memoryStore
        let sink = lineSink
        startAnalysis { [weak self] runner, check, batch in
            guard let self else { throw CancellationError() }
            let ids = items.compactMap(\.itemIdentifier)
            let knownPhotoKit = try await Task.detached { try store.knownSources(kind: .photokit, locators: ids) }.value
            let files = self.previews.files
            let r = try await PhotosImporter.export(picked: items, knownPhotoKit: knownPhotoKit, currentKey: check.analyzerKey, batch: batch,
                                                    knownContent: { try store.knownContents([$0])[$0] },
                                                    hasPreview: { files.existing($0) != nil }, onLine: sink)
            return try await self.measure(r, runner: runner, batch: batch)
        }
    }

    /// Runs the analyzer on an import (when it has anything to do) and makes the previews of its staged files that
    /// are remembered and have none. A preview depends only on the bytes, so a photo measured again keeps its own.
    private func measure(_ r: ImportResult, runner: AnalyzerRunner, batch: StagedBatch) async throws -> BatchOutcome {
        var outcome = BatchOutcome()
        if r.needsAnalyzer {
            do {
                outcome = try await runner.analyze(paths: [batch.files], out: batch.out, memory: memoryDatabase.url,
                                                   sources: batch.manifest, onLine: lineSink)
            } catch {
                // A cancelled or failed run may have remembered some photos before it stopped: they get their previews
                // while their staged copies still exist, then the error goes on.
                await salvagePreviews(r.staged)
                throw error
            }
        }
        outcome.skippedBeforeImport = r.skippedKnown
        outcome.failedBeforeImport = r.skippedFailed
        let files = previews.files
        let wanted = Self.previewsWanted(r.staged, remembered: outcome.remembered, hasPreview: { files.existing($0) != nil })
        let made = await Self.makePreviews(wanted, store: previews)
        if !wanted.isEmpty { record(line: "made \(Fmt.count(made, "preview")) of \(wanted.count.formatted())") }
        return outcome
    }

    /// The staged files to make previews of: remembered after the run (new, measured again or already known) and
    /// without one. Measured again (stale) is not reason enough, since the preview depends only on the bytes.
    nonisolated static func previewsWanted(_ staged: [StagedFile], remembered: Set<String>, hasPreview: (String) -> Bool) -> [StagedFile] {
        staged.filter { remembered.contains($0.sha256) && !hasPreview($0.sha256) }
    }

    /// Previews for the staged files whose content the memory now holds as measured and that have none.
    private func salvagePreviews(_ staged: [StagedFile]) async {
        guard !staged.isEmpty else { return }
        let store = memoryStore, files = previews.files
        let known = (try? await Task.detached { try store.knownContents(staged.map(\.sha256)) }.value) ?? [:]
        let wanted = Self.previewsToSalvage(staged, known: known, hasPreview: { files.existing($0) != nil })
        _ = await Self.makePreviews(wanted, store: previews)
    }

    nonisolated static func previewsToSalvage(_ staged: [StagedFile], known: [String: KnownAsset], hasPreview: (String) -> Bool) -> [StagedFile] {
        var seen = Set<String>()
        return staged.filter { known[$0.sha256]?.status == "measured" && !hasPreview($0.sha256) && seen.insert($0.sha256).inserted }
    }

    /// Makes previews of staged files, at most `previewConcurrency` at once. Returns how many were made.
    nonisolated static func makePreviews(_ files: [StagedFile], store: PreviewStore, limit: Int = previewConcurrency) async -> Int {
        await withTaskGroup(of: Bool.self) { group in
            var next = 0, made = 0
            while next < min(limit, files.count) {
                let f = files[next]
                group.addTask { (try? await store.make(sha: f.sha256, from: f.url)) != nil }
                next += 1
            }
            while let ok = await group.next() {
                if ok { made += 1 }
                if next < files.count {
                    let f = files[next]
                    group.addTask { (try? await store.make(sha: f.sha256, from: f.url)) != nil }
                    next += 1
                }
            }
            return made
        }
    }

    static var photosCount: Int {
        let n = UserDefaults.standard.integer(forKey: "photosCount")
        return n > 0 ? n : 40
    }

    private func record(line: String) {
        guard progress != nil else { return }
        progress?.lines.append(line)
        if (progress?.lines.count ?? 0) > 200 { progress?.lines.removeFirst() }
        if let m = line.firstMatch(of: /\[(\d+)\/(\d+)\]/), let d = Int(m.1), let t = Int(m.2) {
            progress?.done = d
            progress?.total = t
        }
    }

    /// Stops the run (the analyzer process is terminated) and closes the sheet; a finished run's sheet just closes.
    func cancelAnalysis() {
        analysisTask?.cancel()
        progress = nil
    }

    // MARK: Earlier copies

    /// Measures the copies earlier versions left in Application Support into the memory, makes their previews, then
    /// deletes only the copies whose content the memory now holds and the run folders that are empty. Only on request.
    func importEarlierCopies() {
        let dir = earlierCopies
        let db = memoryDatabase.url
        let store = memoryStore
        let sink = lineSink
        let previews = self.previews
        startAnalysis { [weak self] runner, _, batch in
            guard let self else { throw CancellationError() }
            let files = try await Task.detached(priority: .utility) {
                try EarlierCopies.files(in: dir).map { StagedFile(url: $0, sha256: try ContentHash.sha256(of: $0)) }
            }.value
            sink("\(files.count == 1 ? "1 earlier copy" : "\(files.count.formatted()) earlier copies") found in \(dir.path)")
            // One clone per distinct content (APFS: no extra disk) under the name it had before the app prefixed it,
            // listed without a locator: the records carry the real name and no Application Support path becomes a source.
            let staged = try await Task.detached(priority: .utility) { try EarlierCopies.stage(files, into: batch) }.value
            try ManifestLine.encode(staged.map { .staged($0.url, sha256: $0.sha256, kind: .file, locator: nil) }).write(to: batch.manifest, options: .atomic)
            let outcome = try await runner.analyze(paths: [batch.files], out: batch.out, memory: db, sources: batch.manifest, onLine: sink)
            let remembered = outcome.remembered
            let wanted = staged.filter { remembered.contains($0.sha256) && previews.files.existing($0.sha256) == nil }
            _ = await Self.makePreviews(wanted, store: previews)
            let known = try await Task.detached { try store.knownContents(files.map(\.sha256)) }.value
            let removal = await Task.detached(priority: .utility) {
                let r = EarlierCopies.removeRemembered(files, known: known, hasPreview: { previews.files.existing($0) != nil }, root: dir)
                EarlierCopies.removeEmptyFolders(under: dir, includingRoot: true)
                EarlierCopies.removeEmptyFolders(under: EarlierCopies.runsDirectory, includingRoot: false)
                return r
            }.value
            self.record(line: removal.sentence)
            return outcome
        }
    }

    // MARK: Forgetting and compacting (through the analyzer, the memory's only writer)

    private func maintain(_ args: [String], then: (@MainActor () async -> Void)? = nil) {
        guard !isAnalyzing, !isMaintaining else { return }
        isMaintaining = true
        let runner = makeRunner()
        Task { [weak self] in
            do {
                _ = try await runner.memoryCommand(args)
                await then?()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            // A results.json opened from a file stays on screen; Settings reads the new snapshot either way.
            await self?.loadMemory(keepSelection: true, onlyIfShown: true)
            self?.isMaintaining = false
        }
    }

    /// Folds records beyond the window into the archive and trims the details to their budget.
    func compactMemory() {
        maintain(["compact", memoryDatabase.url.path])
    }

    /// Forgets one camera: its ledger rows, records, details and archive, and its previews.
    func forget(camera: CameraMemory) {
        let store = memoryStore
        let previews = self.previews
        let shas = (try? store.shas(ledgerCamera: camera.ledgerName)) ?? []
        maintain(["forget", memoryDatabase.url.path, "--camera", camera.ledgerName]) {
            _ = await previews.remove(shas: shas)
        }
    }

    /// Deletes memory.sqlite with its -wal and -shm, and every preview. Only while no analysis runs.
    func forgetEverything() async {
        guard !isAnalyzing, !isMaintaining else { return }
        var failures: [String] = []
        for f in memoryDatabase.companionFiles where FileManager.default.fileExists(atPath: f.path) {
            do { try FileManager.default.removeItem(at: f) } catch { failures.append(f.path) }
        }
        let cleared = await previews.clear()
        if cleared.remainingBytes > 0 {
            let size = ByteCountFormatter.string(fromByteCount: cleared.remainingBytes, countStyle: .file)
            failures.append("\(size) of previews in \(previews.files.directory.path)")
        }
        memory = nil
        memoryError = nil
        if isShowingMemory {
            library = nil
            sidebarSelection = .library
            selectedPhotoID = nil
        }
        if !failures.isEmpty { errorMessage = "Could not delete \(Fmt.list(failures))." }
    }

    func clearPreviews() async -> PreviewStore.TrimResult { await previews.clear() }
}
