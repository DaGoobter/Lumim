import Foundation
import ActivityKit

/// Shows download progress on the Lock Screen and Dynamic Island while downloads run.
@MainActor
final class DownloadActivityController {
    static let shared = DownloadActivityController()
    private var activity: Activity<DownloadActivityAttributes>?
    private var lastUpdate = Date.distantPast
    private var lastState: DownloadActivityAttributes.ContentState?

    func refresh(_ records: [DownloadRecord]) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let active = records.filter { $0.state == .downloading || $0.state == .queued }
        if active.isEmpty {
            guard let activity else { return }
            let done = DownloadActivityAttributes.ContentState(title: "", progress: 1, remaining: 0, finished: true)
            Task { await activity.end(ActivityContent(state: done, staleDate: nil), dismissalPolicy: .after(.now + 8)) }
            self.activity = nil
            lastState = nil
            return
        }
        let current = active.first { $0.state == .downloading } ?? active[0]
        let progress = active.map(\.progress).reduce(0, +) / Double(active.count)
        let state = DownloadActivityAttributes.ContentState(title: current.item.displayTitle,
                                                            progress: min(1, max(0, progress)),
                                                            remaining: active.count, finished: false)
        if let activity {
            // Don't flood the system with updates.
            guard Date().timeIntervalSince(lastUpdate) > 2 || state.remaining != lastState?.remaining else { return }
            lastUpdate = Date()
            lastState = state
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
        } else {
            activity = try? Activity.request(attributes: DownloadActivityAttributes(startedAt: Date()),
                                             content: ActivityContent(state: state, staleDate: nil), pushType: nil)
            lastUpdate = Date()
            lastState = state
        }
    }
}
