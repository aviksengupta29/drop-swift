//
//  BrowseView.swift
//  DropSwift
//
//  Browse folders on the laptop and download files to the phone.
//

import SwiftUI

struct BrowseView: View {
    @EnvironmentObject var server: ServerConnection

    var body: some View {
        NavigationStack {
            Group {
                if server.isConnected {
                    FolderListView(path: "", title: "Laptop")
                } else {
                    ContentUnavailableView(
                        "Not connected",
                        systemImage: "wifi.slash",
                        description: Text("Connect to your computer on the Connect tab first.")
                    )
                }
            }
            .navigationTitle("Browse")
        }
    }
}

/// Lists a single folder; folders push a new FolderListView, files download.
struct FolderListView: View {
    @EnvironmentObject var server: ServerConnection
    let path: String
    let title: String

    @State private var items: [RemoteFile] = []
    @State private var loading = false
    @State private var error: String?

    // Download state
    @State private var downloadedURL: URL?
    @State private var showShare = false
    @State private var downloadingName: String?

    var body: some View {
        List {
            if let error {
                Text(error).foregroundStyle(.orange)
            }
            ForEach(items) { item in
                if item.isDir {
                    NavigationLink {
                        FolderListView(path: childPath(item.name), title: item.name)
                    } label: {
                        Label(item.name, systemImage: "folder.fill")
                    }
                } else {
                    Button {
                        Task { await download(item) }
                    } label: {
                        HStack {
                            Label(item.name, systemImage: "doc")
                                .foregroundStyle(.primary)
                            Spacer()
                            if downloadingName == item.name {
                                ProgressView()
                            } else {
                                Text(item.displaySize)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .overlay { if loading && items.isEmpty { ProgressView() } }
        .navigationTitle(title)
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $showShare) {
            if let downloadedURL { ShareSheet(items: [downloadedURL]) }
        }
    }

    private func childPath(_ name: String) -> String {
        path.isEmpty ? name : "\(path)/\(name)"
    }

    private func load() async {
        loading = true; error = nil
        do {
            items = try await server.list(path: path).items
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }

    private func download(_ item: RemoteFile) async {
        downloadingName = item.name
        defer { downloadingName = nil }
        do {
            let url = try await server.download(path: childPath(item.name), name: item.name)
            downloadedURL = url
            showShare = true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
