import WidgetKit
import SwiftUI
import ActivityKit

@main
struct PrismWidgets: WidgetBundle {
    var body: some Widget {
        DownloadActivityWidget()
        ContinueWatchingWidget()
    }
}

private let spectrum = LinearGradient(
    colors: [Color(red: 1, green: 0.30, blue: 0.43), Color(red: 1, green: 0.65, blue: 0.17),
             Color(red: 1, green: 0.89, blue: 0.36), Color(red: 0.24, green: 0.94, blue: 0.63),
             Color(red: 0.24, green: 0.66, blue: 1), Color(red: 0.61, green: 0.36, blue: 1)],
    startPoint: .leading, endPoint: .trailing)

struct DownloadActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: context.state.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(spectrum)
                VStack(alignment: .leading, spacing: 6) {
                    Text(context.state.finished ? "Downloads ready" : "Downloading \(context.state.title)")
                        .font(.headline).lineLimit(1)
                    ProgressView(value: context.state.progress)
                        .tint(Color(red: 0.42, green: 0.55, blue: 1))
                    Text(context.state.finished ? "Ready to watch offline"
                         : context.state.remaining > 1 ? "\(context.state.remaining) items left" : "Last one")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .activityBackgroundTint(Color(red: 0.035, green: 0.031, blue: 0.067))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(spectrum)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(Int(context.state.progress * 100))%").font(.title3.monospacedDigit().weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.finished ? "Downloads ready" : context.state.title).font(.subheadline).lineLimit(1)
                        ProgressView(value: context.state.progress).tint(Color(red: 0.42, green: 0.55, blue: 1))
                    }
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(spectrum)
            } compactTrailing: {
                Text("\(Int(context.state.progress * 100))%").font(.caption2.monospacedDigit())
            } minimal: {
                ProgressView(value: context.state.progress).progressViewStyle(.circular)
                    .tint(Color(red: 0.42, green: 0.55, blue: 1))
            }
        }
    }
}
