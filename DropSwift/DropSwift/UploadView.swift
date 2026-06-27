//
//  UploadView.swift
//  DropSwift
//
//  Premium Send screen: a drag-and-drop inspired upload area, a delightful
//  circular transfer indicator, and a satisfying completion state.
//

import SwiftUI
import PhotosUI

struct UploadView: View {
    @EnvironmentObject var server: ServerConnection
    var goToConnect: () -> Void = {}

    @State private var selection: [PhotosPickerItem] = []
    @State private var sendTask: Task<Void, Never>?

    var body: some View {
        Group {
            if server.isConnected {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.l) {
                        header
                        if server.isTransferring {
                            transferCard
                        } else {
                            uploadArea
                            if !selection.isEmpty { readyCard }
                            if let result = server.transferResult { resultCard(result) }
                            if !server.failedItems.isEmpty { retryCard }
                        }
                    }
                    .padding(.horizontal, Space.l)
                    .padding(.bottom, 130)
                    .animation(.spring(response: 0.5, dampingFraction: 0.85), value: server.isTransferring)
                    .animation(.spring(response: 0.5, dampingFraction: 0.85), value: selection.isEmpty)
                    .animation(.spring(response: 0.5, dampingFraction: 0.85), value: server.failedItems.count)
                }
                .scrollIndicators(.hidden)
            } else {
                EmptyState(
                    icon: "wifi.slash",
                    title: "Not connected",
                    message: "Connect to your computer first to send photos and videos at full quality.",
                    actionTitle: "Go to Connect",
                    action: goToConnect
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 80)
            }
        }
        .onChange(of: server.transferResult) { _, new in
            if new != nil { Haptics.success() }
        }
        .onChange(of: selection.count) { old, new in
            if new > old { Haptics.soft() }   // photos picked
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Send")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text(server.isConnected ? "To \(server.serverName) · originals preserved"
                                    : "Photos & videos at full quality")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, Space.s)
    }

    // MARK: Upload area

    private var uploadArea: some View {
        PhotosPicker(
            selection: $selection,
            matching: .any(of: [.images, .videos]),
            photoLibrary: .shared()
        ) {
            VStack(spacing: Space.m) {
                ZStack {
                    Circle().fill(Theme.accent.opacity(0.12)).frame(width: 92, height: 92)
                    Image(systemName: "arrow.up.doc.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(Theme.accentGradient)
                        .symbolEffect(.bounce, value: selection.count)
                }
                VStack(spacing: 4) {
                    Text(selection.isEmpty ? "Choose photos or videos" : "\(selection.count) selected")
                        .font(.headline)
                    Text("Tap to pick from your library")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.xl + Space.s)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Theme.accent.opacity(0.05))
            )
            .overlay(AnimatedDashBorder(radius: Radius.card))
        }
        .buttonStyle(PressableStyle(scale: 0.98))
    }

    // MARK: Ready to send

    private var readyCard: some View {
        VStack(spacing: Space.m) {
            HStack(spacing: Space.m) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.accent.opacity(0.12)).frame(width: 50, height: 50)
                    Image(systemName: "photo.stack")
                        .font(.system(size: 22)).foregroundStyle(Theme.accentGradient)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selection.count) item\(selection.count == 1 ? "" : "s") ready")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Originals & metadata kept")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Haptics.light()
                    withAnimation { selection = [] }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            PrimaryButton(title: "Send \(selection.count) item\(selection.count == 1 ? "" : "s")",
                          icon: "paperplane.fill") {
                let items = selection
                sendTask = Task {
                    await server.sendPhotos(items)
                    await MainActor.run { selection = [] }
                }
            }
        }
        .appCard()
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Live transfer

    private var transferCard: some View {
        VStack(spacing: Space.l) {
            CircularProgress(fraction: server.transferOverall)
                .padding(.top, Space.s)

            VStack(spacing: Space.xs) {
                Text("Sending \(min(server.transferCompleted + 1, server.transferTotal)) of \(server.transferTotal)")
                    .font(.headline)
                Text(server.transferCurrentName.isEmpty ? "Preparing…" : server.transferCurrentName)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            HStack(spacing: 0) {
                metric(icon: "gauge.with.dots.needle.67percent", label: "Speed") {
                    Text(speedText).contentTransition(.numericText())
                }
                metricDivider
                metric(icon: "clock", label: "Time left") { etaValue }
                metricDivider
                metric(icon: "photo.stack", label: "Files") {
                    Text("\(server.transferCompleted)/\(server.transferTotal)")
                        .contentTransition(.numericText())
                }
            }
            .animation(.snappy, value: server.transferSpeed)

            SecondaryButton(title: "Cancel", icon: "xmark", tint: Theme.error) {
                Haptics.warning()
                sendTask?.cancel()
            }
        }
        .appCard()
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    private func metric<V: View>(icon: String, label: String,
                                 @ViewBuilder value: () -> V) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
            value()
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var metricDivider: some View { Divider().frame(height: 36) }

    @ViewBuilder private var etaValue: some View {
        if let eta = server.transferETADate, eta > .now {
            Text(timerInterval: Date.now...eta, countsDown: true)
        } else {
            Text("—")
        }
    }

    private var speedText: String {
        let bps = server.transferSpeed
        guard bps > 1 else { return "—" }
        let mb = bps / 1_000_000
        if mb >= 1 { return String(format: "%.0f MB/s", mb) }
        return String(format: "%.0f KB/s", bps / 1000)
    }

    // MARK: Result

    private func resultCard(_ result: String) -> some View {
        let ok = server.failedItems.isEmpty
        return HStack(spacing: Space.m) {
            Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 30)).foregroundStyle(ok ? Theme.success : Theme.warning)
                .symbolEffect(.bounce, value: result)
            Text(result).font(.system(size: 15, weight: .medium))
            Spacer(minLength: 0)
        }
        .appCard(padding: Space.m)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Retry

    private var retryCard: some View {
        VStack(spacing: Space.m) {
            HStack(spacing: Space.m) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.warning.opacity(0.15)).frame(width: 48, height: 48)
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.warning)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(server.failedItems.count) item\(server.failedItems.count == 1 ? "" : "s") didn't send")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Resume from where it stopped")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            PrimaryButton(title: "Retry \(server.failedItems.count) item\(server.failedItems.count == 1 ? "" : "s")",
                          icon: "arrow.clockwise") {
                let items = server.failedItems
                sendTask = Task { await server.sendPhotos(items) }
            }
        }
        .appCard()
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Pieces

/// Animated dashed border that slowly marches around the upload area.
struct AnimatedDashBorder: View {
    var radius: CGFloat
    @State private var phase: CGFloat = 0
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Theme.accent.opacity(0.5),
                          style: StrokeStyle(lineWidth: 2, dash: [9, 7], dashPhase: phase))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    phase = -16
                }
            }
    }
}

/// Large circular transfer indicator with a counting percentage.
struct CircularProgress: View {
    var fraction: Double
    var body: some View {
        ZStack {
            Circle().stroke(Theme.accent.opacity(0.14), lineWidth: 13)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(Theme.accentGradient,
                        style: StrokeStyle(lineWidth: 13, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: fraction)
            VStack(spacing: 0) {
                Text("\(Int(fraction * 100))")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: fraction))
                    .animation(.snappy, value: fraction)
                Text("percent").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 168, height: 168)
    }
}
