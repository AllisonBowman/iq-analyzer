import Foundation
import Observation

/// Reads and writes `~/Library/Application Support/IQCoach/preferences.json`: the editor, set-aside cards, intent tags
/// and capture checks. Writes are atomic and debounced by a second; a file that does not decode is moved aside as
/// `preferences.bad-<stamp>.json` and the app starts clean.
@MainActor @Observable
final class PreferencesStore {
    private(set) var prefs = UserPreferences()
    /// Set when a damaged file was moved aside at launch, so Settings can say so.
    private(set) var movedAside: URL?
    let directory: URL
    @ObservationIgnored private var pending: Task<Void, Never>?
    static let debounce: Duration = .seconds(1)

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IQCoach", isDirectory: true)
    }

    var fileURL: URL { directory.appendingPathComponent("preferences.json") }

    init(directory: URL = PreferencesStore.defaultDirectory, load: Bool = true) {
        self.directory = directory
        if load { self.load() }
    }

    // MARK: Reading and writing

    func load() {
        let url = fileURL
        guard let data = try? Data(contentsOf: url) else { prefs = UserPreferences(); return }
        do {
            prefs = try Self.decoder().decode(UserPreferences.self, from: data)
        } catch {
            let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.omitted).time(includingFractionalSeconds: false).timeSeparator(.omitted))
            let bad = directory.appendingPathComponent("preferences.bad-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: bad)
            movedAside = bad
            prefs = UserPreferences()
        }
    }

    /// Writes now (tests and quitting); otherwise changes are saved a second after the last one.
    func saveNow() throws {
        pending?.cancel()
        pending = nil
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder().encode(prefs).write(to: fileURL, options: .atomic)
    }

    private func scheduleSave() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            try? self?.saveNow()
        }
    }

    private func change(_ body: (inout UserPreferences) -> Void) {
        body(&prefs)
        scheduleSave()
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: Changes

    func setEditor(_ e: Editor) { change { $0.editor = e } }

    func setAside(_ i: Insight, note: String, date: Date = .now) {
        change { $0.setAside[i.id] = Dismissal(date: date, note: note.trimmingCharacters(in: .whitespacesAndNewlines), insight: i) }
    }

    func bringBack(_ id: String) { change { $0.setAside[id] = nil } }

    func toggle(_ tag: IntentTag, for p: PhotoRecord) {
        change { prefs in
            var set = prefs.intents[p.key] ?? []
            if set.contains(tag) { set.remove(tag) } else { set.insert(tag) }
            prefs.intents[p.key] = set.isEmpty ? nil : set
        }
    }

    func reset() {
        prefs = UserPreferences()
        scheduleSave()
    }

    /// Counts a newly loaded library's photos into the active checks.
    func ingest(_ library: PhotoLibrary) {
        guard prefs.checks.contains(where: { $0.status == .active }) else { return }
        let updated = CheckComparison.ingest(prefs.checks, library: library, intents: prefs.intents)
        if updated != prefs.checks { change { $0.checks = updated } }
    }

    func startCheck(_ c: CaptureCheck) { change { $0.checks.append(c) } }

    func setStatus(_ status: CaptureCheck.Status, check id: UUID) {
        change { prefs in
            if let i = prefs.checks.firstIndex(where: { $0.id == id }) { prefs.checks[i].status = status }
        }
    }

    /// Replaces the preferences wholesale (capture checks update through here).
    func update(_ body: (inout UserPreferences) -> Void) { change(body) }
}
