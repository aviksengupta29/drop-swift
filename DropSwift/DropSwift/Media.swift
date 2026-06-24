//
//  Media.swift
//  DropSwift
//
//  Gallery building blocks: media-type detection, thumbnails, and the
//  full-screen viewer (zoomable photos + in-app video playback).
//

import SwiftUI
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
func makeVideoThumbnail(url: URL) async -> UIImage? {
    let asset = AVURLAsset(url: url)
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
            guard let url = server.fileURL(path: path),
                  let thumb = await makeVideoThumbnail(url: url) else { return }
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
                        .foregroundStyle(Brand.violet)
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
    @EnvironmentObject var server: ServerConnection
    let items: [SelectedMedia]
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    @State private var shareURL: URL?
    @State private var showShare = false

    init(items: [SelectedMedia], startIndex: Int) {
        self.items = items
        _index = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, media in
                    MediaPage(media: media).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                Spacer()
                if items.count > 1 {
                    Text("\(index + 1) of \(items.count)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Button { Task { await share() } } label: { Image(systemName: "square.and.arrow.up.circle.fill") }
            }
            .font(.system(size: 28))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
        .statusBarHidden(true)
        .sheet(isPresented: $showShare) {
            if let shareURL { ShareSheet(items: [shareURL]) }
        }
    }

    private func share() async {
        let media = items[index]
        if let url = try? await server.download(path: media.path, name: media.name) {
            shareURL = url
            showShare = true
        }
    }
}

/// One page in the pager: a zoomable photo or an in-place video player.
struct MediaPage: View {
    @EnvironmentObject var server: ServerConnection
    let media: SelectedMedia

    var body: some View {
        switch MediaKind.of(media.name) {
        case .video:
            if let url = server.fileURL(path: media.path) {
                VideoPlayerView(url: url)
            } else {
                Color.black
            }
        default:
            ZoomableImage(path: media.path)
        }
    }
}

/// Streams and auto-plays a video.
struct VideoPlayerView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .onAppear {
                if player == nil { player = AVPlayer(url: url) }
            }
            .onDisappear { player?.pause() }
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
