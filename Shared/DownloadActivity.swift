import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// Download progress on the Lock Screen and in the Dynamic Island.
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var progress: Double
        var remaining: Int
        var finished: Bool
    }
    var startedAt: Date
}
#endif
