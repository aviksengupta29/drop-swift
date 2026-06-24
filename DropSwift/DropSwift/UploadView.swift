//
//  UploadView.swift
//  DropSwift
//
//  Material 3 styled Send screen with a live transfer progress card.
//

import SwiftUI
import PhotosUI

struct UploadView: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject var server: ServerConnection
    @State private var selection: [PhotosPickerItem] = []
    @State private var sendTask: Task<Void, Never>?

    var body: some View {
        M3Scaffold(title: "Send", showLogo: true) {
            let m3 = M3(scheme)
            if server.isConnected {
                content(m3)
            } else {
                notConnected(m3)
            }
        }
    }

    private func content(_ m3: M3) -> some View {
        VStack(spacing: 18) {
            // Hero
            M3Card {
                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.up.on.square.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(m3.primary)
                    Text("Send to \(server.serverName)")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(m3.onSurface)
                    Text("Photos & videos keep their original quality and metadata.")
                        .font(.system(size: 13))
                        .foregroundStyle(m3.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }

            PhotosPicker(
                selection: $selection,
                maxSelectionCount: ServerConnection.maxBatch,
                matching: .any(of: [.images, .videos]),
                photoLibrary: .shared()
            ) {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                    Text("Choose photos / videos").font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .foregroundStyle(m3.onSecondaryContainer)
                .background(m3.secondaryContainer, in: Capsule())
            }
            .disabled(server.isTransferring)

            Text("Up to \(ServerConnection.maxBatch) items per transfer.")
                .font(.system(size: 12))
                .foregroundStyle(m3.onSurfaceVariant)

            if server.isTransferring {
                transferCard(m3)
            } else if !selection.isEmpty {
                M3FilledButton(title: "Send \(selection.count) item(s)", icon: "paperplane.fill") {
                    sendTask = Task {
                        await server.sendPhotos(selection)
                        selection = []
                    }
                }
            }

            if let result = server.transferResult, !server.isTransferring {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text(result).font(.system(size: 13)).foregroundStyle(m3.onSurfaceVariant)
                }
                .multilineTextAlignment(.center)
            }
        }
    }

    private func transferCard(_ m3: M3) -> some View {
        M3Card {
            VStack(spacing: 14) {
                HStack {
                    Text("Sending \(min(server.transferCompleted + 1, server.transferTotal)) of \(server.transferTotal)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(m3.onSurface)
                    Spacer()
                    Text("\(Int(server.transferOverall * 100))%")
                        .font(.system(size: 15, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(m3.onSurfaceVariant)
                }
                M3LinearProgress(value: server.transferOverall)
                Text(server.transferCurrentName)
                    .font(.system(size: 12))
                    .foregroundStyle(m3.onSurfaceVariant)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                M3OutlinedButton(title: "Cancel", icon: "xmark", role: .destructive) {
                    sendTask?.cancel()
                }
            }
        }
    }

    private func notConnected(_ m3: M3) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 60)
            Image(systemName: "wifi.slash").font(.system(size: 48)).foregroundStyle(m3.onSurfaceVariant)
            Text("Not connected").font(.system(size: 18, weight: .semibold)).foregroundStyle(m3.onSurface)
            Text("Connect to your computer on the Connect tab first.")
                .font(.system(size: 14)).foregroundStyle(m3.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
    }
}
