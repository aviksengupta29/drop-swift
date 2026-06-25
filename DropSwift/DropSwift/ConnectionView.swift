//
//  ConnectionView.swift
//  DropSwift
//
//  Native iOS Connect screen (List / sections) — auto-discovery + manual entry.
//

import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject var server: ServerConnection
    @StateObject private var discovery = Discovery()
    @State private var showManual = false

    var body: some View {
        List {
            // Hero
            Section {
                VStack(spacing: 10) {
                    Image("AppLogo")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                        .shadow(color: Theme.accent.opacity(0.3), radius: 12, y: 6)
                    Text("DropSwift").font(.largeTitle.weight(.bold))
                    Text("Send files between your phone and computer")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            // Discovered computers
            Section {
                if discovery.servers.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching for your computer…").foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(discovery.servers) { found in
                        Button { Task { await server.connect(to: found) } } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "laptopcomputer")
                                    .font(.title3)
                                    .foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(found.name)
                                    Text(verbatim: "\(found.host):\(found.port)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if server.isConnected && server.host == found.host {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }
            } header: {
                HStack {
                    Text("Computers on this Wi‑Fi")
                    if discovery.isSearching {
                        ProgressView().controlSize(.mini).padding(.leading, 4)
                    }
                    Spacer()
                    Button { discovery.refresh() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .textCase(nil)
                }
            }

            // Status + disconnect
            Section {
                HStack(spacing: 10) {
                    Circle().fill(statusColor).frame(width: 9, height: 9)
                    Text(statusText)
                    Spacer()
                    if server.isConnecting { ProgressView() }
                }
                if server.isConnected {
                    Button(role: .destructive) {
                        withAnimation { server.disconnect() }
                    } label: {
                        Label("Disconnect", systemImage: "wifi.slash")
                    }
                }
            }

            // Manual entry
            Section {
                Button { withAnimation { showManual.toggle() } } label: {
                    Label("Enter address manually", systemImage: "keyboard")
                }
                if showManual {
                    TextField("Host (e.g. 192.168.1.5)", text: $server.host)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port (e.g. 8080)", text: $server.port)
                        .keyboardType(.numberPad)
                    Button("Connect") {
                        Task { await server.connectManually() }
                    }
                    .disabled(server.isConnecting)
                }
            } footer: {
                Text("Make sure the DropSwift server is running and both devices are on the same Wi‑Fi.")
            }
        }
        .listStyle(.insetGrouped)
        .tint(Theme.accent)
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        .onChange(of: discovery.servers) { _, servers in
            Task { await server.autoConnectIfKnown(servers) }
        }
    }

    private var statusText: String {
        if server.isConnected { return "Connected to \(server.serverName)" }
        if server.isConnecting { return "Connecting…" }
        if let err = server.lastError { return err }
        return "Not connected"
    }

    private var statusColor: Color {
        if server.isConnected { return .green }
        if server.lastError != nil { return .red }
        return .secondary
    }
}

/// Sheet that asks for the server's 6-digit access code.
struct CodeEntryView: View {
    @EnvironmentObject var server: ServerConnection
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var submitting = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 24)
                Text("Enter access code").font(.title2.weight(.bold))
                Text("Type the 6-digit code shown in the DropSwift app on \(server.serverName.isEmpty ? "your computer" : server.serverName).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                TextField("000000", text: $code)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .tracking(8)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 40)
                    .onChange(of: code) { _, v in code = String(v.filter(\.isNumber).prefix(6)) }

                if let err = server.lastError {
                    Text(err).font(.footnote).foregroundStyle(.red)
                }

                Button {
                    Task {
                        submitting = true
                        await server.submitCode(code)
                        submitting = false
                        if server.isConnected { dismiss() }
                    }
                } label: {
                    Text(submitting ? "Checking…" : "Connect").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(code.count != 6 || submitting)
                .padding(.horizontal)

                Spacer()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .tint(Theme.accent)
        }
        .presentationDetents([.medium])
    }
}
