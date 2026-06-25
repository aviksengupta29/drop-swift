//
//  BrowseView.swift
//  DropSwift
//
//  Liquid Glass gallery: square thumbnails under a native glass nav bar,
//  tap to open a swipeable viewer, folders to navigate.
//

import SwiftUI

struct BrowseView: View {
    @EnvironmentObject var server: ServerConnection

    var body: some View {
        NavigationStack {
            if server.isConnected {
                GalleryView(path: "",
                            title: server.serverName.isEmpty ? "Browse" : server.serverName)
            } else {
                ZStack {
                    GlassBackground()
                    VStack(spacing: 14) {
                        Image(systemName: "wifi.slash").font(.system(size: 48)).foregroundStyle(.secondary)
                        Text("Not connected").font(.system(size: 18, weight: .semibold))
                        Text("Connect to your computer on the Connect tab first.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal, 30)
                    }
                }
                .navigationTitle("Browse")
            }
        }
    }
}

/// Identifies a full-screen pager presentation (the media list + start index).
struct PagerData: Identifiable {
    let id = UUID()
    let items: [SelectedMedia]
    let start: Int
}

/// One folder shown as a gallery grid.
struct GalleryView: View {
    @EnvironmentObject var server: ServerConnection
    let path: String
    let title: String

    @State private var items: [RemoteFile] = []
    @State private var loading = false
    @State private var error: String?
    @State private var pager: PagerData?
    @State private var shareURL: URL?
    @State private var showShare = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    private var folders: [RemoteFile] { items.filter { $0.isDir } }
    private var files: [RemoteFile] { items.filter { !$0.isDir } }
    private var mediaItems: [SelectedMedia] {
        files.filter { MediaKind.of($0.name) != .other }
            .map { SelectedMedia(path: childPath($0.name), name: $0.name) }
    }

    var body: some View {
        ScrollView {
            if let error {
                Text(error).foregroundStyle(Theme.red).padding()
            }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(folders) { folder in
                    NavigationLink {
                        GalleryView(path: childPath(folder.name), title: folder.name)
                    } label: {
                        FolderCell(name: folder.name)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(files) { file in
                    Button { tap(file) } label: {
                        MediaCell(file: file, path: childPath(file.name))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 130)

            if items.isEmpty && !loading {
                ContentUnavailableView("Empty folder", systemImage: "tray").padding(.top, 60)
            }
        }
        .background(GlassBackground())
        .overlay { if loading && items.isEmpty { ProgressView() } }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .fullScreenCover(item: $pager) { data in
            MediaPager(items: data.items, startIndex: data.start)
        }
        .sheet(isPresented: $showShare) {
            if let shareURL { ShareSheet(items: [shareURL]) }
        }
    }

    private func childPath(_ name: String) -> String {
        path.isEmpty ? name : "\(path)/\(name)"
    }

    private func tap(_ file: RemoteFile) {
        let p = childPath(file.name)
        if MediaKind.of(file.name) == .other {
            Task {
                if let url = try? await server.download(path: p, name: file.name) {
                    shareURL = url
                    showShare = true
                }
            }
        } else if let start = mediaItems.firstIndex(where: { $0.path == p }) {
            pager = PagerData(items: mediaItems, start: start)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let server = self.server
        let path = self.path
        do {
            let listing = try await Task.detached(priority: .userInitiated) {
                try await server.list(path: path)
            }.value
            items = listing.items
            error = nil
        } catch is CancellationError {
        } catch let urlError as URLError where urlError.code == .cancelled {
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
