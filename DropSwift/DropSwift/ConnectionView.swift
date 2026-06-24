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

    var body: some View {
        M3Scaffold(title: "DropSwift", showLogo: true) {
            let m3 = M3(scheme)
            VStack(alignment: .leading, spacing: 16) {

                // Discovered computers
                M3SectionHeader(title: "Computers on this Wi-Fi")
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

                // Status
                M3SectionHeader(title: "Status")
                M3Card {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(statusColor(m3))
                            .frame(width: 10, height: 10)
                        Text(statusText)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(m3.onSurface)
                        Spacer()
                        if connecting { ProgressView().tint(m3.primary) }
                    }
                }

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

    private func statusColor(_ m3: M3) -> Color {
        if server.isConnected { return .green }
        if server.lastError != nil { return m3.error }
        return m3.outline
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
