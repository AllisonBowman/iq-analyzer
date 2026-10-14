import SwiftUI
import AppKit

/// Renders the four screens to PNG with ImageRenderer so the build can be checked without a GUI session.
@MainActor
enum SnapshotRunner {
    static let width: CGFloat = 1400
    static let minHeight: CGFloat = 900

    static func run(input: String, outputDirectory: String) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: input))
            let photos = try PhotoRecord.decodeAll(from: data)
            let library = PhotoLibrary(sourceName: URL(fileURLWithPath: input).lastPathComponent, photos: photos)
            let dir = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let cam = library.cameras.first, let photo = cam.photos.sorted(by: { $0.file < $1.file }).first else {
                FileHandle.standardError.write(Data("No photos in \(input)\n".utf8)); return 1
            }
            var written: [URL] = []
            written.append(try render(canvas(library, selected: .library) {
                LibraryOverviewView(library: library)
            }, to: dir.appendingPathComponent("library.png")))
            written.append(try render(canvas(library, selected: .camera(cam.model)) {
                CameraReportView(camera: cam, selectedPhotoID: .constant(nil))
            }, to: dir.appendingPathComponent("camera-\(slug(cam.model)).png")))
            written.append(try render(AnyView(
                PhotoDetailView(photo: photo)
                    .frame(width: 760)
                    .padding(.vertical, 24)
                    .frame(width: width)
                    .frame(minHeight: minHeight, alignment: .top)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.isSnapshot, true)
                    .environment(\.colorScheme, .light)),
                to: dir.appendingPathComponent("photo-\(slug((photo.file as NSString).deletingPathExtension)).png")))
            written.append(try render(AnyView(
                GlossaryView()
                    .frame(width: width)
                    .frame(minHeight: minHeight, alignment: .top)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.isSnapshot, true)
                    .environment(\.colorScheme, .light)),
                to: dir.appendingPathComponent("glossary.png")))
            for u in written { print("wrote \(u.path)") }
            return 0
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            return 1
        }
    }

    private static func slug(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    private static func canvas<Content: View>(_ library: PhotoLibrary, selected: SidebarItem, @ViewBuilder content: () -> Content) -> AnyView {
        AnyView(
            HStack(alignment: .top, spacing: 0) {
                StaticSidebar(library: library, selected: selected).frame(width: 240)
                Divider()
                content().frame(width: width - 241, alignment: .topLeading)
            }
            .frame(width: width, alignment: .topLeading)
            .frame(minHeight: minHeight, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.isSnapshot, true)
            .environment(\.colorScheme, .light)
        )
    }

    private static func render(_ view: AnyView, to url: URL) throws -> URL {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        guard let cg = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
        return url
    }
}

/// The sidebar as plain views, because List cannot draw off-screen.
private struct StaticSidebar: View {
    let library: PhotoLibrary
    let selected: SidebarItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Library", "square.grid.2x2", library.photos.count, selected == .library)
            Text("Cameras").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 12).padding(.horizontal, 12)
            ForEach(library.cameras) { c in
                row(c.model, "camera", c.photos.count, selected == .camera(c.model))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func row(_ title: String, _ symbol: String, _ n: Int, _ on: Bool) -> some View {
        HStack {
            Label(title, systemImage: symbol).lineLimit(1)
            Spacer()
            Text(n.formatted()).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(on ? AnyShapeStyle(.selection.opacity(0.35)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
    }
}
