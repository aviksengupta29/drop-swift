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
import ImageIO
import CoreLocation
import CryptoKit
import Network

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

/// Host/port/code decoded from the QR code shown in the DropSwift Server app.
struct QRPairingPayload {
    let host: String
    let port: String
    let code: String

    /// Parses a scanned "dropswift://pair?host=...&port=...&code=..." string.
    /// Returns nil for anything else, so an unrelated QR code just fails quietly.
    static func parse(_ raw: String) -> QRPairingPayload? {
        guard let comps = URLComponents(string: raw),
              comps.scheme == "dropswift", comps.host == "pair",
              let items = comps.queryItems else { return nil }
        var values: [String: String] = [:]
        for item in items { values[item.name] = item.value }
        guard let host = values["host"], !host.isEmpty,
              let port = values["port"], Int(port) != nil,
              let code = values["code"], code.count == 6 else { return nil }
        return QRPairingPayload(host: host, port: port, code: code)
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

    /// Set true when the background heartbeat loses contact — drives the in-app
    /// "disconnected" popup.
    @Published var didDisconnectUnexpectedly = false

    /// Set true when the server needs the 6-digit access code — drives the
    /// code-entry sheet.
    @Published var needsCode = false

    /// True while a connect/auto-connect is in flight.
    @Published var isConnecting = false

    /// Bumped whenever the server switches which folder it shares — Browse
    /// observes this to auto-refresh (and pop back to the new root).
    @Published var browseReloadToken = 0

    /// Name of the folder the server is currently sharing (shown in Browse).
    @Published var folderName = ""
    private var folderSignature: String?

    /// Records the server's current shared-folder path. The first value seen is
    /// a baseline; any later change bumps `browseReloadToken` to refresh Browse.
    private func noteFolderSignature(_ sig: String?) {
        guard let sig, !sig.isEmpty else { return }
        folderName = (sig as NSString).lastPathComponent
        if let existing = folderSignature {
            if existing != sig {
                folderSignature = sig
                browseReloadToken += 1
            }
        } else {
            folderSignature = sig
        }
    }

    /// True when the phone has no Wi‑Fi (Wi‑Fi off, or only cellular) — DropSwift
    /// needs local Wi‑Fi, so the Connect screen shows a "Turn on Wi‑Fi" prompt
    /// instead of an endless "searching…". Defaults false so we never flash the
    /// prompt before the first real reading.
    @Published var wifiOff = false
    private let netMonitor = NWPathMonitor()
    private let netMonitorQueue = DispatchQueue(label: "dropswift.netmonitor")

    /// Watches connectivity so we can tell the user when Wi‑Fi is off. Local
    /// sharing works over Wi‑Fi (or a wired/adapter LAN); cellular-only or no
    /// network means we can't reach the computer.
    private func startNetworkMonitor() {
        netMonitor.pathUpdateHandler = { [weak self] path in
            let hasLAN = path.status == .satisfied &&
                (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            Task { @MainActor in
                guard let self else { return }
                let cameBack = self.wifiOff && hasLAN
                self.wifiOff = !hasLAN
                // Wi‑Fi just returned — re-arm discovery so the computer shows up
                // promptly instead of waiting for the next periodic refresh.
                if cameBack { self.startDiscovery(); self.refreshDiscovery() }
            }
        }
        netMonitor.start(queue: netMonitorQueue)
    }

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

    /// Which way an active transfer is going. Send (phone → Mac) and Restore
    /// (Mac → phone) share the SAME progress state + Dynamic Island machinery;
    /// the direction just selects the wording and which screen shows the card.
    enum TransferDirection { case send, receive }

    // Transfer progress (observed by the UI for the progress bar). Shared by
    // both Send and Restore — only one transfer runs at a time.
    @Published var transferDirection: TransferDirection = .send
    @Published var isTransferring = false
    @Published var transferTotal = 0
    @Published var transferCompleted = 0
    @Published var transferFailed = 0
    @Published var transferCurrentName = ""
    @Published var activeFractions: [Int: Double] = [:]   // in-flight per-file progress
    @Published var transferResult: String?
    @Published var transferSpeed: Double = 0      // bytes/sec (UI + Live Activity)
    @Published var transferETADate: Date?         // projected completion time
    @Published var failedItems: [PhotosPickerItem] = []   // items left to retry (Send only)

    /// Concurrent network uploads (also the background session's
    /// max-connections-per-host).
    static let maxParallelUploads = 4

    /// How many uploads are kept OUTSTANDING (exported + handed to the system
    /// background daemon) at once. A deep queue is what lets a transfer keep
    /// draining while the app is suspended / the phone is locked — the daemon
    /// works through it without needing the app to wake between files.
    static let uploadQueueDepth = 16

    /// Concurrent photo-library exports (bounds CPU + temp-disk churn while the
    /// queue above stays deep with already-exported, uploading files).
    static let maxExportConcurrency = 3

    /// Cap on total temp bytes for outstanding uploads, so a deep queue of large
    /// videos can't exhaust disk (photos hit the count limit first; big videos
    /// hit this first).
    static let maxOutstandingBytes: Int64 = 1_500_000_000

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

        startNetworkMonitor()
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
            noteFolderSignature(health.root)

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

    /// Connects using host/port/code decoded from the QR code shown in the
    /// DropSwift Server app — skips the manual 6-digit entry entirely.
    func connectFromQR(_ payload: QRPairingPayload) async {
        suppressAutoConnect = false
        host = payload.host
        port = payload.port
        currentKey = "host:\(payload.host):\(payload.port)"
        connectedServerId = nil
        lastError = nil
        didDisconnectUnexpectedly = false
        needsCode = false
        isConnecting = true
        defer { isConnecting = false }
        do {
            let (data, response) = try await session.data(from: try url("/api/health"))
            try Self.check(response)
            let health = try JSONDecoder().decode(Health.self, from: data)
            serverName = health.name
            noteFolderSignature(health.root)
        } catch {
            isConnected = false
            serverName = ""
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        if await authenticate(code: payload.code) {
            isConnected = true
            startHeartbeat()
        } else {
            lastError = "This QR code is no longer valid. Try scanning again."
            needsCode = true
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
                        // A restart usually means the shared folder changed —
                        // ping once now to pick up the new one and refresh Browse.
                        _ = await self.pingStatus()
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
            let (data, response) = try await pingSession.data(for: req)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 { return .unauthorized }
                guard (200..<300).contains(http.statusCode) else { return .fail }
            }
            // Notice a shared-folder switch on the server and refresh Browse.
            if let ping = try? JSONDecoder().decode(PingResponse.self, from: data) {
                noteFolderSignature(ping.root)
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

    // MARK: - Restore to library (Browse → Save to Photos)

    /// Downloads the given server files and re-imports them into the iPhone
    /// Photo library, restoring each item's ORIGINAL capture date + location
    /// (read from its embedded EXIF/QuickTime metadata) so it lands in the
    /// correct place in the timeline — not "today". Serial, low-memory
    /// (streams each file to disk), and honors cancellation.
    func savePhotos(_ items: [SelectedMedia]) async {
        guard !items.isEmpty else { return }

        // Creating assets needs read-write (or add-only) access to the library.
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard auth == .authorized || auth == .limited else {
            transferDirection = .receive
            transferResult = "Allow Photos access in Settings to save items back."
            return
        }

        // Drive the SAME progress state + Dynamic Island as Send, tagged as an
        // incoming (Mac → iPhone) transfer.
        transferDirection = .receive
        isTransferring = true
        transferTotal = items.count
        transferCompleted = 0
        transferFailed = 0
        transferCurrentName = ""
        activeFractions = [:]
        transferResult = nil
        resetTransferMetrics()

        UIApplication.shared.isIdleTimerDisabled = true
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "DropSwiftRestore") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }

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
            isTransferring = false
            activeFractions = [:]
        }

        for (index, item) in items.enumerated() {
            if Task.isCancelled { break }
            transferCurrentName = item.name
            activeFractions[index] = 0
            let ok = await saveOne(item, index: index)
            activeFractions[index] = nil
            if ok { transferCompleted += 1 } else { transferFailed += 1 }
        }

        if Task.isCancelled {
            transferResult = "Stopped. Saved \(transferCompleted) of \(transferTotal)."
        } else if transferFailed == 0 {
            transferResult = "Saved \(transferCompleted) item\(transferCompleted == 1 ? "" : "s") to your library."
        } else {
            transferResult = "Saved \(transferCompleted), failed \(transferFailed)."
        }
    }

    /// Downloads one file to disk and imports it into the library with its
    /// original date/location restored. Returns true on success.
    private func saveOne(_ item: SelectedMedia, index: Int) async -> Bool {
        let localURL: URL
        do {
            localURL = try await downloadToTemp(path: item.path, name: item.name, index: index)
        } catch {
            return false
        }
        defer { try? FileManager.default.removeItem(at: localURL) }

        let kind = MediaKind.of(item.name)
        let (date, location) = await Self.captureInfo(url: localURL, kind: kind)

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = item.name
                request.addResource(with: kind == .video ? .video : .photo,
                                    fileURL: localURL, options: options)
                // Explicitly restore capture date/location so the asset sorts to
                // the right spot even when PhotoKit wouldn't infer them.
                if let date { request.creationDate = date }
                if let location { request.location = location }
            } completionHandler: { success, _ in
                cont.resume(returning: success)
            }
        }
    }

    /// Streams a server file straight to a temp file on disk (constant memory,
    /// safe for multi-gigabyte videos), keeping its original filename, and
    /// reports byte progress into the shared transfer metrics (speed/ETA/ring).
    private func downloadToTemp(path: String, name: String, index: Int) async throws -> URL {
        let delegate = DownloadProgressDelegate(onProgress: { [weak self] fraction in
            Task { @MainActor in self?.activeFractions[index] = fraction }
        }, onBytes: { [weak self] delta in
            Task { @MainActor in self?.bytesSent += delta }
        })
        let (tempURL, response) = try await session.download(
            for: try authed("/api/download", query: ["path": path]), delegate: delegate)
        try Self.check(response)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    // MARK: - Embedded capture metadata (date + location)

    /// Reads the original capture date and GPS location embedded in a media
    /// file, so a restored item can be placed back on the correct timeline.
    nonisolated private static func captureInfo(url: URL, kind: MediaKind) async -> (Date?, CLLocation?) {
        switch kind {
        case .video: return await videoCaptureInfo(url: url)
        default:     return imageCaptureInfo(url: url)
        }
    }

    /// EXIF stores dates as "yyyy:MM:dd HH:mm:ss" with no zone — interpret in
    /// the current time zone (what the Photos app does for such files).
    nonisolated private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    nonisolated private static func imageCaptureInfo(url: URL) -> (Date?, CLLocation?) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return (nil, nil) }

        var date: Date?
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                date = exifDateFormatter.date(from: s)
            } else if let s = exif[kCGImagePropertyExifDateTimeDigitized] as? String {
                date = exifDateFormatter.date(from: s)
            }
        }
        if date == nil, let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let s = tiff[kCGImagePropertyTIFFDateTime] as? String {
            date = exifDateFormatter.date(from: s)
        }

        var location: CLLocation?
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
           let lon = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue {
            let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
            let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
            location = CLLocation(latitude: latRef == "S" ? -lat : lat,
                                  longitude: lonRef == "W" ? -lon : lon)
        }
        return (date, location)
    }

    nonisolated private static func videoCaptureInfo(url: URL) async -> (Date?, CLLocation?) {
        let asset = AVURLAsset(url: url)
        var date: Date?
        var location: CLLocation?

        if let creationItem = try? await asset.load(.creationDate) {
            if let d = try? await creationItem.load(.dateValue) {
                date = d
            } else if let s = try? await creationItem.load(.stringValue) {
                date = isoDate(s)
            }
        }

        if let metadata = try? await asset.load(.metadata) {
            for item in metadata {
                guard let key = item.commonKey else { continue }
                if key == .commonKeyCreationDate, date == nil {
                    if let d = try? await item.load(.dateValue) { date = d }
                    else if let s = try? await item.load(.stringValue) { date = isoDate(s) }
                }
                if key == .commonKeyLocation, location == nil,
                   let s = try? await item.load(.stringValue) {
                    location = iso6709Location(s)
                }
            }
        }
        return (date, location)
    }

    nonisolated private static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Parses an ISO 6709 location string (e.g. "+27.5916+086.5640+8850.000/")
    /// — signed latitude then signed longitude — into a location.
    nonisolated private static func iso6709Location(_ s: String) -> CLLocation? {
        let scanner = Scanner(string: s)
        guard let lat = scanner.scanDouble(), let lon = scanner.scanDouble() else { return nil }
        return CLLocation(latitude: lat, longitude: lon)
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
        // Clear any lingering "completed" card from a previous transfer so they
        // don't pile up on the Lock Screen.
        for activity in Activity<TransferActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        let attributes = TransferActivityAttributes(serverName: serverName)
        let state = TransferActivityAttributes.ContentState(
            completed: 0, total: total, fraction: 0, currentName: "", done: false,
            incoming: transferDirection == .receive)
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
            speed: max(0, smoothedSpeed), etaDate: etaDate,
            incoming: transferDirection == .receive)
        Task { await liveActivity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    private func endLiveActivity() {
        guard let liveActivity else { return }
        let state = TransferActivityAttributes.ContentState(
            completed: transferCompleted, total: transferTotal,
            fraction: 1, currentName: "", done: true, speed: 0, etaDate: nil,
            incoming: transferDirection == .receive)
        let finished = liveActivity
        self.liveActivity = nil
        Task {
            // Keep the completed card on the Lock Screen / Dynamic Island (with
            // the "done" checkmark UI) instead of dropping it after a few
            // seconds. `.default` leaves it up until the user dismisses it (or
            // the system's ~4-hour max), and it survives even if the app closes.
            await finished.end(ActivityContent(state: state, staleDate: nil),
                               dismissalPolicy: .default)
        }
    }

    /// Sends an UNLIMITED number of photos/videos to the laptop, STREAMING each
    /// from disk (constant low memory — handles 1 TB+), keeping the original
    /// filename + metadata. Uploads several in parallel as a queue that refills,
    /// retries transient failures, and honors cancellation.
    func sendPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        transferDirection = .send
        isTransferring = true
        transferTotal = items.count
        transferCompleted = 0
        transferFailed = 0
        activeFractions = [:]
        transferResult = nil
        failedItems = []
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
        transferFailed = failures
        isTransferring = false
        activeFractions = [:]
        failedItems = pending.map { $0.1 }   // remember what didn't send, for Retry
        if Task.isCancelled {
            transferResult = "Stopped. Sent \(transferCompleted) of \(transferTotal)."
        } else {
            transferResult = failures == 0
                ? "Sent \(transferCompleted) item(s) to \(serverName)."
                : "Sent \(transferCompleted), failed \(failures)."
        }
    }

    /// Uploads a batch of (index, item), keeping up to `uploadQueueDepth` uploads
    /// outstanding (handed to the background daemon) so the transfer keeps
    /// draining while suspended. Bounded by disk budget + export concurrency so
    /// memory/disk stay in check no matter how many thousands are selected.
    /// Returns the items that failed so a later pass can retry them.
    private func runUploadPass(_ batch: [(Int, PhotosPickerItem)], stamp: Int) async -> [(Int, PhotosPickerItem)] {
        var failed: [(Int, PhotosPickerItem)] = []
        let gate = UploadGate(maxCount: Self.uploadQueueDepth, maxBytes: Self.maxOutstandingBytes)
        let exportSem = AsyncSemaphore(Self.maxExportConcurrency)
        var produced = Set<Int>()

        await withTaskGroup(of: (Int, PhotosPickerItem, Bool).self) { group in
            // Producer: keep the queue full, throttled by the gate (depth + disk).
            for (idx, item) in batch {
                if Task.isCancelled { break }
                await gate.reserve()
                if Task.isCancelled { await gate.release(0); break }
                produced.insert(idx)
                group.addTask { [weak self] in
                    let ok = await self?.uploadOne(item, index: idx, stamp: stamp,
                                                   gate: gate, exportSem: exportSem) ?? false
                    return (idx, item, ok)
                }
            }
            for await (idx, item, ok) in group {
                if !ok { failed.append((idx, item)) }
            }
        }
        // Items never started (e.g. after a cancel) are still pending.
        for (idx, item) in batch where !produced.contains(idx) { failed.append((idx, item)) }
        return failed
    }

    /// Exports one item to a temp file, then stream-uploads it (on the background
    /// session) with retries. Holds one `gate` slot for its whole lifetime so the
    /// producer keeps the queue at the right depth; limits concurrent exports via
    /// `exportSem`. Returns true on success.
    private func uploadOne(_ item: PhotosPickerItem, index: Int, stamp: Int,
                           gate: UploadGate, exportSem: AsyncSemaphore) async -> Bool {
        if Task.isCancelled { await gate.release(0); return false }
        activeFractions[index] = 0

        // 1) Export to a temp file (bounded concurrency).
        await exportSem.acquire()
        let exported = Task.isCancelled ? nil : await exportItem(item, index: index, stamp: stamp)
        await exportSem.release()

        guard let (fileURL, name) = exported else {
            activeFractions[index] = nil
            await gate.release(0)
            return false
        }
        let size = Self.fileSize(fileURL)
        await gate.account(size)
        transferCurrentName = name

        // 2) Upload with retries (continues in the background while suspended).
        let ok = await uploadWithRetries(at: fileURL, name: name, index: index)

        try? FileManager.default.removeItem(at: fileURL)
        activeFractions[index] = nil
        await gate.release(size)
        return ok
    }

    /// Exports a picked item's original resource (or the picker's transferable as
    /// a fallback) to a temp file. Returns (URL, filename), or nil to fail it.
    private func exportItem(_ item: PhotosPickerItem, index: Int, stamp: Int) async -> (URL, String)? {
        do {
            if let original = try await Self.writeOriginalToTemp(for: item) { return original }
        } catch {
            // Export stalled (e.g. an iCloud item that won't download) or was
            // cancelled — fail this file so the queue keeps moving; retry later.
            return nil
        }
        // No backing photo-library asset — fall back to the picker's transferable.
        guard let data = try? await item.loadTransferable(type: Data.self), !Task.isCancelled else { return nil }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "dat"
        let name = "DropSwift_\(stamp)_\(index).\(ext)"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + name)
        guard (try? data.write(to: tmp)) != nil else { return nil }
        return (tmp, name)
    }

    /// Stream-uploads an already-exported temp file, verifying integrity via a
    /// SHA-256 the server checks, retrying transient failures. Returns success.
    private func uploadWithRetries(at fileURL: URL, name: String, index: Int) async -> Bool {
        // Fingerprint the exact bytes we're about to send so the server can
        // verify it received them intact (catches truncation/corruption).
        let sha = await Task.detached(priority: .utility) {
            Self.sha256Hex(ofFileAt: fileURL)
        }.value

        var attempt = 0
        while attempt < 3 && !Task.isCancelled {
            do {
                try await uploadFile(at: fileURL, filename: name, index: index, sha256: sha)
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
        return false
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = attrs[.size] as? NSNumber else { return 0 }
        return n.int64Value
    }

    /// Writes a picked item's ORIGINAL resource to a temp file on disk, streaming
    /// (low memory). Returns the temp URL + the original filename.
    /// Returns nil if the item has no backing photo-library asset (caller falls
    /// back to the picker's transferable). THROWS if the export stalls (e.g. an
    /// iCloud item that won't download) or is cancelled — so one stuck file can
    /// never freeze the whole queue, and Cancel always works.
    nonisolated private static func writeOriginalToTemp(for item: PhotosPickerItem,
                                                        stallSeconds: TimeInterval = 45) async throws -> (URL, String)? {
        guard let id = item.itemIdentifier,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            return nil
        }
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: PHAssetResourceType = asset.mediaType == .video ? .video : .photo
        guard let resource = resources.first(where: { $0.type == preferred }) ?? resources.first else {
            return nil
        }

        let name = resource.originalFilename
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + name)
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: tempURL) else {
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true   // allow fetching from iCloud

        let manager = PHAssetResourceManager.default()
        let state = ExportState()

        // Watchdog: if no bytes arrive for `stallSeconds`, abandon this file so the
        // queue keeps moving (it's retried later). Lets big-but-progressing
        // downloads continue, while breaking true hangs.
        let watchdog = Task.detached {
            while true {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled || state.isResumed { break }
                if state.secondsSinceProgress() > stallSeconds {
                    manager.cancelDataRequest(state.requestID)
                    state.resume(.failure(StallError()))
                    break
                }
            }
        }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    state.attach(cont)
                    let rid = manager.requestData(for: resource, options: options,
                        dataReceivedHandler: { chunk in
                            do {
                                try handle.write(contentsOf: chunk)
                            } catch {
                                // A dropped write would produce a truncated file
                                // that still "looks" complete — fail instead so
                                // this item is retried, never silently corrupted.
                                manager.cancelDataRequest(state.requestID)
                                state.resume(.failure(error))
                                return
                            }
                            state.touch()
                        },
                        completionHandler: { error in
                            if let error { state.resume(.failure(error)) } else { state.resume(.success(())) }
                        })
                    state.requestID = rid
                    if Task.isCancelled {
                        manager.cancelDataRequest(rid)
                        state.resume(.failure(CancellationError()))
                    }
                }
            } onCancel: {
                manager.cancelDataRequest(state.requestID)
                state.resume(.failure(CancellationError()))
            }
            watchdog.cancel()
            try? handle.close()
            return (tempURL, name)
        } catch {
            watchdog.cancel()
            try? handle.close()
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    /// Streams a file from disk to the laptop (constant low memory), reporting
    /// per-file progress into `activeFractions[index]`. Sends the content
    /// SHA-256 (when known) so the server can reject a corrupted transfer.
    func uploadFile(at fileURL: URL, filename: String, index: Int,
                    toPath: String = "", sha256: String? = nil) async throws {
        var request = try authed("/api/upload", query: ["path": toPath])
        request.httpMethod = "POST"
        request.setValue(filename, forHTTPHeaderField: "X-Filename")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let sha256 { request.setValue(sha256, forHTTPHeaderField: "X-Content-SHA256") }

        // Upload on the BACKGROUND session so the transfer continues while the
        // app is suspended or the phone is locked (the system daemon keeps going
        // and wakes us to advance the queue).
        let (_, response) = try await BackgroundUploader.shared.upload(
            request, fromFile: fileURL,
            onProgress: { [weak self] fraction in
                Task { @MainActor in self?.activeFractions[index] = fraction }
            },
            onBytes: { [weak self] delta in
                Task { @MainActor in self?.bytesSent += delta }
            })
        try Self.check(response)
    }

    /// Streaming SHA-256 of a file's bytes (constant memory, safe for huge
    /// videos). Returns the lowercase hex digest, or nil if it can't be read.
    nonisolated static func sha256Hex(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            guard let chunk = try? handle.read(upToCount: 1024 * 1024),
                  !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
private struct StallError: Error {}

/// Thread-safe coordinator for a cancellable, stall-protected PhotoKit export.
/// Guarantees the continuation is resumed exactly once (by whichever of the
/// completion handler, the cancellation handler, or the watchdog fires first).
private final class ExportState: @unchecked Sendable {
    private let lock = NSLock()
    private var _requestID: PHAssetResourceDataRequestID = 0
    private var _lastProgress = Date()
    private var _resumed = false
    private var _cont: CheckedContinuation<Void, Error>?

    var requestID: PHAssetResourceDataRequestID {
        get { lock.lock(); defer { lock.unlock() }; return _requestID }
        set { lock.lock(); _requestID = newValue; lock.unlock() }
    }
    var isResumed: Bool { lock.lock(); defer { lock.unlock() }; return _resumed }

    func attach(_ cont: CheckedContinuation<Void, Error>) { lock.lock(); _cont = cont; lock.unlock() }
    func touch() { lock.lock(); _lastProgress = Date(); lock.unlock() }
    func secondsSinceProgress() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(_lastProgress)
    }
    func resume(_ result: Result<Void, Error>) {
        lock.lock()
        if _resumed { lock.unlock(); return }
        _resumed = true
        let c = _cont; _cont = nil
        lock.unlock()
        switch result {
        case .success: c?.resume()
        case .failure(let e): c?.resume(throwing: e)
        }
    }
}

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

/// Reports download byte-progress for the restore (Save to Photos) flow, feeding
/// the same speed/ETA/ring metrics the upload path uses.
final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private let onBytes: @Sendable (Int64) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void,
         onBytes: @escaping @Sendable (Int64) -> Void = { _ in }) {
        self.onProgress = onProgress
        self.onBytes = onBytes
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onBytes(bytesWritten)
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(min(1.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    // The async `download(for:delegate:)` returns the file URL itself, so this
    // required callback isn't used for delivery — but must exist.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}

/// Throttles how many uploads are OUTSTANDING at once — by count (queue depth)
/// AND by total temp bytes on disk. Keeping the queue deep is what lets the
/// background daemon keep uploading while the app is suspended; the byte cap
/// stops a deep queue of large videos from filling up storage.
actor UploadGate {
    private let maxCount: Int
    private let maxBytes: Int64
    private var count = 0
    private var bytes: Int64 = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxCount: Int, maxBytes: Int64) {
        self.maxCount = maxCount
        self.maxBytes = maxBytes
    }

    /// Blocks until there's room, then claims one slot.
    func reserve() async {
        while count >= maxCount || bytes >= maxBytes {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in waiters.append(c) }
        }
        count += 1
    }

    /// Records the exported size against the disk budget (after a slot is held).
    func account(_ n: Int64) { bytes += n }

    /// Frees a slot (and its bytes) and wakes any producers waiting for room.
    func release(_ n: Int64) {
        count = max(0, count - 1)
        bytes = max(0, bytes - n)
        let woken = waiters
        waiters.removeAll()
        for c in woken { c.resume() }
    }
}

/// Minimal async semaphore bounding concurrent photo-library exports.
actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ permits: Int) { self.permits = permits }

    func acquire() async {
        if permits > 0 { permits -= 1; return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in waiters.append(c) }
    }

    func release() {
        if waiters.isEmpty { permits += 1 }
        else { waiters.removeFirst().resume() }
    }
}
