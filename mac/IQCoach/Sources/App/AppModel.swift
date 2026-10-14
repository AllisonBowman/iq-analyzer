import SwiftUI
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
    var progress: AnalysisProgress?
    private var analysisTask: Task<Void, Never>?

    static let defaultPython = "~/Developer/iq-analyzer/.venv/bin/python"
    static let defaultRepo = "~/Developer/iq-analyzer"

    var selectedCamera: CameraGroup? {
        guard case .camera(let m)? = sidebarSelection else { return nil }
        return library?.camera(m)
    }

    var selectedPhoto: PhotoRecord? {
        guard let id = selectedPhotoID else { return nil }
        return selectedCamera?.photos.first { $0.id == id }
    }

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
            library = PhotoLibrary(sourceName: url.lastPathComponent, photos: photos)
            sidebarSelection = .library
            selectedPhotoID = nil
        } catch {
            errorMessage = "Could not read \(url.lastPathComponent) as iqa results: \(error.localizedDescription)"
        }
    }

    func analyze(folder: URL) {
        let defaults = UserDefaults.standard
        let runner = AnalyzerRunner(python: defaults.string(forKey: "pythonPath") ?? Self.defaultPython,
                                    repo: defaults.string(forKey: "repoPath") ?? Self.defaultRepo)
        progress = AnalysisProgress()
        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let json = try await runner.analyze(folder: folder) { line in
                    Task { @MainActor in self.record(line: line) }
                }
                self.progress = nil
                self.load(url: json)
            } catch {
                self.progress?.failure = error.localizedDescription
                self.progress?.finished = true
            }
        }
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

    func cancelAnalysis() {
        analysisTask?.cancel()
        progress = nil
    }
}
