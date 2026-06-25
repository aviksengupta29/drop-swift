//
//  UploadView.swift
//  DropSwift
//
//  Liquid Glass Send screen with a live transfer progress card.
//

import SwiftUI
import PhotosUI

struct UploadView: View {
    @EnvironmentObject var server: ServerConnection
    @State private var selection: [PhotosPickerItem] = []
    @State private var sendTask: Task<Void, Never>?

    var body: some View {
        GlassScreen(scrolls: false) {
            VStack {
                Spacer(minLength: 0)
                if server.isConnected { content } else { notConnected }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 70)
        }
    }

    private var content: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.up.on.square.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.accent)
                Text("Send to \(server.serverName)")
                    .font(.system(size: 18, weight: .semibold))
                Text("Photos & videos keep their original quality and metadata.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .glass(RoundedRectangle(cornerRadius: 26, style: .continuous))

            PhotosPicker(
                selection: $selection,
                maxSelectionCount: ServerConnection.maxBatch,
                matching: .any(of: [.images, .videos]),
                photoLibrary: .shared()
            ) {
                Label("Choose photos / videos", systemImage: "photo.on.rectangle.angled")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.glass)
            .tint(Theme.accent)
            .disabled(server.isTransferring)

            Text("Up to \(ServerConnection.maxBatch) items per transfer.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if server.isTransferring {
                transferCard
            } else if !selection.isEmpty {
                Button {
                    sendTask = Task {
                        await server.sendPhotos(selection)
                        selection = []
                    }
                } label: {
                    Label("Send \(selection.count) item(s)", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
            }

            if let result = server.transferResult, !server.isTransferring {
                Label(result, systemImage: "checkmark.seal.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.green)
                    .multilineTextAlignment(.center)
            }
        }
    }

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
            ProgressView(value: server.transferOverall).tint(Theme.accent)
            Text(server.transferCurrentName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(role: .destructive) { sendTask?.cancel() } label: {
                Label("Cancel", systemImage: "xmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
        .padding(20)
        .glass(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var notConnected: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.slash").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Not connected").font(.system(size: 18, weight: .semibold))
            Text("Connect to your computer on the Connect tab first.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
