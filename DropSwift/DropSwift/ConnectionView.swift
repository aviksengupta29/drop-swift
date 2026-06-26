//
//  ConnectionView.swift
//  DropSwift
//
//  Premium Connect screen: animated hero, live searching, connection cards,
//  and a delightful connected state.
//

import SwiftUI
import Combine

struct ConnectionView: View {
    @EnvironmentObject var server: ServerConnection
    @State private var showManual = false

    var body: some View {
        ScrollView {
            VStack(spacing: Space.l) {
                HeroHeader(title: "Connect to your\nComputer",
                           subtitle: "Transfer files instantly over your local network.")
                    .padding(.top, Space.xl)

                if server.isConnected {
                    connectedCard
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                } else {
                    searching
                }

                manual
            }
            .padding(.horizontal, Space.l)
            .padding(.bottom, 130)
            .animation(.spring(response: 0.5, dampingFraction: 0.82), value: server.isConnected)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Connected

    private var connectedCard: some View {
        VStack(spacing: Space.l) {
            ZStack {
                Circle().fill(Theme.success.opacity(0.16)).frame(width: 104, height: 104)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 68))
                    .foregroundStyle(Theme.success)
                    .symbolEffect(.bounce, value: server.isConnected)
            }
            VStack(spacing: 4) {
                Text(server.serverName.isEmpty ? "Connected" : server.serverName)
                    .font(.title2.weight(.bold))
                Text("Connected · Local Network")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                infoRow("desktopcomputer", "Computer", server.serverName)
                divider
                infoRow("network", "Address", "\(server.host):\(server.port)")
                divider
                infoRow("lock.fill", "Secure", "Access code verified")
            }
            SecondaryButton(title: "Disconnect", icon: "wifi.slash", tint: Theme.error) {
                Haptics.warning()
                withAnimation { server.disconnect() }
            }
        }
        .appCard()
    }

    private var divider: some View {
        Divider().background(Color.primary.opacity(0.04))
    }

    private func infoRow(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: icon).font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent).frame(width: 22)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .trailing)
        }
        .font(.system(size: 15))
        .padding(.vertical, 13)
    }

    // MARK: Searching

    @ViewBuilder private var searching: some View {
        if server.discoveredServers.isEmpty {
            VStack(spacing: Space.l) {
                WifiPulse()
                VStack(spacing: Space.s) {
                    HStack(spacing: Space.s) {
                        Text(server.isConnecting ? "Connecting" : "Searching for your computer")
                            .font(.headline)
                        SearchingDots()
                    }
                    Text(server.lastError ?? "Make sure the DropSwift server is running on the same Wi‑Fi.")
                        .font(.subheadline)
                        .foregroundStyle(server.lastError == nil ? .secondary : Color(Theme.error))
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .appCard(padding: Space.xl)
        } else {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader("Computers nearby") {
                    Button {
                        Haptics.light()
                        server.refreshDiscovery()
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                }
                ForEach(server.discoveredServers) { found in
                    ComputerCard(found: found,
                                 connecting: server.isConnecting && server.host == found.host) {
                        Task { await server.connect(to: found) }
                    }
                }
            }
        }
    }

    // MARK: Manual entry

    private var manual: some View {
        VStack(spacing: Space.m) {
            Button {
                Haptics.light()
                withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { showManual.toggle() }
            } label: {
                HStack {
                    Image(systemName: "keyboard")
                    Text("Enter address manually")
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(showManual ? 180 : 0))
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Space.m)
                .frame(height: 54)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            }
            .buttonStyle(PressableStyle(scale: 0.98))

            if showManual {
                VStack(spacing: Space.m) {
                    field("Host", "192.168.1.5", text: $server.host, keyboard: .numbersAndPunctuation)
                    field("Port", "8080", text: $server.port, keyboard: .numberPad)
                    PrimaryButton(title: "Connect", icon: "link") {
                        Task { await server.connectManually() }
                    }
                }
                .appCard()
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func field(_ label: String, _ placeholder: String,
                       text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(size: 16))
                .padding(.horizontal, Space.m)
                .frame(height: 50)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

// MARK: - Pieces

/// Glowing concentric Wi‑Fi pulse.
struct WifiPulse: View {
    @State private var animate = false
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Theme.accent.opacity(0.5), lineWidth: 2)
                    .frame(width: 80, height: 80)
                    .scaleEffect(animate ? 1.8 : 0.7)
                    .opacity(animate ? 0 : 0.6)
                    .animation(.easeOut(duration: 2.2).repeatForever(autoreverses: false)
                        .delay(Double(i) * 0.55), value: animate)
            }
            Circle().fill(Theme.accentGradient).frame(width: 72, height: 72)
                .shadow(color: Theme.accent.opacity(0.55), radius: 18)
            Image(systemName: "wifi").font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: 160, height: 160)
        .onAppear { animate = true }
    }
}

/// Animated "…" used in the searching state.
struct SearchingDots: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Theme.accent)
                    .frame(width: 6, height: 6)
                    .opacity(phase == i ? 1 : 0.3)
                    .scaleEffect(phase == i ? 1.25 : 1)
            }
        }
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 0.3)) { phase = (phase + 1) % 3 }
        }
    }
}

/// A discovered computer, presented as a floating card that springs in.
struct ComputerCard: View {
    let found: DiscoveredServer
    let connecting: Bool
    let action: () -> Void
    @State private var appear = false

    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            HStack(spacing: Space.m) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.accent.opacity(0.12)).frame(width: 52, height: 52)
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 24)).foregroundStyle(Theme.accentGradient)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(found.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text(verbatim: "\(found.host) · Local Network")
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: Space.s)
                if connecting {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
            .appCard(padding: Space.m, radius: 22)
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 18)
        .onAppear { withAnimation(.spring(response: 0.55, dampingFraction: 0.74)) { appear = true } }
    }
}

// MARK: - Access code sheet

struct CodeEntryView: View {
    @EnvironmentObject var server: ServerConnection
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var submitting = false

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: Space.l) {
                ZStack {
                    Circle().fill(Theme.accent.opacity(0.14)).frame(width: 96, height: 96)
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 46)).foregroundStyle(Theme.accentGradient)
                }
                .padding(.top, Space.xl)

                VStack(spacing: Space.xs) {
                    Text("Enter access code").font(.title2.weight(.bold))
                    Text("Type the 6-digit code shown in the DropSwift app on \(server.serverName.isEmpty ? "your computer" : server.serverName).")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, Space.l)
                }

                TextField("000000", text: $code)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .tracking(10)
                    .frame(height: 70)
                    .frame(maxWidth: .infinity)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                    .padding(.horizontal, Space.xl)
                    .onChange(of: code) { _, v in code = String(v.filter(\.isNumber).prefix(6)) }

                if let err = server.lastError {
                    Text(err).font(.footnote).foregroundStyle(Color(Theme.error))
                }

                PrimaryButton(title: submitting ? "Checking…" : "Connect",
                              icon: "checkmark.circle", enabled: code.count == 6 && !submitting) {
                    Task {
                        submitting = true
                        await server.submitCode(code)
                        submitting = false
                        if server.isConnected { Haptics.success(); dismiss() } else { Haptics.warning() }
                    }
                }
                .padding(.horizontal, Space.xl)

                Button("Cancel") { dismiss() }.foregroundStyle(.secondary)
                Spacer()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
