//
//  UploadView.swift
//  DropSwift
//
//  Native iOS Send screen with a live transfer progress section.
//

import SwiftUI
import PhotosUI

struct UploadView: View {
    @EnvironmentObject var server: ServerConnection
    @State private var selection: [PhotosPickerItem] = []
    @State private var sendTask: Task<Void, Never>?

    var body: some View {
        Group {
            if server.isConnected {
                List {
                    // Hero
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "square.and.arrow.up.circle.fill")
                                .font(.system(size: 50))
                                .foregroundStyle(Theme.accent)
                            Text("Send to \(server.serverName)").font(.headline)
                            Text("Photos & videos keep their original quality and metadata.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }

                    // Pick + send
                    Section {
                        PhotosPicker(
                            selection: $selection,
                            maxSelectionCount: ServerConnection.maxBatch,
                            matching: .any(of: [.images, .videos]),
                            photoLibrary: .shared()
                        ) {
                            Label("Choose photos / videos", systemImage: "photo.on.rectangle.angled")
                        }
                        .disabled(server.isTransferring)

                        if !selection.isEmpty && !server.isTransferring {
                            Button {
                                sendTask = Task {
                                    await server.sendPhotos(selection)
                                    selection = []
                                }
                            } label: {
                                Label("Send \(selection.count) item(s)", systemImage: "paperplane.fill")
                            }
                        }
                    } footer: {
                        Text("Up to \(ServerConnection.maxBatch) items per transfer.")
                    }

                    // Live transfer
                    if server.isTransferring {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Sending \(min(server.transferCompleted + 1, server.transferTotal)) of \(server.transferTotal)")
                                    Spacer()
                                    Text("\(Int(server.transferOverall * 100))%")
                                        .monospacedDigit().foregroundStyle(.secondary)
                                }
                                ProgressView(value: server.transferOverall)
                                Text(server.transferCurrentName)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            .padding(.vertical, 4)

                            Button(role: .destructive) { sendTask?.cancel() } label: {
                                Label("Cancel", systemImage: "xmark")
                            }
                        }
                    }

                    // Result
                    if let result = server.transferResult, !server.isTransferring {
                        Section {
                            Label(result, systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .tint(Theme.accent)
            } else {
                ContentUnavailableView(
                    "Not connected",
                    systemImage: "wifi.slash",
                    description: Text("Connect to your computer on the Connect tab first.")
                )
            }
        }
    }
}
