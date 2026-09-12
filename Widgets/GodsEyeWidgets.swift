import ActivityKit
import SwiftUI
import WidgetKit

@main
struct GodsEyeWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TrackLiveActivity()
    }
}

struct TrackLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrackActivityAttributes.self) { ctx in
            LockScreenView(ctx: ctx)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.green)
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(ctx.attributes.kind, systemImage: "scope").font(.caption.monospaced()).foregroundStyle(.green)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(ctx.state.updated, style: .relative).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ctx.attributes.title).font(.headline.monospaced())
                        Text(ctx.state.summary).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                        Text(String(format: "%.4f, %.4f", ctx.state.lat, ctx.state.lon)).font(.caption2.monospaced()).foregroundStyle(.green)
                    }
                }
            } compactLeading: {
                Image(systemName: "scope").foregroundStyle(.green)
            } compactTrailing: {
                Text(ctx.attributes.title).font(.caption2.monospaced()).lineLimit(1)
            } minimal: {
                Image(systemName: "scope").foregroundStyle(.green)
            }
        }
    }
}

struct LockScreenView: View {
    let ctx: ActivityViewContext<TrackActivityAttributes>
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "scope").font(.title2).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text("TRACKING · \(ctx.attributes.kind)").font(.caption2.monospaced().bold()).foregroundStyle(.green)
                Text(ctx.attributes.title).font(.headline.monospaced())
                Text(ctx.state.summary).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(String(format: "%.3f", ctx.state.lat)).font(.caption2.monospaced())
                Text(String(format: "%.3f", ctx.state.lon)).font(.caption2.monospaced())
                Text(ctx.state.updated, style: .relative).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }
}
