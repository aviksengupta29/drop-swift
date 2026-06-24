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
        ZStack {
            Rectangle().fill(Color.gray.opacity(0.14))

            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if kind == .other {
                VStack(spacing: 6) {
                    Image(systemName: "doc.fill").font(.title2)
                    Text(file.name).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding(6)
            } else {
                ProgressView()
            }

            if kind == .video {
                Image(systemName: "play.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(.black.opacity(0.45), in: Circle())
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        VStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 38))
                .foregroundStyle(Brand.violet)
            Text(name).font(.caption).lineLimit(1).foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fill)
        .background(Color.gray.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Full-screen viewer

struct SelectedMedia: Identifiable {
    let path: String
    let name: String
    var id: String { path }
}

struct MediaViewer: View {
    @EnvironmentObject var server: ServerConnection
    let media: SelectedMedia
    @Environment(\.dismiss) private var dismiss

    @State private var shareURL: URL?
    @State private var showShare = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            switch MediaKind.of(media.name) {
            case .video:
                if let url = server.fileURL(path: media.path) {
                    VideoPlayerView(url: url)
                }
            case .image:
                ZoomableImage(path: media.path)
            case .other:
                ProgressView().tint(.white)
            }

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                Spacer()
                Button { Task { await share() } } label: {
                    Image(systemName: "square.and.arrow.up.circle.fill")
                }
            }
            .font(.system(size: 30))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 18)
            .padding(.top, 12)
        }
        .sheet(isPresented: $showShare) {
            if let shareURL { ShareSheet(items: [shareURL]) }
        }
    }

    private func share() async {
        if let url = try? await server.download(path: media.path, name: media.name) {
            shareURL = url
            showShare = true
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
                let p = AVPlayer(url: url)
                player = p
                p.play()
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
