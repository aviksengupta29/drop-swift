//
//  DropSwiftWidgetLiveActivity.swift
//  DropSwiftWidget  (Widget Extension target)
//
//  Renders the AirDrop-style transfer progress in the Dynamic Island and on the
//  Lock Screen. Add this file (and TransferActivityAttributes.swift) to the
//  widget extension target.
//

import ActivityKit
import WidgetKit
import SwiftUI

private let accent = Color(red: 0.42, green: 0.28, blue: 1.0)

@main
struct DropSwiftWidgetBundle: WidgetBundle {
    var body: some Widget {
        DropSwiftTransferLiveActivity()
    }
}

struct DropSwiftTransferLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TransferActivityAttributes.self) { context in
            // Lock Screen / banner presentation.
            HStack(spacing: 14) {
                ProgressRing(fraction: context.state.fraction, size: 42, line: 4)
                    .overlay {
                        Image(systemName: context.state.done ? "checkmark" : "paperplane.fill")
                            .font(.caption).foregroundStyle(accent)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.state.done ? "Sent to \(context.attributes.serverName)"
                                            : "Sending to \(context.attributes.serverName)")
                        .font(.subheadline.weight(.semibold))
                    Text(context.state.done ? "\(context.state.completed) items"
                                            : "\(context.state.completed) of \(context.state.total)  •  \(Int(context.state.fraction * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: context.state.fraction).tint(accent)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.35))
            .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("DropSwift", systemImage: "paperplane.fill")
                        .font(.caption).foregroundStyle(accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(Int(context.state.fraction * 100))%")
                        .font(.caption.weight(.semibold)).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: context.state.fraction).tint(accent)
                        Text(context.state.done
                             ? "Sent \(context.state.completed) items to \(context.attributes.serverName)"
                             : "Sending \(context.state.completed) of \(context.state.total) to \(context.attributes.serverName)")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: "paperplane.fill").foregroundStyle(accent)
            } compactTrailing: {
                ProgressRing(fraction: context.state.fraction, size: 18, line: 2.5)
            } minimal: {
                ProgressRing(fraction: context.state.fraction, size: 18, line: 2.5)
            }
            .keylineTint(accent)
        }
    }
}

/// Circular progress ring (AirDrop style).
struct ProgressRing: View {
    let fraction: Double
    var size: CGFloat = 18
    var line: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: line)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(accent, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: fraction)
        }
        .frame(width: size, height: size)
    }
}
