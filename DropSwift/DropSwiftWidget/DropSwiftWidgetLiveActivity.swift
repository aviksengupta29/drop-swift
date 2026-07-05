//
//  DropSwiftWidgetLiveActivity.swift
//  DropSwiftWidget  (Widget Extension target)
//
//  A purpose-built Dynamic Island + Lock Screen experience for transfers —
//  glanceable, information-dense, and animated the way Apple's own (Music, Maps,
//  Timers) Live Activities are: numeric text transitions, a native ticking ETA,
//  a circular progress ring around the icon, and a clean completion morph.
//

import ActivityKit
import WidgetKit
import SwiftUI

private let accent = Color(red: 110/255, green: 75/255, blue: 1.0)   // #6E4BFF
private var accentGradient: LinearGradient {
    LinearGradient(colors: [Color(red: 131/255, green: 92/255, blue: 1.0), accent],
                   startPoint: .leading, endPoint: .trailing)
}

private func clamp(_ x: Double) -> Double { min(1, max(0, x)) }

/// "DropSwift on Aviks-MacBook-Pro.local" → "Aviks MacBook Pro".
private func deviceName(_ raw: String) -> String {
    var s = raw
    if s.hasPrefix("DropSwift on ") { s.removeFirst("DropSwift on ".count) }
    s = s.replacingOccurrences(of: ".local", with: "")
         .replacingOccurrences(of: "-", with: " ")
    return s.isEmpty ? "your Mac" : s
}

private func speedText(_ bps: Double) -> String? {
    guard bps > 1 else { return nil }
    let mb = bps / 1_000_000
    if mb >= 1 { return String(format: "%.0f MB/s", mb) }
    return String(format: "%.0f KB/s", bps / 1000)
}

@main
struct DropSwiftWidgetBundle: WidgetBundle {
    var body: some Widget {
        DropSwiftTransferLiveActivity()
    }
}

struct DropSwiftTransferLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TransferActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activitySystemActionForegroundColor(accent)
        } dynamicIsland: { context in
            let s = context.state
            let device = deviceName(context.attributes.serverName)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RingIcon(fraction: s.fraction, done: s.done, size: 42)
                        .padding(.leading, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        PercentLabel(state: s, size: 24)
                        ETALabel(state: s, alignment: .trailing)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 9) {
                        CapsuleProgress(fraction: s.fraction, done: s.done)
                        HStack(spacing: 8) {
                            Label(device, systemImage: "laptopcomputer")
                                .labelStyle(.titleAndIcon)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            if !s.done, let sp = speedText(s.speed) {
                                Text(sp).monospacedDigit()
                            }
                            Text(s.done ? "\(s.total) files" : "\(s.completed)/\(s.total)")
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)   // clear the island's rounded corners
                    }
                    .padding(.top, 3)
                }
            } compactLeading: {
                Logo(size: 19).shadow(color: accent.opacity(0.5), radius: 2)
            } compactTrailing: {
                MiniRing(fraction: s.fraction, done: s.done)
            } minimal: {
                MiniRing(fraction: s.fraction, done: s.done)
            }
            .keylineTint(accent)
        }
        // Show this Live Activity on the Apple Watch Smart Stack with a
        // watch-tailored (.small) layout.
        .supplementalActivityFamilies([.small])
    }
}

// MARK: - Lock Screen / Watch

struct LockScreenView: View {
    @Environment(\.activityFamily) private var activityFamily
    let context: ActivityViewContext<TransferActivityAttributes>

    var body: some View {
        switch activityFamily {
        case .small:
            WatchTransferView(context: context)
        default:
            phoneBody
        }
    }

    private var phoneBody: some View {
        let s = context.state
        let device = deviceName(context.attributes.serverName)
        return HStack(alignment: .center, spacing: 14) {
            RingIcon(fraction: s.fraction, done: s.done, size: 50)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.incoming
                             ? (s.done ? "Saved to iPhone" : "Saving from \(device)")
                             : (s.done ? "Sent to \(device)" : "Sending to \(device)"))
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(1)
                        Label("via Wi‑Fi", systemImage: "wifi")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    PercentLabel(state: s, size: 22)
                }

                CapsuleProgress(fraction: s.fraction, done: s.done)

                HStack(spacing: 14) {
                    Stat(icon: "doc.on.doc",
                         text: s.done ? "\(s.total) files" : "\(s.completed) of \(s.total)")
                    if !s.done, let sp = speedText(s.speed) {
                        Stat(icon: "gauge.with.dots.needle.67percent", text: sp)
                    }
                    if !s.done, let eta = s.etaDate, eta > .now {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                            Text(timerInterval: Date.now...eta, countsDown: true)
                                .monospacedDigit()
                                .frame(maxWidth: 52, alignment: .leading)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
    }
}

/// Apple Watch (Smart Stack) presentation — compact and glanceable.
struct WatchTransferView: View {
    let context: ActivityViewContext<TransferActivityAttributes>

    var body: some View {
        let s = context.state
        let device = deviceName(context.attributes.serverName)
        HStack(spacing: 10) {
            RingIcon(fraction: s.fraction, done: s.done, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(s.incoming ? (s.done ? "Saved" : "Saving") : (s.done ? "Sent" : "Sending"))
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    PercentLabel(state: s, size: 15)
                }
                CapsuleProgress(fraction: s.fraction, done: s.done)
                HStack(spacing: 6) {
                    Text(device).lineLimit(1)
                    Spacer(minLength: 4)
                    if !s.done, let eta = s.etaDate, eta > .now {
                        Text(timerInterval: Date.now...eta, countsDown: true)
                            .monospacedDigit()
                            .frame(maxWidth: 46, alignment: .trailing)
                    } else {
                        Text("\(s.completed)/\(s.total)").monospacedDigit()
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Shared pieces

/// App logo (or a green checkmark when done) inside a circular progress ring.
struct RingIcon: View {
    let fraction: Double
    var done: Bool
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: done ? 1 : max(0.02, clamp(fraction)))
                .stroke(done ? AnyShapeStyle(Color.green) : AnyShapeStyle(accentGradient),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: (done ? Color.green : accent).opacity(0.5), radius: 3)
                .animation(.spring(response: 0.5, dampingFraction: 0.9), value: fraction)
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: done)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Logo(size: size * 0.6)
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: done)
    }
}

/// Slim gradient capsule progress with a soft leading glow.
struct CapsuleProgress: View {
    let fraction: Double
    var done: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(done ? AnyShapeStyle(Color.green) : AnyShapeStyle(accentGradient))
                    .frame(width: max(7, geo.size.width * (done ? 1 : clamp(fraction))))
                    .shadow(color: (done ? Color.green : accent).opacity(0.55), radius: 3, x: 1)
                    .animation(.spring(response: 0.55, dampingFraction: 0.9), value: fraction)
                    .animation(.spring(response: 0.5, dampingFraction: 0.85), value: done)
            }
        }
        .frame(height: 6)
    }
}

/// Tiny ring for the compact / minimal Dynamic Island; morphs to a check.
struct MiniRing: View {
    let fraction: Double
    var done: Bool
    var size: CGFloat = 19

    var body: some View {
        ZStack {
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .resizable().scaledToFit()
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: done)
            } else {
                Circle().stroke(.quaternary, lineWidth: 2.6)
                Circle()
                    .trim(from: 0, to: max(0.04, clamp(fraction)))
                    .stroke(accent, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.5, dampingFraction: 0.9), value: fraction)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Big percentage with a counting (numericText) transition; "Done" when finished.
struct PercentLabel: View {
    let state: TransferActivityAttributes.ContentState
    var size: CGFloat = 22

    var body: some View {
        Group {
            if state.done {
                Text("Done")
                    .foregroundStyle(.green)
            } else {
                Text("\(Int(clamp(state.fraction) * 100))%")
                    .foregroundStyle(accentGradient)
                    .contentTransition(.numericText())
            }
        }
        .font(.system(size: size, weight: .bold, design: .rounded))
        .monospacedDigit()
    }
}

/// Native, ticking time-remaining label.
struct ETALabel: View {
    let state: TransferActivityAttributes.ContentState
    var alignment: Alignment = .leading

    var body: some View {
        if !state.done, let eta = state.etaDate, eta > .now {
            Text(timerInterval: Date.now...eta, countsDown: true)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: alignment)
        }
    }
}

struct Stat: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text).monospacedDigit().contentTransition(.numericText())
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

/// The DropSwift app logo (rounded).
struct Logo: View {
    var size: CGFloat
    var body: some View {
        Image("AppLogo")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}
