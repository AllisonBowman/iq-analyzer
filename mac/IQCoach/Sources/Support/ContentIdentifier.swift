import Foundation
import ImageIO
import Vision

struct ContentLabel: Sendable, Hashable {
    let label: String
    let confidence: Double
}

/// What Vision found in one photo. Recognised text strings are deliberately never kept.
struct ContentSummary: Sendable, Hashable {
    var available: Bool
    var reason: String?
    var labels: [ContentLabel] = []
    var faceCount: Int = 0
    var textObservationCount: Int = 0
    /// Angle of the detected horizon in degrees (Vision's sign convention), nil when none was found.
    var horizonDegrees: Double?
    /// First salient object, normalised, origin top-left.
    var salientBox: CGRect?

    static func unavailable(_ reason: String) -> ContentSummary { ContentSummary(available: false, reason: reason) }
    var hasText: Bool { textObservationCount > 0 }

    /// "2 faces · text present · horizon 1.4° off level"; nil when nothing applies.
    var summaryLine: String? {
        let s = self
        var parts: [String] = []
        if s.faceCount > 0 { parts.append(Fmt.count(s.faceCount, "face")) }
        if s.hasText { parts.append("text present") }
        if let h = s.horizonDegrees { parts.append("horizon \(Fmt.num(abs(h), 1))° off level") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// On-device content identification with Apple's Vision framework. No network. Results are cached per path.
actor ContentIdentifier {
    static let shared = ContentIdentifier()

    static let minConfidence = 0.25
    static let maxLabels = 8
    static let longSide = 1600

    private var summaries: [String: ContentSummary] = [:]
    private var labelCache: [String: [ContentLabel]] = [:]

    /// Full identification. Never throws; failures come back as `available == false`.
    func summary(path: String) async -> ContentSummary {
        if let hit = summaries[path] { return hit }
        let result = await Task.detached(priority: .userInitiated) { Self.analyze(path: path, full: true) }.value
        if result.available {
            summaries[path] = result
            labelCache[path] = result.labels
        }
        return result
    }

    /// Classification only (cheap), for the per-camera "What you photograph" row.
    func labels(path: String) async -> [ContentLabel]? {
        if let hit = labelCache[path] { return hit }
        if let full = summaries[path] { return full.labels }
        let result = await Task.detached(priority: .utility) { Self.analyze(path: path, full: false) }.value
        guard result.available else { return nil }
        labelCache[path] = result.labels
        return result.labels
    }

    // MARK: Work (runs off the actor)

    nonisolated static func downsampled(path: String) -> CGImage? {
        guard FileManager.default.fileExists(atPath: path),
              let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    nonisolated static func analyze(path: String, full: Bool) -> ContentSummary {
        guard FileManager.default.fileExists(atPath: path) else { return .unavailable("The file is not at its recorded path.") }
        guard let image = downsampled(path: path) else { return .unavailable("The image could not be read.") }

        let classify = VNClassifyImageRequest()
        var requests: [VNRequest] = [classify]
        let faces = VNDetectFaceRectanglesRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = false
        let horizon = VNDetectHorizonRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        if full { requests += [faces, text, horizon, saliency] }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform(requests)
        } catch {
            // A single failing request (for example saliency on an odd image) should not hide the rest.
            if (classify.results ?? []).isEmpty {
                return .unavailable("Vision could not analyse this image: \(error.localizedDescription)")
            }
        }

        var s = ContentSummary(available: true)
        s.labels = (classify.results ?? [])
            .filter { Double($0.confidence) >= minConfidence }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxLabels)
            .map { ContentLabel(label: $0.identifier, confidence: Double($0.confidence)) }
        guard full else { return s }
        s.faceCount = faces.results?.count ?? 0
        s.textObservationCount = text.results?.count ?? 0
        if let h = horizon.results?.first {
            s.horizonDegrees = Double(h.angle) * 180 / .pi
        }
        if let box = saliency.results?.first?.salientObjects?.first?.boundingBox {
            s.salientBox = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        }
        return s
    }
}
