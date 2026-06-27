//
//  ServerConnection.swift
//  DropSwift
//
//  Talks to the DropSwift laptop server over the local network.
//

import Foundation
import Combine
import SwiftUI
import UIKit
import PhotosUI
import Photos
import AVFoundation
import ActivityKit

/// Errors surfaced to the UI.
enum ServerError: LocalizedError {
    case notConnected
    case badAddress
    case http(Int)
    case unauthorized
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to a computer yet."
        case .badAddress:   return "Enter a valid host and port."
        case .http(let c):  return "Server returned HTTP \(c)."
        case .unauthorized: return "The access code is no longer valid."
        case .message(let m): return m
        }
    }
}

/// Response from /api/auth.
private struct AuthResult: Codable {
    let token: String
    let name: String?
}

/// Holds the connection details and performs all network calls.
@MainActor
final class ServerConnection: ObservableObject {
    @Published var host: String { didSet { save() } }
    @Published var port: String { didSet { save() } }
    @Published var isConnected = false
    @Published var serverName = ""
    @Published var lastError: String?

    /// Set true when the background heartbeat loses contact — drives the in-app
    /// "disconnected" popup.
    @Published var didDisconnectUnexpectedly = false

    /// Set true when the server needs the 6-digit access code — drives the
    /// code-entry sheet.
    @Published var needsCode = false

    /// True while a connect/auto-connect is in flight.
    @Published var isConnecting = false

    private var heartbeat: Task<Void, Never>?
    private var token: String?
    private var currentKey = ""              // stable per-computer key for stored creds
    private var isAutoConnecting = false
    private var suppressAutoConnect = false  // set after a manual disconnect

    /// Bonjour discovery runs continuously (all tabs) and is the PRIMARY way we
    /// notice a server vanish — the instant it leaves the list we disconnect.
    @Published var discoveredServers: [DiscoveredServer] = []
    private let discovery = Discovery()
    private var discoverySub: AnyCancellable?
    private var connectedServerId: String?   // Bonjour id of the server we're on

    /// Start (or re-arm) Bonjour discovery. Safe to call repeatedly — we restart
    /// the browser each time so it recovers after backgrounding, a network change,
    /// or the Local Network permission being granted after launch. Re-starting the
    /// browser does NOT clear the current list, so connected servers don't flicker.
    func startDiscovery() {
        if discoverySub == nil {
            discoverySub = discovery.$servers.sink { [weak self] servers in
                Task { @MainActor in self?.onDiscovered(servers) }
            }
        }
        discovery.start()
    }

    func refreshDiscovery() { discovery.refresh() }

    private func onDiscovered(_ servers: [DiscoveredServer]) {
        discoveredServers = servers
        // VANISH: if the computer we're connected to leaves the list, it's gone.
        // (Skip during a transfer — the live connection is proof it's alive and a
        // momentary mDNS blip shouldn't interrupt it.)
        if isConnected, !isTransferring, let id = connectedServerId,
           !servers.contains(where: { $0.id == id }) {
            markDisconnected()
            return
        }
        Task { await autoConnectIfKnown(servers) }
    }

    // Credentials are stored per computer (keyed by its stable Bonjour name when
    // discovered, or host:port for manual entry) so they survive IP changes.
    private let lastCodeKey = "dropswift.lastCode"

    private func tokenKey() -> String { "dropswift.token.\(currentKey)" }
    private func codeKey() -> String { "dropswift.code.\(currentKey)" }
    private func loadToken() -> String? { UserDefaults.standard.string(forKey: tokenKey()) }
    private func saveToken(_ t: String) { UserDefaults.standard.set(t, forKey: tokenKey()) }
    /// Per-computer code, falling back to the last code that ever worked — so a
    /// key mismatch (IP change, manual vs discovery) never forces a re-prompt.
    private func loadCode() -> String? {
        UserDefaults.standard.string(forKey: codeKey())
            ?? UserDefaults.standard.string(forKey: lastCodeKey)
    }
    private func saveCode(_ c: String) {
        UserDefaults.standard.set(c, forKey: codeKey())
        UserDefaults.standard.set(c, forKey: lastCodeKey)
    }
    private func clearToken() {
        token = nil
        UserDefaults.standard.removeObject(forKey: tokenKey())
    }

    /// Builds a request carrying the auth token (when we have one).
    private func authed(_ path: String, query: [String: String] = [:]) throws -> URLRequest {
        var request = URLRequest(url: try url(path, query: query))
        if let token { request.setValue(token, forHTTPHeaderField: "X-Auth-Token") }
        return request
    }

    // Transfer progress (observed by the UI for the progress bar).
    @Published var isTransferring = false
    @Published var transferTotal = 0
    @Published var transferCompleted = 0
    @Published var transferCurrentName = ""
    @Published var activeFractions: [Int: Double] = [:]   // in-flight per-file progress
    @Published var transferResult: String?
    @Published var transferSpeed: Double = 0      // bytes/sec (Send UI + Live Activity)
    @Published var transferETADate: Date?         // projected completion time

    /// How many uploads run at once — overlaps photo-library export with network
    /// transfer and uses several streams (like a download manager).
    static let maxParallelUploads = 3

    /// Overall 0...1 progress across the whole batch.
    var transferOverall: Double {
        guard transferTotal > 0 else { return 0 }
        let inflight = activeFractions.values.reduce(0, +)
        return min(1, (Double(transferCompleted) + inflight) / Double(transferTotal))
    }

    private let session: URLSession       // transfers (waits for connectivity)
    private let pingSession: URLSession   // heartbeat (fails fast)

    init() {
        let d = UserDefaults.standard
        self.host = d.string(forKey: "dropswift.host") ?? ""
        self.port = d.string(forKey: "dropswift.port") ?? "8080"

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120              // idle timeout between packets
        config.timeoutIntervalForResource = 60 * 60 * 24    // allow very large transfers
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)

        // Dedicated session for health pings: ephemeral (no connection reuse /
        // caching) and fails fast so a dropped server is detected quickly.
        let ping = URLSessionConfiguration.ephemeral
        ping.timeoutIntervalForRequest = 8
        ping.timeoutIntervalForResource = 10
        ping.waitsForConnectivity = false
        ping.requestCachePolicy = .reloadIgnoringLocalCacheData
        ping.urlCache = nil
        self.pingSession = URLSession(configuration: ping)
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

    /// Connect to a discovered computer (remembers it by its stable name).
    func connect(to found: DiscoveredServer) async {
        suppressAutoConnect = false
        currentKey = found.id
        connectedServerId = found.id
        host = found.host
        port = String(found.port)
        await connect()
    }

    /// Connect using the manually-entered host/port.
    func connectManually() async {
        suppressAutoConnect = false
        currentKey = "host:\(host.trimmingCharacters(in: .whitespaces)):\(port)"
        await connect()
    }

    /// Checks the server is reachable, then either reuses a saved token, silently
    /// re-authenticates with the saved code, or asks for the code (first time).
    func connect() async {
        if currentKey.isEmpty { currentKey = "host:\(host):\(port)" }
        lastError = nil
        didDisconnectUnexpectedly = false
        needsCode = false
        isConnecting = true
        defer { isConnecting = false }
        token = loadToken()
        do {
            let (data, response) = try await session.data(from: try url("/api/health"))
            try Self.check(response)
            let health = try JSONDecoder().decode(Health.self, from: data)
            serverName = health.name

            if token != nil, await verifyToken() {
                isConnected = true; startHeartbeat(); return
            }
            // Token missing/expired: try the saved code silently, else prompt.
            if let code = loadCode(), await authenticate(code: code) {
                isConnected = true; startHeartbeat(); return
            }
            clearToken()
            isConnected = false
            needsCode = true
        } catch {
            isConnected = false
            serverName = ""
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Auto-connect to the first discovered computer we already have a code for —
    /// no tap, no code prompt.
    func autoConnectIfKnown(_ servers: [DiscoveredServer]) async {
        guard !isConnected, !isConnecting, !isAutoConnecting,
              !suppressAutoConnect, !needsCode else { return }
        isAutoConnecting = true
        defer { isAutoConnecting = false }

        // Auto-connect if we have a code for this computer, or any last-used code.
        let hasAnyCode = UserDefaults.standard.string(forKey: lastCodeKey) != nil
        for found in servers {
            let hasCode = UserDefaults.standard.string(forKey: "dropswift.code.\(found.id)") != nil || hasAnyCode
            guard hasCode else { continue }
            currentKey = found.id
            connectedServerId = found.id
            host = found.host
            port = String(found.port)
            isConnecting = true
            await connect()
            isConnecting = false
            if isConnected { return }
        }
    }

    /// Exchanges the 6-digit code for a session token (called from the code sheet).
    func submitCode(_ code: String) async {
        lastError = nil
        if await authenticate(code: code) {
            needsCode = false
            isConnected = true
            startHeartbeat()
        } else {
            lastError = "Invalid code. Please try again."
        }
    }

    /// POSTs the code, stores the token AND the code (for future auto-connect).
    @discardableResult
    private func authenticate(code: String) async -> Bool {
        do {
            var request = URLRequest(url: try url("/api/auth"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            let result = try JSONDecoder().decode(AuthResult.self, from: data)
            token = result.token
            saveToken(result.token)
            saveCode(code)
            if let name = result.name, !name.isEmpty { serverName = name }
            return true
        } catch {
            return false
        }
    }

    /// Drops the current connection and suppresses auto-connect for this session.
    /// Keeps the saved code so reconnecting doesn't re-prompt.
    func disconnect() {
        stopHeartbeat()
        suppressAutoConnect = true
        connectedServerId = nil
        isConnected = false
        serverName = ""
        lastError = nil
    }

    private func verifyToken() async -> Bool {
        guard token != nil else { return false }
        do {
            let (_, response) = try await pingSession.data(for: try authed("/api/ping"))
            if let http = response as? HTTPURLResponse { return http.statusCode == 200 }
            return false
        } catch {
            return false
        }
    }

    // MARK: - Background heartbeat

    /// Keep-alive: a tiny `/api/health` GET every 2s while connected and IDLE.
    /// During a transfer it does NOT ping at all (zero impact on transfer
    /// speed) — a dropped server is detected from the upload failures instead.
    /// Two misses in a row → mark disconnected and raise the popup (~4s).
    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))   // safety net; vanish is the fast path
                if Task.isCancelled { break }
                guard let self else { break }

                // While transferring, the active connection proves the server is
                // alive and we must not steal any bandwidth — so skip the probe.
                if self.isTransferring {
                    failures = 0
                    continue
                }

                switch await self.pingStatus() {
                case .ok:
                    failures = 0
                case .unauthorized:
                    // Token expired (server restarted). Silently re-authenticate
                    // with the saved code; only prompt if that also fails.
                    if let code = self.loadCode(), await self.authenticate(code: code) {
                        failures = 0
                    } else {
                        self.clearToken()
                        self.stopHeartbeat()
                        self.isConnected = false
                        self.needsCode = true
                        return
                    }
                case .fail:
                    failures += 1
                    if failures >= 2 {
                        self.markDisconnected()
                        return
                    }
                }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    private func markDisconnected() {
        stopHeartbeat()
        connectedServerId = nil
        isConnected = false
        serverName = ""
        didDisconnectUnexpectedly = true
    }

    /// Immediate health check — used when the app returns to the foreground
    /// (the heartbeat is suspended while backgrounded).
    func checkNow() async {
        guard isConnected else { return }
        switch await pingStatus() {
        case .ok:
            break
        case .unauthorized:
            clearToken(); stopHeartbeat(); isConnected = false; needsCode = true
        case .fail:
            if case .fail = await pingStatus() { markDisconnected() }   // confirm once
        }
    }

    private enum PingResult { case ok, fail, unauthorized }

    /// A single small, short-timeout authenticated health check.
    private func pingStatus() async -> PingResult {
        guard let request = try? authed("/api/ping") else { return .fail }
        var req = request
        req.timeoutInterval = 5
        do {
            let (_, response) = try await pingSession.data(for: req)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 { return .unauthorized }
                return (200..<300).contains(http.statusCode) ? .ok : .fail
            }
            return .ok
        } catch {
            return .fail
        }
    }

    /// Lists a folder on the laptop.
    func list(path: String) async throws -> Listing {
        let (data, response) = try await session.data(for: try authed("/api/list", query: ["path": path]))
        try Self.check(response)
        return try JSONDecoder().decode(Listing.self, from: data)
    }

    /// Direct URL used to load an image (token attached via fileData) — kept for
    /// non-authenticated callers; video uses `videoAsset(path:)`.
    func fileURL(path: String) -> URL? {
        try? url("/api/download", query: ["path": path])
    }

    /// AVURLAsset for streaming a video, with the auth token in the HTTP headers.
    func videoAsset(path: String) -> AVURLAsset? {
        guard let u = try? url("/api/download", query: ["path": path]) else { return nil }
        var options: [String: Any] = [:]
        if let token { options["AVURLAssetHTTPHeaderFieldsKey"] = ["X-Auth-Token": token] }
        return AVURLAsset(url: u, options: options)
    }

    /// Raw bytes of a file (used to build image thumbnails / full images).
    func fileData(path: String) async throws -> Data {
        let (data, response) = try await session.data(for: try authed("/api/download", query: ["path": path]))
        try Self.check(response)
        return data
    }

    /// Downloads a file to a temporary location and returns its local URL.
    func download(path: String, name: String) async throws -> URL {
        let (data, response) = try await session.data(for: try authed("/api/download", query: ["path": path]))
        try Self.check(response)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try data.write(to: dest)
        return dest
    }

    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    private func endBackgroundTask() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    // MARK: - Live Activity (Dynamic Island)

    private var liveActivity: Activity<TransferActivityAttributes>?

    // Live speed / ETA tracking for the Dynamic Island + Live Activity.
    private var bytesSent: Int64 = 0
    private var transferStart: Date?
    private var speedSampleBytes: Int64 = 0
    private var speedSampleDate: Date?
    private var smoothedSpeed: Double = 0
    private var lastHapticBucket = 0

    /// Resets the speed/ETA accumulators at the start of a transfer.
    private func resetTransferMetrics() {
        bytesSent = 0
        transferStart = Date()
        speedSampleBytes = 0
        speedSampleDate = nil
        smoothedSpeed = 0
        lastHapticBucket = 0
        transferSpeed = 0
        transferETADate = nil
    }

    private func startLiveActivity(total: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = TransferActivityAttributes(serverName: serverName)
        let state = TransferActivityAttributes.ContentState(
            completed: 0, total: total, fraction: 0, currentName: "", done: false)
        liveActivity = try? Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: nil))
    }

    private func updateLiveActivity() {
        let now = Date()

        // Smoothed transfer speed (EMA over ~0.5s samples).
        if let last = speedSampleDate {
            let dt = now.timeIntervalSince(last)
            if dt >= 0.5 {
                let inst = Double(bytesSent - speedSampleBytes) / dt
                smoothedSpeed = smoothedSpeed == 0 ? inst : smoothedSpeed * 0.6 + inst * 0.4
                speedSampleDate = now
                speedSampleBytes = bytesSent
            }
        } else {
            speedSampleDate = now
            speedSampleBytes = bytesSent
        }

        // Projected completion time (from elapsed time + overall progress).
        var etaDate: Date?
        let f = transferOverall
        if let start = transferStart, f > 0.02 {
            let elapsed = now.timeIntervalSince(start)
            let remaining = elapsed * (1 - f) / f
            if remaining.isFinite, remaining > 1, remaining < 86_400 {
                etaDate = now.addingTimeInterval(remaining)
            }
        }

        // Publish for the in-app Send screen.
        transferSpeed = max(0, smoothedSpeed)
        transferETADate = etaDate

        // Milestone haptics (play when foregrounded — screen stays awake mid-transfer).
        let bucket = Int(f * 4)
        if bucket > lastHapticBucket, bucket < 4 {
            lastHapticBucket = bucket
            Haptics.light()
        }

        guard let liveActivity else { return }
        let state = TransferActivityAttributes.ContentState(
            completed: transferCompleted, total: transferTotal,
            fraction: f, currentName: transferCurrentName, done: false,
            speed: max(0, smoothedSpeed), etaDate: etaDate)
        Task { await liveActivity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    private func endLiveActivity() {
        guard let liveActivity else { return }
        let state = TransferActivityAttributes.ContentState(
            completed: transferCompleted, total: transferTotal,
            fraction: 1, currentName: "", done: true, speed: 0, etaDate: nil)
        let finished = liveActivity
        self.liveActivity = nil
        Task {
            await finished.end(ActivityContent(state: state, staleDate: nil),
                               dismissalPolicy: .after(Date().addingTimeInterval(4)))
        }
    }

    /// Sends an UNLIMITED number of photos/videos to the laptop, STREAMING each
    /// from disk (constant low memory — handles 1 TB+), keeping the original
    /// filename + metadata. Uploads several in parallel as a queue that refills,
    /// retries transient failures, and honors cancellation.
    func sendPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        isTransferring = true
        transferTotal = items.count
        transferCompleted = 0
        activeFractions = [:]
        transferResult = nil
        resetTransferMetrics()

        // Keep the screen awake and take a short background grace window so the
        // transfer isn't interrupted by screen sleep or brief backgrounding.
        UIApplication.shared.isIdleTimerDisabled = true
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "DropSwiftTransfer") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }

        // Dynamic Island / Lock Screen Live Activity (AirDrop-style progress).
        startLiveActivity(total: items.count)
        let liveUpdater = Task { @MainActor [weak self] in
            while self?.isTransferring == true {
                self?.updateLiveActivity()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }

        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            endBackgroundTask()
            liveUpdater.cancel()
            endLiveActivity()
        }

        // Needed to read the original file + filename from the photo library.
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }

        let stamp = Int(Date().timeIntervalSince1970)

        // Process the whole batch, then retry any failures in extra passes with
        // growing waits — so a transient drop (Wi‑Fi blip, the Mac briefly busy,
        // a momentary server hiccup) recovers instead of losing files over a
        // long transfer.
        var pending: [(Int, PhotosPickerItem)] = items.enumerated().map { ($0.offset, $0.element) }
        var pass = 0
        let maxPasses = 6
        while !pending.isEmpty && !Task.isCancelled {
            pass += 1
            pending = await runUploadPass(pending, stamp: stamp)
            guard !pending.isEmpty, !Task.isCancelled, pass < maxPasses else { break }
            let delay = Double(min(120, pass * 20))   // 20s, 40s, … up to 2 min
            transferCurrentName = "Waiting to retry \(pending.count) item(s)…"
            try? await Task.sleep(for: .seconds(delay))
        }

        let failures = pending.count
        isTransferring = false
        activeFractions = [:]
        if Task.isCancelled {
            transferResult = "Stopped. Sent \(transferCompleted) of \(transferTotal)."
        } else {
            transferResult = failures == 0
                ? "Sent \(transferCompleted) item(s) to \(serverName)."
                : "Sent \(transferCompleted), failed \(failures). Check the connection and try again."
        }
    }

    /// Uploads a batch of (index, item) with bounded concurrency; returns the
    /// items that failed so a later pass can retry them. Only `maxParallelUploads`
    /// items are exported-to-temp + uploading at once, so disk/memory stay flat
    /// no matter how many thousands are selected.
    private func runUploadPass(_ batch: [(Int, PhotosPickerItem)], stamp: Int) async -> [(Int, PhotosPickerItem)] {
        var failed: [(Int, PhotosPickerItem)] = []
        await withTaskGroup(of: (Int, PhotosPickerItem, Bool).self) { group in
            var next = 0
            let limit = min(Self.maxParallelUploads, batch.count)
            func add(_ k: Int) {
                let (idx, item) = batch[k]
                group.addTask { [weak self] in
                    let ok = await self?.uploadOne(item, index: idx, stamp: stamp) ?? false
                    return (idx, item, ok)
                }
            }
            while next < limit { add(next); next += 1 }
            while let (idx, item, ok) = await group.next() {
                if !ok && !Task.isCancelled { failed.append((idx, item)) }
                if next < batch.count && !Task.isCancelled { add(next); next += 1 }
            }
        }
        return failed
    }

    /// Exports one item to a temp file (original + metadata, or fallback) and
    /// stream-uploads it with retries. Returns true on success.
    private func uploadOne(_ item: PhotosPickerItem, index: Int, stamp: Int) async -> Bool {
        if Task.isCancelled { return false }
        activeFractions[index] = 0

        let fileURL: URL
        let name: String
        if let (tmp, original) = await Self.writeOriginalToTemp(for: item) {
            fileURL = tmp
            name = original
        } else if let data = try? await item.loadTransferable(type: Data.self) {
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "dat"
            name = "DropSwift_\(stamp)_\(index).\(ext)"
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-" + name)
            guard (try? data.write(to: tmp)) != nil else { activeFractions[index] = nil; return false }
            fileURL = tmp
        } else {
            activeFractions[index] = nil
            return false
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }

        transferCurrentName = name

        var attempt = 0
        while attempt < 3 && !Task.isCancelled {
            do {
                try await uploadFile(at: fileURL, filename: name, index: index)
                activeFractions[index] = nil
                transferCompleted += 1
                return true
            } catch {
                attempt += 1
                activeFractions[index] = 0
                if attempt < 3 && !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))   // brief backoff, then retry
                }
            }
        }
        activeFractions[index] = nil
        return false
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
    /// per-file progress into `activeFractions[index]`.
    func uploadFile(at fileURL: URL, filename: String, index: Int, toPath: String = "") async throws {
        var request = try authed("/api/upload", query: ["path": toPath])
        request.httpMethod = "POST"
        request.setValue(filename, forHTTPHeaderField: "X-Filename")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let delegate = UploadProgressDelegate(onProgress: { [weak self] fraction in
            Task { @MainActor in self?.activeFractions[index] = fraction }
        }, onBytes: { [weak self] delta in
            Task { @MainActor in self?.bytesSent += delta }
        })
        let (_, response) = try await session.upload(for: request, fromFile: fileURL, delegate: delegate)
        try Self.check(response)
    }

    // MARK: - Helpers

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 { throw ServerError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw ServerError.http(http.statusCode)
        }
    }
}

/// Reports upload byte-progress for the progress bar.
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private let onBytes: @Sendable (Int64) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void,
         onBytes: @escaping @Sendable (Int64) -> Void = { _ in }) {
        self.onProgress = onProgress
        self.onBytes = onBytes
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        onBytes(bytesSent)
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(min(1.0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}
