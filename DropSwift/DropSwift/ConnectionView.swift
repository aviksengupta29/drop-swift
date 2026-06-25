//
//  ConnectionView.swift
//  DropSwift
//
//  Liquid Glass Connect screen: auto-discovery + manual entry.
//

import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject var server: ServerConnection
    @StateObject private var discovery = Discovery()
    @State private var connecting = false
    @State private var showManual = false

    var body: some View {
        GlassScreen {
            VStack(spacing: 18) {
                hero
                discovered
                statusPill
                if server.isConnected { disconnectButton }
                manual
                Text("Make sure the DropSwift server is running and both devices are on the same Wi‑Fi.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
            }
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 12) {
            Image("AppLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: Theme.accent.opacity(0.35), radius: 16, y: 8)
            Text("DropSwift")
                .font(.system(size: 32, weight: .bold, design: .rounded))
            Text("Send files between your phone and computer")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 4)
    }

    // MARK: Discovered computers

    private var discovered: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("COMPUTERS ON THIS WI‑FI")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if discovery.isSearching { ProgressView().controlSize(.mini) }
                Spacer()
                Button { discovery.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .tint(Theme.accent)
            }
            .padding(.horizontal, 6)

            VStack(spacing: 0) {
                if discovery.servers.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Searching for your computer…").foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(16)
                } else {
                    ForEach(Array(discovery.servers.enumerated()), id: \.element.id) { idx, found in
                        Button { Task { await connect(to: found) } } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "laptopcomputer")
                                    .font(.title3).foregroundStyle(Theme.accent).frame(width: 38)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(found.name).foregroundStyle(.primary)
                                    Text("\(found.host):\(found.port)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if server.isConnected && server.host == found.host {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if idx < discovery.servers.count - 1 { Divider().padding(.leading, 16) }
                    }
                }
            }
            .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    // MARK: Status + disconnect

    private var statusPill: some View {
        HStack(spacing: 8) {
            if connecting {
                ProgressView().controlSize(.small)
            } else {
                Circle().fill(statusColor).frame(width: 8, height: 8)
            }
            Text(statusText).font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glass(Capsule())
        .overlay(Capsule().strokeBorder(server.isConnected ? Theme.green.opacity(0.55) : .clear, lineWidth: 1))
        .shadow(color: server.isConnected ? Theme.green.opacity(0.4) : .clear, radius: server.isConnected ? 9 : 0)
    }

    private var disconnectButton: some View {
        Button(role: .destructive) { withAnimation { server.disconnect() } } label: {
            Label("Disconnect", systemImage: "wifi.slash")
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .tint(Theme.red)
    }

    // MARK: Manual entry

    private var manual: some View {
        VStack(spacing: 12) {
            Button { withAnimation { showManual.toggle() } } label: {
                Label(showManual ? "Hide manual entry" : "Enter address manually", systemImage: "keyboard")
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .tint(Theme.accent)

            if showManual {
                VStack(spacing: 12) {
                    field("Host (e.g. 192.168.1.5)", text: $server.host, keyboard: .numbersAndPunctuation)
                    field("Port (e.g. 8080)", text: $server.port, keyboard: .numberPad)
                    Button {
                        Task { connecting = true; await server.connect(); connecting = false }
                    } label: {
                        Text("Connect")
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .tint(Theme.accent)
                    .disabled(connecting)
                }
                .padding(16)
                .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        TextField(label, text: text)
            .keyboardType(keyboard)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(.horizontal, 16)
            .frame(height: 50)
            .glass(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Helpers

    private var statusText: String {
        if server.isConnected { return "Connected" }
        if connecting { return "Connecting…" }
        if let err = server.lastError { return err }
        return "Not connected"
    }

    private var statusColor: Color {
        if server.isConnected { return Theme.green }
        if server.lastError != nil { return Theme.red }
        return .secondary
    }

    private func connect(to found: DiscoveredServer) async {
        connecting = true
        server.host = found.host
        server.port = String(found.port)
        await server.connect()
        connecting = false
    }
}

/// Sheet that asks for the server's 6-digit access code.
struct CodeEntryView: View {
    @EnvironmentObject var server: ServerConnection
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var submitting = false

    var body: some View {
        ZStack {
            GlassBackground()
            VStack(spacing: 16) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 30)
                Text("Enter access code")
                    .font(.system(size: 20, weight: .bold))
                Text("Type the 6-digit code shown in the DropSwift app on \(server.serverName.isEmpty ? "your computer" : server.serverName).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                TextField("000000", text: $code)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .tracking(8)
                    .frame(height: 64)
                    .frame(maxWidth: .infinity)
                    .glass(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 40)
                    .onChange(of: code) { _, v in code = String(v.filter(\.isNumber).prefix(6)) }

                if let err = server.lastError {
                    Text(err).font(.footnote).foregroundStyle(Theme.red)
                }

                Button {
                    Task {
                        submitting = true
                        await server.submitCode(code)
                        submitting = false
                        if server.isConnected { dismiss() }
                    }
                } label: {
                    Text(submitting ? "Checking…" : "Connect")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(Theme.accent)
                .disabled(code.count != 6 || submitting)

                Button("Cancel") { dismiss() }
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)

                Spacer(minLength: 0)
            }
        }
        .presentationDetents([.medium])
    }
}
