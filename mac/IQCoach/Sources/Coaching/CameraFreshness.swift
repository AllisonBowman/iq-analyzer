import Foundation

/// How recently a camera was used (docs/MEMORY-SPEC.md §8 item 1): Active up to 90 days since its newest dated photo,
/// Resting up to 365, Dormant beyond. It only adds a sentence before the advice; the coaching itself is unchanged.
enum CameraFreshness: String, Sendable, Equatable, CaseIterable {
    case active, resting, dormant

    static let activeDays = 90
    static let restingDays = 365

    static func state(days: Int) -> CameraFreshness {
        days <= activeDays ? .active : (days <= restingDays ? .resting : .dormant)
    }

    /// Whole calendar days from `last` to `now` (a future-dated photo counts as 0).
    static func days(from last: Date, to now: Date, calendar: Calendar = .current) -> Int {
        let d = calendar.dateComponents([.day], from: calendar.startOfDay(for: last), to: calendar.startOfDay(for: now)).day ?? 0
        return max(0, d)
    }

    /// nil when the camera has no dated photo.
    init?(lastDate: Date?, now: Date = .now, calendar: Calendar = .current) {
        guard let lastDate else { return nil }
        self = Self.state(days: Self.days(from: lastDate, to: now, calendar: calendar))
    }

    var word: String {
        switch self {
        case .active: "Active"
        case .resting: "Resting"
        case .dormant: "Dormant"
        }
    }

    /// A short tag for the library tile; nil for an active camera, which needs none.
    var tag: String? { self == .active ? nil : word }

    /// "You haven't shot with the iPhone 13 since 8 Jul 2026 (110 days). This advice comes from those photos; a new
    /// photo from this camera brings it up to date." nil for an active camera or one without dated photos.
    static func banner(camera: String, lastDate: Date?, now: Date = .now, calendar: Calendar = .current) -> String? {
        guard let lastDate, let state = CameraFreshness(lastDate: lastDate, now: now, calendar: calendar), state != .active else { return nil }
        let days = days(from: lastDate, to: now, calendar: calendar)
        return "You haven't shot with the \(camera) since \(Fmt.date(lastDate)) (\(Fmt.count(days, "day"))). This advice comes from those photos; a new photo from this camera brings it up to date."
    }
}

extension CameraGroup {
    func freshness(now: Date = .now) -> CameraFreshness? { CameraFreshness(lastDate: summary.lastDate, now: now) }
}
