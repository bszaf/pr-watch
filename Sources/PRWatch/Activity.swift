import Foundation

/// A single PR state change worth recording. Independent of notification toggles —
/// the activity feed logs every transition; banners are a filtered subset.
enum ActivityKind: String, Codable, Sendable {
    case ciPassed, ciFailed
    case approved, changesRequested, reviewRequested
    case conflict

    var label: String {
        switch self {
        case .ciPassed: "CI passed"
        case .ciFailed: "CI failed"
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .reviewRequested: "Review requested"
        case .conflict: "Merge conflict"
        }
    }

    var symbol: String {
        switch self {
        case .ciPassed: "checkmark.circle.fill"
        case .ciFailed: "xmark.circle.fill"
        case .approved: "hand.thumbsup.fill"
        case .changesRequested: "hand.raised.fill"
        case .reviewRequested: "eye.fill"
        case .conflict: "exclamationmark.triangle.fill"
        }
    }
}

struct ActivityEvent: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    let date: Date
    let prId: String
    let repo: String
    let number: Int
    var ref: String?          // "#123" / "!123"; optional for backward-compat with v1 files
    let title: String
    let url: String
    let kind: ActivityKind
}

/// Persists the activity feed to a versioned JSON file under Application Support.
/// The `version` field lets us drop/migrate cleanly if the on-disk format changes.
enum ActivityStore {
    static let version = 1

    /// ~/Library/Application Support/PRWatch/activity.json
    static var fileURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PRWatch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("activity.json")
    }

    private struct Envelope: Codable {
        var version: Int
        var events: [ActivityEvent]
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func load() -> [ActivityEvent] {
        guard let data = try? Data(contentsOf: fileURL),
              let env = try? decoder.decode(Envelope.self, from: data),
              env.version == version   // unknown/newer format → start fresh rather than crash
        else { return [] }
        return env.events
    }

    static func save(_ events: [ActivityEvent]) {
        guard let data = try? encoder.encode(Envelope(version: version, events: events)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
