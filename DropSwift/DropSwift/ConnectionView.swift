//
//  ConnectionView.swift
//  DropSwift
//
//  Auto-discovers the laptop via Bonjour; manual entry kept as a fallback.
//

import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject var server: ServerConnection
    @StateObject private var discovery = Discovery()
    @State private var connecting = false
    @State private var showManual = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    BrandHeader(subtitle: "Send files between your phone and computer")
                        .listRowBackground(Color.clear)
                }

                // MARK: Auto-discovered computers
                Section {
                    if discovery.servers.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Searching for your computer…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(discovery.servers) { found in
                            Button {
                                Task { await connect(to: found) }
                            } label: {
                                HStack {
                                    Image(systemName: "laptopcomputer")
                                    VStack(alignment: .leading) {
                                        Text(found.name)
                                        Text("\(found.host):\(found.port)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if server.isConnected && server.host == found.host {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Computers on this Wi‑Fi")
                } footer: {
                    Text("Make sure the DropSwift server is running on your computer and both devices are on the same Wi‑Fi.")
                }

                // MARK: Status
                Section("Status") {
                    if server.isConnected {
                        Label("Connected to \(server.serverName)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if connecting {
                        HStack { ProgressView(); Text("Connecting…") }
                    } else if let err = server.lastError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Not connected").foregroundStyle(.secondary)
                    }
                }

                // MARK: Manual entry (fallback)
                Section {
                    DisclosureGroup("Enter address manually", isExpanded: $showManual) {
                        TextField("Host (e.g. 192.168.1.5)", text: $server.host)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Port (e.g. 8080)", text: $server.port)
                            .keyboardType(.numberPad)
                        Button("Connect") {
                            Task {
                                connecting = true
                                await server.connect()
                                connecting = false
                            }
                        }
                        .disabled(connecting)
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { discovery.start() }
            .onDisappear { discovery.stop() }
        }
    }

    private func connect(to found: DiscoveredServer) async {
        connecting = true
        server.host = found.host
        server.port = String(found.port)
        await server.connect()
        connecting = false
    }
}
