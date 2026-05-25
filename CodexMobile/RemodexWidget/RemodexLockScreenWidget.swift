// FILE: RemodexLockScreenWidget.swift
// Purpose: Lock Screen / Always-On accessory widget that surfaces the Remodex
//          outline logo. Tapping the widget launches Remodex on the host
//          device. Three accessory families are supported so the user can pick
//          the layout that fits their Lock Screen.
// Layer: Widget Extension

import SwiftUI
import WidgetKit
import ActivityKit

struct RemodexLockScreenEntry: TimelineEntry {
    let date: Date
}

struct RemodexLockScreenProvider: TimelineProvider {
    func placeholder(in context: Context) -> RemodexLockScreenEntry {
        RemodexLockScreenEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (RemodexLockScreenEntry) -> Void) {
        completion(RemodexLockScreenEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RemodexLockScreenEntry>) -> Void) {
        // Static branding widget — no time-based refresh required.
        let timeline = Timeline(entries: [RemodexLockScreenEntry(date: Date())], policy: .never)
        completion(timeline)
    }
}

struct RemodexLockScreenWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RemodexLockScreenEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                circularBody
            case .accessoryRectangular:
                rectangularBody
            case .accessoryInline:
                inlineBody
            default:
                EmptyView()
            }
        }
        .containerBackground(.clear, for: .widget)
    }

    private var circularBody: some View {
        // Keep the circular accessory as a bare glyph; the Lock Screen slot
        // already supplies the surrounding widget chrome.
        Image("remodex-outline")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .widgetAccentable()
    }

    private var rectangularBody: some View {
        HStack(spacing: 8) {
            Image("remodex-outline")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 28, height: 28)
                .widgetAccentable()

            VStack(alignment: .leading, spacing: 0) {
                Text("Remodex")
                    .font(.headline)
                    .lineLimit(1)
                Text("Open Codex chat")
                    .font(.caption)
                    .opacity(0.8)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var inlineBody: some View {
        // Inline accessories collapse to a single line next to the clock; the
        // image is auto-tinted by the system.
        Label("Remodex", image: "remodex-outline")
    }
}

struct RemodexLockScreenWidget: Widget {
    static let kind = "com.emanueledipietro.Remodex.RemodexWidget.LockScreen"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: RemodexLockScreenProvider()) { entry in
            RemodexLockScreenWidgetView(entry: entry)
        }
        .configurationDisplayName("Remodex")
        .description("Quick access to Remodex from your Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct RemodexDisplayIslandLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RemodexDisplayIslandAttributes.self) { context in
            RemodexDisplayIslandLockScreenView(state: context.state)
                .activityBackgroundTint(Color(red: 0.05, green: 0.055, blue: 0.06))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.state.primaryThreadURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RemodexDisplayIslandCountView(
                        value: context.state.runningConversations.count,
                        title: "Running",
                        tint: .green
                    )
                    .padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RemodexDisplayIslandCountView(
                        value: context.state.completedConversations.count + context.state.failedConversations.count,
                        title: "Review",
                        tint: context.state.failedConversations.isEmpty ? .cyan : .orange
                    )
                    .padding(.trailing, 8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RemodexDisplayIslandExpandedList(state: context.state)
                        .padding(.horizontal, 8)
                }
            } compactLeading: {
                RemodexDisplayIslandMark()
            } compactTrailing: {
                Text(compactStatusText(for: context.state))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
            } minimal: {
                RemodexDisplayIslandMark()
            }
            .keylineTint(.green)
            .widgetURL(context.state.primaryThreadURL)
        }
    }

    private func compactStatusText(for state: RemodexDisplayIslandAttributes.ContentState) -> String {
        let runningCount = state.runningConversations.count
        if runningCount > 0 {
            return "\(runningCount)"
        }
        if !state.failedConversations.isEmpty {
            return "!"
        }
        return "\(state.completedConversations.count)"
    }
}

private struct RemodexDisplayIslandLockScreenView: View {
    let state: RemodexDisplayIslandAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                RemodexDisplayIslandMark()
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Remodex")
                        .font(.headline.weight(.semibold))
                    Text(headerSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            RemodexDisplayIslandExpandedList(state: state)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var headerSubtitle: String {
        let running = state.runningConversations.count
        let completed = state.completedConversations.count
        let failed = state.failedConversations.count
        if failed > 0, running > 0 {
            return "\(running) running, \(failed) failed"
        }
        if failed > 0 {
            return failed == 1 ? "1 conversation failed" : "\(failed) conversations failed"
        }
        if running > 0, completed > 0 {
            return "\(running) running, \(completed) ready"
        }
        if running > 0 {
            return running == 1 ? "1 conversation running" : "\(running) conversations running"
        }
        return completed == 1 ? "1 conversation ready" : "\(completed) conversations ready"
    }
}

private struct RemodexDisplayIslandExpandedList: View {
    let state: RemodexDisplayIslandAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(displayRows) { row in
                if let url = row.threadURL {
                    Link(destination: url) {
                        RemodexDisplayIslandRow(conversation: row)
                    }
                } else {
                    RemodexDisplayIslandRow(conversation: row)
                }
            }
        }
    }

    private var displayRows: [RemodexDisplayIslandConversation] {
        Array((state.runningConversations + state.failedConversations + state.completedConversations).prefix(3))
    }
}

private struct RemodexDisplayIslandRow: View {
    let conversation: RemodexDisplayIslandConversation

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(conversation.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(conversation.detail.isEmpty ? conversation.state : conversation.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 1) {
                Text(conversation.state)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(tint)
                    .lineLimit(1)

                if let runningStartedAt = conversation.runningStartedAt {
                    Text(runningStartedAt, style: .timer)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                }
            }
            .frame(width: 62, alignment: .trailing)
        }
    }

    private var tint: Color {
        switch conversation.state {
        case "Ready":
            return .cyan
        case "Failed":
            return .orange
        default:
            return .green
        }
    }
}

private struct RemodexDisplayIslandCountView: View {
    let value: Int
    let title: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.headline.weight(.bold))
                .monospacedDigit()
            Text(title)
                .font(.caption2)
                .foregroundStyle(tint)
        }
    }
}

private struct RemodexDisplayIslandMark: View {
    var body: some View {
        Image("remodex-outline")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(.white)
    }
}

#if DEBUG
#Preview("Circular", as: .accessoryCircular) {
    RemodexLockScreenWidget()
} timeline: {
    RemodexLockScreenEntry(date: Date())
}

#Preview("Rectangular", as: .accessoryRectangular) {
    RemodexLockScreenWidget()
} timeline: {
    RemodexLockScreenEntry(date: Date())
}

#Preview("Inline", as: .accessoryInline) {
    RemodexLockScreenWidget()
} timeline: {
    RemodexLockScreenEntry(date: Date())
}
#endif
