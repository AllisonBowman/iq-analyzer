import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var visibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        Group {
            if let library = model.library {
                NavigationSplitView(columnVisibility: $visibility) {
                    SidebarView(library: library, selection: $model.sidebarSelection, search: search)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
                } content: {
                    contentColumn(library)
                        .navigationSplitViewColumnWidth(min: 520, ideal: 720)
                } detail: {
                    detailColumn
                        .navigationSplitViewColumnWidth(min: 340, ideal: 420)
                }
                .searchable(text: $search, placement: .sidebar, prompt: "Search cameras")
                .navigationTitle(model.selectedCamera?.model ?? "Library")
                .onChange(of: model.sidebarSelection) { model.selectedPhotoID = nil }
            } else {
                EmptyStateView()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.isImporting = true } label: { Label("Open Results…", systemImage: "doc.badge.plus") }
                    .help("Open a results.json (⌘O)")
                Button { model.isChoosingFolder = true } label: { Label("Analyze Folder…", systemImage: "folder.badge.gearshape") }
                    .help("Run the analyzer on a folder of photos (⇧⌘O)")
                Button { model.isPickingPhotos = true } label: { Label("Choose Photos…", systemImage: "photo.on.rectangle.angled") }
                    .help("Pick up to \(AppModel.maxPickedPhotos) photos from your Photos library to analyze (⇧⌘P)")
                if let cam = model.selectedCamera {
                    ShareLink(item: MarkdownExport.coaching(for: cam, insights: CoachingEngine.insights(for: cam)),
                              subject: Text("Coaching for \(cam.model)")) {
                        Label("Share Coaching", systemImage: "square.and.arrow.up")
                    }
                    .help("Share this camera's coaching as Markdown")
                }
            }
        }
        .fileImporter(isPresented: $model.isImporting, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): model.load(url: url)
            case .failure(let e): model.errorMessage = e.localizedDescription
            }
        }
        .photosPicker(isPresented: $model.isPickingPhotos, selection: $model.pickedPhotos,
                      maxSelectionCount: AppModel.maxPickedPhotos, matching: .images, preferredItemEncoding: .current)
        .onChange(of: model.pickedPhotos) { _, items in model.analyze(picked: items) }
        .fileImporter(isPresented: $model.isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.analyze(folder: url) }
        }
        .sheet(isPresented: Binding(get: { model.progress != nil }, set: { if !$0 { model.cancelAnalysis() } })) {
            AnalysisSheet()
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
        .task {
            if let n = LaunchOptions.analyzePhotosCount { model.analyzeFromPhotos(count: n) }
            await WindowShots.runIfRequested(model: model)
        }
    }

    @ViewBuilder private func contentColumn(_ library: PhotoLibrary) -> some View {
        @Bindable var model = model
        if let cam = model.selectedCamera {
            CameraReportView(camera: cam, selectedPhotoID: $model.selectedPhotoID)
        } else {
            LibraryOverviewView(library: library)
        }
    }

    @ViewBuilder private var detailColumn: some View {
        if let photo = model.selectedPhoto {
            PhotoDetailView(photo: photo)
        } else {
            ContentUnavailableView(model.selectedCamera == nil ? "Choose a camera" : "Choose a photo",
                                   systemImage: model.selectedCamera == nil ? "camera" : "photo",
                                   description: Text(model.selectedCamera == nil ? "Pick a camera in the sidebar for its report card and coaching." : "Select a row in the Photos table to see its measurements and editing advice."))
        }
    }
}

struct SidebarView: View {
    let library: PhotoLibrary
    @Binding var selection: SidebarItem?
    let search: String

    private var cameras: [CameraGroup] {
        search.isEmpty ? library.cameras : library.cameras.filter { $0.model.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List(selection: $selection) {
            Label("Library", systemImage: "square.grid.2x2")
                .badge(library.photos.count)
                .tag(SidebarItem.library)
            Section("Cameras") {
                ForEach(cameras) { c in
                    Label(c.model, systemImage: "camera")
                        .badge(c.photos.count)
                        .tag(SidebarItem.camera(c.model))
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ContentUnavailableView {
            Label("No results yet", systemImage: "camera.aperture")
        } description: {
            Text("IQ Coach reads the sharpness, noise and exposure measurements iqa made of your photos, then tells you what each camera does well and badly, what to change when you shoot, and what to do in your editing app.")
        } actions: {
            Button("Open Results…") { model.isImporting = true }
                .buttonStyle(.borderedProminent)
            Button("Analyze Folder…") { model.isChoosingFolder = true }
            Button("Choose Photos to Analyze…") { model.isPickingPhotos = true }
        }
        .padding(24)
    }
}

struct AnalysisSheet: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let p = model.progress ?? AnalysisProgress()
        VStack(alignment: .leading, spacing: 16) {
            Text(p.failure == nil ? "Analyzing photos" : "The analysis did not finish").font(.title2.weight(.semibold))
            if let failure = p.failure {
                Label(failure, systemImage: "exclamationmark.triangle").fixedSize(horizontal: false, vertical: true)
            } else if p.total > 0 {
                ProgressView(value: Double(p.done), total: Double(p.total)) {
                    Text("\(p.done.formatted()) of \(p.total.formatted()) photos")
                }
            } else {
                ProgressView("Starting Python…")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(p.lines.suffix(40).enumerated()), id: \.offset) { _, l in
                        Text(l).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 140)
            .padding(8)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button(p.failure == nil ? "Cancel" : "Close", role: .cancel) { model.cancelAnalysis() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
