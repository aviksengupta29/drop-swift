//
//  UploadView.swift
//  DropSwift
//
//  Pick photos/videos and send them to the laptop, with a live progress bar.
//

import SwiftUI
import PhotosUI

struct UploadView: View {
    @EnvironmentObject var server: ServerConnection
    @State private var selection: [PhotosPickerItem] = []

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
        ScrollView {
            VStack(spacing: 22) {
                BrandHeader(subtitle: "Send photos & videos to \(server.serverName)")

                PhotosPicker(
                    selection: $selection,
                    matching: .any(of: [.images, .videos])
                ) {
                    Label("Choose photos / videos", systemImage: "photo.on.rectangle.angled")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.violet)
                .disabled(server.isTransferring)

                if server.isTransferring {
                    transferCard
                } else if !selection.isEmpty {
                    Button {
                        Task {
                            await server.sendPhotos(selection)
                            selection = []
                        }
                    } label: {
                        Label("Send \(selection.count) item(s)", systemImage: "paperplane.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.indigo)
                }

                if let result = server.transferResult, !server.isTransferring {
                    Label(result, systemImage: "checkmark.seal.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                        .multilineTextAlignment(.center)
                }

                Spacer(minLength: 0)
            }
            .padding()
        }
    }

    /// The live transfer card with the progress bar.
    private var transferCard: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Sending \(min(server.transferCompleted + 1, server.transferTotal)) of \(server.transferTotal)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(server.transferOverall * 100))%")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: server.transferOverall)
                .tint(Brand.violet)
                .scaleEffect(x: 1, y: 1.4, anchor: .center)

            Text(server.transferCurrentName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Brand.gradient.opacity(0.25), lineWidth: 1)
        )
    }
}
