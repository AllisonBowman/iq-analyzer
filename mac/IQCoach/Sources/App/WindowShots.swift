import SwiftUI
import AppKit

/// Captures the live window (real AppKit controls, unlike the ImageRenderer snapshots) for verification.
/// Needs an awake, unlocked display: SwiftUI does not run the window's task until it is drawn.
@MainActor
enum WindowShots {
    nonisolated(unsafe) static var request: (input: String, outdir: String)?
    nonisolated(unsafe) static var logURL = URL(fileURLWithPath: "/tmp/iqcoach-window-shots.log")

    static func runIfRequested(model: AppModel) async {
        guard let req = request else { return }
        request = nil
        trace("window-shots: start")
        let dir = URL(fileURLWithPath: req.outdir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logURL = dir.appendingPathComponent("window-shots.log")
        model.load(url: URL(fileURLWithPath: req.input))
        trace("window-shots: loaded \(model.library?.photos.count ?? -1) photos; error=\(model.errorMessage ?? "none")")
        try? await Task.sleep(for: .milliseconds(800))
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.isVisible }) {
            w.setContentSize(NSSize(width: 1500, height: 940))
            w.center()
        }
        try? await Task.sleep(for: .milliseconds(1200))
        capture(to: dir.appendingPathComponent("window-library.png"))
        if let cam = model.library?.cameras.first {
            model.sidebarSelection = .camera(cam.model)
            try? await Task.sleep(for: .milliseconds(1500))
            capture(to: dir.appendingPathComponent("window-camera.png"))
            if let photo = cam.photos.sorted(by: { $0.file < $1.file }).first {
                model.selectedPhotoID = photo.id
                try? await Task.sleep(for: .milliseconds(1500))
                capture(to: dir.appendingPathComponent("window-photo.png"))
            }
        }
        exit(0)
    }

    static func trace(_ s: String) {
        let line = Data((s + "\n").utf8)
        FileHandle.standardError.write(line)
        let log = logURL
        if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(line); try? h.close() } else { try? line.write(to: log) }
    }

    private static func capture(to url: URL) {
        guard let w = NSApp.windows.first(where: { $0.isVisible }), let v = w.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { print("no window to capture"); return }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url); print("wrote \(url.path)")
        }
    }
}
