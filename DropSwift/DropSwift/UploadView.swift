//
//  UploadView.swift
//  DropSwift
//
//  Pick photos/videos from the phone and send them to the laptop.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct UploadView: View {
    @EnvironmentObject var server: ServerConnection

    @State private var selection: [PhotosPickerItem] = []
    @State private var status: String = ""
    @State private var sending = false
    @State private var sentCount = 0
    @State private var totalCount = 0

    var body: some View {
        NavigationStack {
            Group {
                if server.isConnected {
                    content
                } else {
                    ContentUnavailableView(
                        "Not connected",
                        systemImage: "wifi.slash",
                        description: Text("Connect to your computer on the Connect tab first.")
                    )
                }
            }
            .navigationTitle("Send")
        }
    }

    private var content: some View {
        VStack(spacing: 24) {
            Image(systemName: "square.and.arrow.up.on.square")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            Text("Send photos and videos from this phone to **\(server.serverName)**.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            PhotosPicker(
                selection: $selection,
                maxSelectionCount: 0,           // 0 = unlimited
                matching: .any(of: [.images, .videos])
            ) {
                Label("Choose photos / videos", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(sending)

            if !selection.isEmpty {
                Button {
                    Task { await sendAll() }
                } label: {
                    if sending {
                        Label("Sending \(sentCount)/\(totalCount)…", systemImage: "arrow.up.circle")
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Send \(selection.count) item(s)", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(sending)
            }

            if !status.isEmpty {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding()
    }

    private func sendAll() async {
        sending = true
        totalCount = selection.count
        sentCount = 0
        status = ""
        var failures = 0

        let stamp = Int(Date().timeIntervalSince1970)
        for (index, item) in selection.enumerated() {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    failures += 1; continue
                }
                let name = filename(for: item, index: index, stamp: stamp)
                try await server.upload(data: data, filename: name)
                sentCount += 1
            } catch {
                failures += 1
            }
        }

        sending = false
        selection = []
        status = failures == 0
            ? "✅ Sent \(sentCount) item(s) to \(server.serverName)."
            : "Sent \(sentCount), failed \(failures). Check the connection and try again."
    }

    /// Builds a reasonable filename + extension for a picked item.
    private func filename(for item: PhotosPickerItem, index: Int, stamp: Int) -> String {
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "dat"
        return "DropSwift_\(stamp)_\(index).\(ext)"
    }
}
