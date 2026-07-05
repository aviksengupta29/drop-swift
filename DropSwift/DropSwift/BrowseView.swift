//
//  BrowseView.swift
//  DropSwift
//
//  Liquid Glass gallery: square thumbnails under a native glass nav bar,
//  tap to open a swipeable viewer, folders to navigate.
//

import SwiftUI

/// A subfolder to navigate into (value-based navigation so we can pop to root
/// programmatically when the server's shared folder changes).
struct FolderRoute: Hashable {
    let path: String
    let title: String
}

struct BrowseView: View {
    @EnvironmentObject var server: ServerConnection
    var goToConnect: () -> Void = {}
    @State private var navPath = NavigationPath()

    /// Root title: the shared folder's name, falling back to the computer name.
    private var rootTitle: String {
        if !server.folderName.isEmpty { return server.folderName }
        return server.serverName.isEmpty ? "Browse" : server.serverName
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            ZStack {
                AppBackground()
                if server.isConnected {
                    GalleryView(path: "", title: rootTitle)
                        .navigationDestination(for: FolderRoute.self) { route in
                            GalleryView(path: route.path, title: route.title)
                        }
                } else {
                    EmptyState(
                        icon: "wifi.slash",
                        title: "Not connected",
                        message: "Connect to your computer first to browse and open the files you've sent.",
                        actionTitle: "Go to Connect",
                        action: goToConnect
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 80)
                    .toolbar(.hidden, for: .navigationBar)
                }
            }
        }
        // The Mac switched which folder it shares — drop any drilled-in path so
        // we land on (and show) the new root.
        .onChange(of: server.browseReloadToken) { _, _ in
            navPath = NavigationPath()
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

    // Multi-select → "Save to Photos" (restore back to the iPhone timeline).
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var showSaveSheet = false
    @State private var saveTask: Task<Void, Never>?

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
            if items.isEmpty && !loading {
                EmptyState(
                    icon: "tray",
                    title: "Empty folder",
                    message: "Files you send from your phone will appear here."
                )
                .padding(.top, 80)
            }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(folders) { folder in
                    NavigationLink(value: FolderRoute(path: childPath(folder.name),
                                                      title: folder.name)) {
                        FolderCell(name: folder.name)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(files) { file in
                    let p = childPath(file.name)
                    let isMedia = MediaKind.of(file.name) != .other
                    Button {
                        if selecting {
                            if isMedia { toggle(p) }
                        } else {
                            tap(file)
                        }
                    } label: {
                        MediaCell(file: file, path: p)
                            .overlay {
                                if selecting {
                                    selectionOverlay(on: selected.contains(p), enabled: isMedia)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 130)
        }
        .scrollIndicators(.hidden)
        .overlay { if loading && items.isEmpty { ProgressView() } }
        .overlay(alignment: .bottom) { bottomOverlay }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: selected.isEmpty)
        .navigationTitle(selecting ? "\(selected.count) selected" : title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !mediaItems.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selecting ? "Cancel" : "Select") {
                        Haptics.light()
                        withAnimation(.spring(response: 0.35)) {
                            selecting.toggle()
                            if !selecting { selected = [] }
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(showSaveSheet)
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        // Server switched its shared folder — reload this listing. If we're in a
        // subfolder, BrowseView pops us to root; the root then reloads here.
        .onChange(of: server.browseReloadToken) { _, _ in
            selecting = false
            selected = []
            Task { await load() }
        }
        .fullScreenCover(item: $pager) { data in
            MediaPager(items: data.items, startIndex: data.start)
        }
        .sheet(isPresented: $showShare) {
            if let shareURL { ShareSheet(items: [shareURL]) }
        }
        // Restore progress — the same premium transfer UI as Send (+ Dynamic
        // Island Live Activity), presented while saving back to the iPhone.
        .sheet(isPresented: $showSaveSheet) {
            SaveProgressSheet { saveTask?.cancel() }
        }
    }

    // MARK: Selection UI

    private func selectionOverlay(on: Bool, enabled: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(on ? Theme.accent.opacity(0.35)
                         : Color.black.opacity(enabled ? 0.001 : 0.35))
            Image(systemName: on ? "checkmark.circle.fill" : (enabled ? "circle" : "nosign"))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(on ? AnyShapeStyle(.white)
                                    : AnyShapeStyle(.white.opacity(0.9)))
                .shadow(color: .black.opacity(0.4), radius: 2)
                .padding(6)
        }
    }

    @ViewBuilder private var bottomOverlay: some View {
        if selecting && !selected.isEmpty {
            saveActionBar
        }
    }

    private var saveActionBar: some View {
        HStack(spacing: Space.m) {
            Button {
                Haptics.selection()
                let all = Set(mediaItems.map(\.path))
                selected = selected == all ? [] : all
            } label: {
                Text(selected.count == mediaItems.count ? "None" : "All")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 54, height: 50)
                    .background(Theme.accent.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            }
            .buttonStyle(PressableStyle())

            PrimaryButton(title: "Save \(selected.count) to Photos",
                          icon: "square.and.arrow.down") {
                Task { await saveSelected() }
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.bottom, 96)   // clear the floating tab bar
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func toggle(_ path: String) {
        Haptics.selection()
        if selected.contains(path) { selected.remove(path) } else { selected.insert(path) }
    }

    private func saveSelected() async {
        let chosen = mediaItems.filter { selected.contains($0.path) }
        guard !chosen.isEmpty else { return }
        withAnimation(.spring(response: 0.35)) { selecting = false }

        // Seed a clean "preparing" state so the sheet never flashes a stale
        // result before the transfer counters are set.
        server.transferResult = nil
        server.transferDirection = .receive
        server.transferTotal = chosen.count
        server.transferCompleted = 0
        showSaveSheet = true

        saveTask = Task { await server.savePhotos(chosen) }
        await saveTask?.value
        if server.transferFailed == 0 { Haptics.success() } else { Haptics.warning() }
        selected = []
    }

    private func childPath(_ name: String) -> String {
        path.isEmpty ? name : "\(path)/\(name)"
    }

    private func tap(_ file: RemoteFile) {
        Haptics.light()
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

// MARK: - Restore progress sheet

/// Presents the same premium transfer card as Send (circular ring, speed, ETA,
/// files, Cancel) while saving back to the iPhone, then a completion state. The
/// Dynamic Island / Live Activity runs alongside — driven by `savePhotos`.
struct SaveProgressSheet: View {
    @EnvironmentObject var server: ServerConnection
    @Environment(\.dismiss) private var dismiss
    var onCancel: () -> Void

    private var finished: Bool { !server.isTransferring && server.transferResult != nil }

    var body: some View {
        ZStack {
            AppBackground()
            Group {
                if finished {
                    resultView
                } else {
                    TransferProgressCard(verb: "Saving", onCancel: onCancel)
                }
            }
            .padding(Space.l)
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: finished)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(server.isTransferring)
        .onChange(of: server.isTransferring) { _, transferring in
            // Auto-dismiss shortly after a fully successful save; on partial
            // failure, leave it up so the count is noticed.
            if !transferring && server.transferFailed == 0 {
                Task {
                    try? await Task.sleep(for: .seconds(1.8))
                    if !server.isTransferring { dismiss() }
                }
            }
        }
    }

    private var resultView: some View {
        let ok = server.transferFailed == 0
        return VStack(spacing: Space.l) {
            ZStack {
                Circle().fill((ok ? Theme.success : Theme.warning).opacity(0.16))
                    .frame(width: 96, height: 96)
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(ok ? Theme.success : Theme.warning)
                    .symbolEffect(.bounce, value: server.transferResult)
            }
            VStack(spacing: Space.xs) {
                Text(server.transferResult ?? "Done")
                    .font(.title3.weight(.bold)).multilineTextAlignment(.center)
                Text("Placed back on your timeline with their original dates")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            PrimaryButton(title: "Done", icon: "checkmark") { dismiss() }
                .frame(maxWidth: 260)
        }
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }
}
