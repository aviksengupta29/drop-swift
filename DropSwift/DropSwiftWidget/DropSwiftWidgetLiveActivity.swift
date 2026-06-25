//
//  DropSwiftWidgetLiveActivity.swift
//  DropSwiftWidget  (Widget Extension target)
//
//  AirDrop-style transfer progress in the Dynamic Island and on the Lock Screen.
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
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    Logo(size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.state.done ? "Sent to \(context.attributes.serverName)"
                                                : "Sending to \(context.attributes.serverName)")
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.state.done ? "\(context.state.completed) items complete"
                                                : "\(context.state.completed) of \(context.state.total) items")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text("\(Int(context.state.fraction * 100))%")
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(context.state.done ? Color.green : accent)
                }
                ThickBar(fraction: context.state.fraction, done: context.state.done)
            }
            .padding(18)
            .activityBackgroundTint(Color.black.opacity(0.45))
            .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Logo(size: 26)
                        Text("DropSwift").font(.subheadline.weight(.semibold))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(Int(context.state.fraction * 100))%")
                        .font(.subheadline.weight(.bold)).monospacedDigit()
                        .foregroundStyle(context.state.done ? Color.green : accent)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        ThickBar(fraction: context.state.fraction, done: context.state.done)
                        Text(context.state.done
                             ? "Sent \(context.state.completed) items to \(context.attributes.serverName)"
                             : "Sending \(context.state.completed) of \(context.state.total) to \(context.attributes.serverName)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                Logo(size: 20)
            } compactTrailing: {
                ProgressRing(fraction: context.state.fraction, size: 18, line: 2.5)
            } minimal: {
                ProgressRing(fraction: context.state.fraction, size: 18, line: 2.5)
            }
            .keylineTint(accent)
        }
    }
}

// MARK: - Pieces

/// The DropSwift app logo (rounded).
struct Logo: View {
    var size: CGFloat
    var body: some View {
        Image("AppLogo")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

/// Thick AirDrop-style progress bar.
struct ThickBar: View {
    let fraction: Double
    var done: Bool = false
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule()
                    .fill(done ? Color.green : accent)
                    .frame(width: max(11, geo.size.width * max(0, min(1, fraction))))
                    .animation(.easeInOut(duration: 0.3), value: fraction)
            }
        }
        .frame(height: 11)
    }
}

/// Circular progress ring for the compact / minimal Dynamic Island.
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
