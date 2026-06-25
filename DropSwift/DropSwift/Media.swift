//
//  Media.swift
//  DropSwift
//
//  Gallery building blocks: media-type detection, thumbnails, and the
//  full-screen viewer (zoomable photos + in-app video playback).
//

import SwiftUI
import Combine
import AVKit
import ImageIO

enum MediaKind {
    case image, video, other

    static func of(_ name: String) -> MediaKind {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "tif", "bmp"].contains(ext) {
            return .image
        }
        if ["mov", "mp4", "m4v", "avi", "mkv", "hevc", "3gp", "webm"].contains(ext) {
            return .video
        }
        return .other
    }
}

/// Simple in-memory thumbnail cache (NSCache is thread-safe).
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()
    func image(for key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    func set(_ image: UIImage, for key: String) { cache.setObject(image, forKey: key as NSString) }
}

/// Downsamples image data to a thumbnail using ImageIO (handles HEIC).
func makeThumbnail(from data: Data, maxPixel: CGFloat) -> UIImage? {
    guard let src = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    return UIImage(cgImage: cg)
}

/// Grabs the first frame of a video for use as a thumbnail.
func makeVideoThumbnail(asset: AVURLAsset) async -> UIImage? {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 600, height: 600)
    do {
        let result = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600))
        return UIImage(cgImage: result.image)
    } catch {
        return nil
    }
}

// MARK: - Grid cells

struct MediaCell: View {
    @EnvironmentObject var server: ServerConnection
    let file: RemoteFile
    let path: String

    @State private var image: UIImage?

    private var kind: MediaKind { MediaKind.of(file.name) }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)          // perfect square slot
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if kind == .other {
                    ZStack {
                        Rectangle().fill(Color.gray.opacity(0.15))
                        VStack(spacing: 4) {
                            Image(systemName: "doc.fill").font(.title3)
                            Text(file.name).font(.caption2).lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.secondary)
                        .padding(4)
                    }
                } else {
                    ZStack {
                        Rectangle().fill(Color.gray.opacity(0.12))
                        ProgressView()
                    }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if kind == .video {
                    Image(systemName: "play.fill")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .padding(6)
                }
            }
            .clipped()                                   // crop overflow to the square
            .contentShape(Rectangle())
            .task { await load() }
    }

    private func load() async {
        if let cached = ThumbnailCache.shared.image(for: path) { image = cached; return }
        switch kind {
        case .image:
            guard let data = try? await server.fileData(path: path),
                  let thumb = makeThumbnail(from: data, maxPixel: 400) else { return }
            ThumbnailCache.shared.set(thumb, for: path)
            image = thumb
        case .video:
            guard let asset = server.videoAsset(path: path),
                  let thumb = await makeVideoThumbnail(asset: asset) else { return }
            ThumbnailCache.shared.set(thumb, for: path)
            image = thumb
        case .other:
            break
        }
    }
}

struct FolderCell: View {
    let name: String
    var body: some View {
        Color.gray.opacity(0.14)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.accent)
                    Text(name).font(.caption2).lineLimit(1)
                        .foregroundStyle(.primary).padding(.horizontal, 6)
                }
            }
    }
}

// MARK: - Full-screen viewer

struct SelectedMedia: Identifiable {
    let path: String
    let name: String
    var id: String { path }
}

/// Full-screen, swipeable viewer — flick left/right between photos & videos,
/// pinch to zoom photos, videos play in place. Like the Photos app.
struct MediaPager: View {
    let items: [SelectedMedia]
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    @State private var dragOffset: CGFloat = 0

    init(items: [SelectedMedia], startIndex: Int) {
        self.items = items
        _index = State(initialValue: startIndex)
    }

    private var bgOpacity: Double { max(0, 1 - Double(dragOffset) / 500) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(bgOpacity).ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, media in
                    MediaPage(media: media).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .scaleEffect(1 - min(0.12, dragOffset / 2000))
            .offset(y: dragOffset)
            // Swipe DOWN to dismiss (like Photos). Only reacts to a clearly
            // vertical-downward drag, so horizontal paging still works.
            .simultaneousGesture(
                DragGesture(minimumDistance: 14)
                    .onChanged { v in
                        if v.translation.height > 0,
                           v.translation.height > abs(v.translation.width) {
                            dragOffset = v.translation.height
                        }
                    }
                    .onEnded { v in
                        if v.translation.height > 160,
                           v.translation.height > abs(v.translation.width) {
                            // Slide the content the rest of the way off, then
                            // dismiss WITHOUT the system cover animation — avoids
                            // the "second window closing" double effect.
                            withAnimation(.easeOut(duration: 0.22)) { dragOffset = 1500 }
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(220))
                                var t = Transaction()
                                t.disablesAnimations = true
                                withTransaction(t) { dismiss() }
                            }
                        } else {
                            withAnimation(.spring(response: 0.3)) { dragOffset = 0 }
                        }
                    }
            )

            if items.count > 1 {
                Text("\(index + 1) of \(items.count)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 14)
                    .opacity(dragOffset > 0 ? 0 : 1)
            }
        }
        .statusBarHidden(true)
    }
}

/// One page in the pager: a zoomable photo or an in-place video player.
struct MediaPage: View {
    @EnvironmentObject var server: ServerConnection
    let media: SelectedMedia

    var body: some View {
        switch MediaKind.of(media.name) {
        case .video:
            if let asset = server.videoAsset(path: media.path) {
                VideoPlayerView(asset: asset)
            } else {
                Color.black
            }
        default:
            ZoomableImage(path: media.path)
        }
    }
}

/// Drives an AVPlayer with custom (non-conflicting) controls.
@MainActor
final class VideoModel: ObservableObject {
    let player = AVPlayer()
    @Published var current: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    var scrubbing = false
    private var token: Any?

    func load(_ asset: AVURLAsset) {
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        token = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.3, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.scrubbing { self.current = max(0, time.seconds) }
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                    self.duration = d
                }
                self.isPlaying = self.player.rate > 0
            }
        }
    }

    func toggle() {
        if player.rate > 0 { player.pause() } else { player.play() }
        isPlaying = player.rate > 0
    }

    func seek(_ t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
    }

    func teardown() {
        if let token { player.removeTimeObserver(token) }
        token = nil
        player.pause()
    }
}

/// Renders the video frame with NO native controls (so nothing overlaps our
/// own close/share buttons), then overlays a custom play button + scrubber.
struct VideoSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = false
        vc.videoGravity = .resizeAspect
        vc.allowsPictureInPicturePlayback = false
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
}

struct VideoPlayerView: View {
    let asset: AVURLAsset
    @StateObject private var model = VideoModel()
    @State private var showControls = true

    var body: some View {
        ZStack {
            VideoSurface(player: model.player)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { showControls.toggle() } }

            if showControls {
                Button { model.toggle() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(.black.opacity(0.35), in: Circle())
                }

                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        Text(Self.fmt(model.current))
                            .font(.caption2).monospacedDigit().foregroundStyle(.white)
                        Slider(value: $model.current, in: 0...max(model.duration, 0.1)) { editing in
                            model.scrubbing = editing
                            if !editing { model.seek(model.current) }
                        }
                        .tint(.white)
                        Text(Self.fmt(model.duration))
                            .font(.caption2).monospacedDigit().foregroundStyle(.white)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .glass(Capsule())
                    .padding(.horizontal, 16)
                    .padding(.bottom, 30)
                }
            }
        }
        .onAppear { model.load(asset) }
        .onDisappear { model.teardown() }
    }

    static func fmt(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Loads a full image and lets the user pinch-zoom / double-tap to zoom.
struct ZoomableImage: View {
    @EnvironmentObject var server: ServerConnection
    let path: String

    @State private var uiImage: UIImage?
    @State private var scale: CGFloat = 1

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { scale = max(1, $0) }
                            .onEnded { _ in withAnimation { scale = min(max(scale, 1), 4) } }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation { scale = scale > 1 ? 1 : 2.5 }
                    }
            } else {
                ProgressView().tint(.white)
            }
        }
        .task {
            if let data = try? await server.fileData(path: path) {
                uiImage = UIImage(data: data)
            }
        }
    }
}
