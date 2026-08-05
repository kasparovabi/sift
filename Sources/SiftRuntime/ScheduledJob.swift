import Foundation

/// A recurring task: run `prompt` in `cwd` every `everyMinutes` (while the app is open).
/// Fires through the same headless runner as Hızlı görev.
public struct ScheduledJob: Identifiable, Codable, Sendable, Equatable {
    public var id = UUID()
    public var title: String
    public var prompt: String
    public var cwd: String
    public var everyMinutes: Int
    public var enabled: Bool = true
    public var lastRun: Date? = nil
    public var lastResult: String? = nil

    /// A friendly Turkish cadence label ("Hourly", "Daily", "Every 15 minutes").
    public var cadenceLabel: String {
        switch everyMinutes {
        case 1440: return "Daily"
        case 60:   return "Hourly"
        case let m where m % 1440 == 0: return "Every \(m / 1440) days"
        case let m where m % 60 == 0:   return "Every \(m / 60) hours"
        default:   return "Every \(everyMinutes) minutes"
        }
    }
}

enum ScheduledJobStore {
    private static let key = "sift.scheduledJobs"
    static func load() -> [ScheduledJob] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([ScheduledJob].self, from: data) else { return [] }
        return list
    }
    static func save(_ list: [ScheduledJob]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }
}
