import Foundation

struct UpdateSchedule {
    private static let day: TimeInterval = 24 * 60 * 60
    private static let reminderKey = "deferredUpdateReminder"
    let defaults: UserDefaults

    func remindLater(about build: String, now: Date = .now) {
        defaults.set([build: now.addingTimeInterval(Self.day)], forKey: Self.reminderKey)
    }

    func isDeferred(_ build: String, now: Date = .now) -> Bool {
        guard let date = reminder[build] else { return false }
        return date > now
    }

    func nextCheckDelay(after error: (any Error)?, now: Date = .now) -> TimeInterval {
        let interval: TimeInterval = Self.isTransientNetworkError(error) ? 15 * 60 : Self.day
        guard let date = reminder.values.first, date > now else { return interval }
        return min(interval, date.timeIntervalSince(now))
    }

    // Keep the build and its deadline together across launches. Only the last deferral matters.
    private var reminder: [String: Date] {
        defaults.dictionary(forKey: Self.reminderKey) as? [String: Date] ?? [:]
    }

    private static func isTransientNetworkError(_ error: (any Error)?) -> Bool {
        var cause = error as NSError?
        while let current = cause {
            if current.domain == NSURLErrorDomain {
                switch URLError.Code(rawValue: current.code) {
                case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                     .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                    return true
                default: return false
                }
            }
            // Sparkle wraps the transport error in its own download error.
            cause = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
