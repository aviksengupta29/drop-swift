//
//  ConnectionView.swift
//  DropSwift
//
//  Material 3 styled Connect screen: auto-discovery + manual entry.
//

import SwiftUI

struct ConnectionView: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject var server: ServerConnection
    @StateObject private var discovery = Discovery()
    @State private var connecting = false
    @State private var showManual = false
    @State private var glow = false

    var body: some View {
        M3Scaffold(topBar: false) {
            let m3 = M3(scheme)
            VStack(alignment: .leading, spacing: 16) {

                // Centered hero: logo + big title
                VStack(spacing: 12) {
                    Image("AppLogo")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 88, height: 88)
                        .shadow(color: m3.primary.opacity(0.35), radius: 14, y: 6)
                    Text("DropSwift")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(m3.onSurface)
                    Text("Send files between your phone and computer")
                        .font(.system(size: 14))
                        .foregroundStyle(m3.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 28)
                .padding(.bottom, 12)

                // Discovered computers (with a refresh button)
                HStack(spacing: 4) {
                    Text("COMPUTERS ON THIS WI-FI")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(m3.onSurfaceVariant)
                    if discovery.isSearching {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer()
                    Button { discovery.refresh() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(m3.primary)
                            .frame(width: 32, height: 32)
                            .background(m3.primaryContainer.opacity(0.5), in: Circle())
                    }
                }
                .padding(.leading, 8)
                .padding(.top, 6)

                M3Card(padding: 8) {
                    VStack(spacing: 0) {
                        if discovery.servers.isEmpty {
                            HStack(spacing: 12) {
                                ProgressView().tint(m3.primary)
                                Text("Searching for your computer…")
                                    .font(.system(size: 15))
                                    .foregroundStyle(m3.onSurfaceVariant)
                                Spacer()
                            }
                            .padding(8)
                        } else {
                            ForEach(Array(discovery.servers.enumerated()), id: \.element.id) { idx, found in
                                Button { Task { await connect(to: found) } } label: {
                                    M3ListItem(
                                        icon: "laptopcomputer",
                                        headline: found.name,
                                        supporting: "\(found.host):\(found.port)",
                                        trailingSelected: server.isConnected && server.host == found.host
                                    )
                                    .padding(8)
                                }
                                .buttonStyle(.plain)
                                if idx < discovery.servers.count - 1 {
                                    Divider().overlay(m3.outlineVariant)
                                }
                            }
                        }
                    }
                }

                // Status pill — glows green when connected
                statusPill(m3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)

                // Manual entry
                M3OutlinedButton(title: showManual ? "Hide manual entry" : "Enter address manually",
                                 icon: "keyboard") {
                    withAnimation { showManual.toggle() }
                }

                if showManual {
                    M3Card {
                        VStack(spacing: 12) {
                            M3TextField(label: "Host (e.g. 192.168.1.5)", text: $server.host,
                                        keyboard: .numbersAndPunctuation)
                            M3TextField(label: "Port (e.g. 8080)", text: $server.port,
                                        keyboard: .numberPad)
                            M3FilledButton(title: "Connect", icon: "link",
                                           enabled: !connecting) {
                                Task {
                                    connecting = true
                                    await server.connect()
                                    connecting = false
                                }
                            }
                        }
                    }
                }

                Text("Make sure the DropSwift server is running on your computer and both devices are on the same Wi-Fi.")
                    .font(.system(size: 13))
                    .foregroundStyle(m3.onSurfaceVariant)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
            }
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    private var statusText: String {
        if server.isConnected { return "Connected to \(server.serverName)" }
        if connecting { return "Connecting…" }
        if let err = server.lastError { return err }
        return "Not connected"
    }

    /// Pill showing connection status; when connected its border glows green
    /// with a soft pulse.
    private func statusPill(_ m3: M3) -> some View {
        let connected = server.isConnected
        let green = Color(red: 0.18, green: 0.80, blue: 0.42)
        return HStack(spacing: 9) {
            if connecting {
                ProgressView().controlSize(.small)
            } else {
                Circle()
                    .fill(connected ? green : (server.lastError != nil ? m3.error : m3.outline))
                    .frame(width: 9, height: 9)
                    .shadow(color: connected ? green : .clear, radius: connected ? 4 : 0)
            }
            Text(statusText)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(m3.onSurface)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Capsule().fill(m3.surfaceContainerHigh))
        .overlay(
            Capsule().strokeBorder(
                connected ? green : m3.outlineVariant,
                lineWidth: connected ? 1.8 : 1)
        )
        .shadow(color: connected ? green.opacity(glow ? 0.8 : 0.25) : .clear,
                radius: connected ? (glow ? 16 : 5) : 0)
        .animation(connected ? .easeInOut(duration: 1.3).repeatForever(autoreverses: true) : .default,
                   value: glow)
        .onAppear { glow = true }
        .onChange(of: connected) { _, now in if now { glow = true } }
    }

    private func connect(to found: DiscoveredServer) async {
        connecting = true
        server.host = found.host
        server.port = String(found.port)
        await server.connect()
        connecting = false
    }
}

/// Material 3 outlined text field.
struct M3TextField: View {
    @Environment(\.colorScheme) private var scheme
    let label: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        let m3 = M3(scheme)
        TextField(label, text: $text)
            .keyboardType(keyboard)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .foregroundStyle(m3.onSurface)
            .padding(.horizontal, 16)
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(m3.outline, lineWidth: 1))
    }
}
