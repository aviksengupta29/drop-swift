//
//  ServerConnection.swift
//  DropSwift
//
//  Talks to the DropSwift laptop server over the local network.
//

import Foundation
import Combine
import SwiftUI
import PhotosUI
import Photos

/// Errors surfaced to the UI.
enum ServerError: LocalizedError {
    case notConnected
    case badAddress
    case http(Int)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to a computer yet."
        case .badAddress:   return "Enter a valid host and port."
        case .http(let c):  return "Server returned HTTP \(c)."
        case .message(let m): return m
        }
    }
}

/// Holds the connection details and performs all network calls.
@MainActor
final class ServerConnection: ObservableObject {
    @Published var host: String { didSet { save() } }
    @Published var port: String { didSet { save() } }
    @Published var isConnected = false
    @Published var serverName = ""
    @Published var lastError: String?

    // Transfer progress (observed by the UI for the progress bar).
    @Published var isTransferring = false
    @Published var transferTotal = 0
    @Published var transferCompleted = 0
    @Published var transferCurrentName = ""
    @Published var transferFileFraction: Double = 0   // 0...1 for the current file
    @Published var transferResult: String?

    /// Overall 0...1 progress across the whole batch.
    var transferOverall: Double {
        guard transferTotal > 0 else { return 0 }
        return (Double(transferCompleted) + transferFileFraction) / Double(transferTotal)
    }

    private let session: URLSession

    init() {
        let d = UserDefaults.standard
        self.host = d.string(forKey: "dropswift.host") ?? ""
        self.port = d.string(forKey: "dropswift.port") ?? "8080"
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120              // idle timeout between packets
        config.timeoutIntervalForResource = 60 * 60 * 24    // allow very large transfers
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(host, forKey: "dropswift.host")
        d.set(port, forKey: "dropswift.port")
    }

    /// Builds a URL like http://192.168.1.5:8080/api/list?path=Photos
    private func url(_ path: String, query: [String: String] = [:]) throws -> URL {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let portNum = Int(port) else { throw ServerError.badAddress }
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = trimmed
        comps.port = portNum
        comps.path = path
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let u = comps.url else { throw ServerError.badAddress }
        return u
    }

    // MARK: - Endpoints

    /// Pings the server and records whether we're connected.
    func connect() async {
        lastError = nil
        do {
            let (data, response) = try await session.data(from: try url("/api/health"))
            try Self.check(response)
            let health = try JSONDecoder().decode(Health.self, from: data)
            serverName = health.name
            isConnected = true
        } catch {
            isConnected = false
            serverName = ""
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Drops the current connection (the computer stays discoverable).
    func disconnect() {
        isConnected = false
        serverName = ""
        lastError = nil
    }

    /// Lists a folder on the laptop.
    func list(path: String) async throws -> Listing {
        let (data, response) = try await session.data(from: try url("/api/list", query: ["path": path]))
        try Self.check(response)
        return try JSONDecoder().decode(Listing.self, from: data)
    }

    /// Direct URL used to stream a video or load an image (AVPlayer / ImageIO).
    func fileURL(path: String) -> URL? {
        try? url("/api/download", query: ["path": path])
    }

    /// Raw bytes of a file (used to build image thumbnails / full images).
    func fileData(path: String) async throws -> Data {
        let (data, response) = try await session.data(from: try url("/api/download", query: ["path": path]))
        try Self.check(response)
        return data
    }

    /// Downloads a file to a temporary location and returns its local URL.
    func download(path: String, name: String) async throws -> URL {
        let (data, response) = try await session.data(from: try url("/api/download", query: ["path": path]))
        try Self.check(response)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try data.write(to: dest)
        return dest
    }

    /// Max items per batch (keeps memory/UX sane for very large transfers).
    static let maxBatch = 50

    /// Sends each photo/video to the laptop one at a time, STREAMING from disk
    /// (never loading whole files into memory), keeping the original filename
    /// and metadata. Honors task cancellation between/within files.
    func sendPhotos(_ items: [PhotosPickerItem]) async {
        let batch = Array(items.prefix(Self.maxBatch))
        isTransferring = true
        transferTotal = batch.count
        transferCompleted = 0
        transferFileFraction = 0
        transferResult = nil
        var failures = 0

        // Needed to read the original file + filename from the photo library.
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }

        let stamp = Int(Date().timeIntervalSince1970)
        for (index, item) in batch.enumerated() {
            if Task.isCancelled { break }
            transferFileFraction = 0

            // Write the original to a temp file on disk (low memory), then
            // stream-upload that file and delete it.
            if let (tempURL, name) = await Self.writeOriginalToTemp(for: item) {
                transferCurrentName = name
                do {
                    try await uploadFile(at: tempURL, filename: name)
                    transferCompleted += 1
                } catch {
                    if !Task.isCancelled { failures += 1 }
                }
                try? FileManager.default.removeItem(at: tempURL)
            } else if let data = try? await item.loadTransferable(type: Data.self) {
                // Rare fallback for items without a library identifier.
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "dat"
                let name = "DropSwift_\(stamp)_\(index).\(ext)"
                transferCurrentName = name
                do {
                    try await uploadData(data, filename: name)
                    transferCompleted += 1
                } catch {
                    if !Task.isCancelled { failures += 1 }
                }
            } else {
                failures += 1
            }

            if Task.isCancelled { break }
        }

        isTransferring = false
        transferFileFraction = 0
        if Task.isCancelled {
            transferResult = "Stopped. Sent \(transferCompleted) of \(transferTotal)."
        } else {
            transferResult = failures == 0
                ? "Sent \(transferCompleted) item(s) to \(serverName)."
                : "Sent \(transferCompleted), failed \(failures). Check the connection and try again."
        }
    }

    /// Writes a picked item's ORIGINAL resource to a temp file on disk, streaming
    /// (low memory). Returns the temp URL + the original filename.
    nonisolated private static func writeOriginalToTemp(for item: PhotosPickerItem) async -> (URL, String)? {
        guard let id = item.itemIdentifier else { return nil }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = assets.firstObject else { return nil }

        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: PHAssetResourceType = asset.mediaType == .video ? .video : .photo
        guard let resource = resources.first(where: { $0.type == preferred }) ?? resources.first else {
            return nil
        }

        let name = resource.originalFilename
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + name)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true   // allow fetching from iCloud

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: tempURL, options: options) { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
            return (tempURL, name)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }
    }

    /// Streams a file from disk to the laptop (constant low memory), reporting
    /// per-file progress into `transferFileFraction`.
    func uploadFile(at fileURL: URL, filename: String, toPath: String = "") async throws {
        var request = URLRequest(url: try url("/api/upload", query: ["path": toPath]))
        request.httpMethod = "POST"
        request.setValue(filename, forHTTPHeaderField: "X-Filename")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let delegate = UploadProgressDelegate { [weak self] fraction in
            Task { @MainActor in self?.transferFileFraction = fraction }
        }
        let (_, response) = try await session.upload(for: request, fromFile: fileURL, delegate: delegate)
        try Self.check(response)
    }

    /// Small in-memory upload (fallback path only).
    func uploadData(_ data: Data, filename: String, toPath: String = "") async throws {
        var request = URLRequest(url: try url("/api/upload", query: ["path": toPath]))
        request.httpMethod = "POST"
        request.setValue(filename, forHTTPHeaderField: "X-Filename")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let delegate = UploadProgressDelegate { [weak self] fraction in
            Task { @MainActor in self?.transferFileFraction = fraction }
        }
        let (_, response) = try await session.upload(for: request, from: data, delegate: delegate)
        try Self.check(response)
    }

    // MARK: - Helpers

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw ServerError.http(http.statusCode)
        }
    }
}

/// Reports upload byte-progress for the progress bar.
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(min(1.0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}
