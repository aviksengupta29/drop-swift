//
//  Discovery.swift
//  DropSwift
//
//  Finds DropSwift servers on the local network automatically via Bonjour,
//  so the user never has to type an IP address or port.
//

import Foundation
import Combine
import Network

/// One computer found on the network.
struct DiscoveredServer: Identifiable, Hashable {
    let id: String      // stable id (the Bonjour service name)
    let name: String    // friendly name, e.g. "DropSwift on Aviks-MacBook-Pro"
    let host: String    // resolved IP, e.g. "192.168.1.7"
    let port: Int
}

@MainActor
final class Discovery: ObservableObject {
    @Published var servers: [DiscoveredServer] = []
    @Published var isSearching = false

    private var browser: NWBrowser?
    private var resolvers: [NWConnection] = []

    /// Service type must match what the laptop server advertises.
    private let serviceType = "_dropswift._tcp"

    func start() {
        stop()
        isSearching = true

        // LAN-only: do not use peer-to-peer (AWDL/Wi-Fi Direct) links — discovery
        // and transfers must go over the shared local Wi-Fi network only.
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: params)
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.handle(results)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isSearching = true
                case .failed:
                    // Transient failure — drop this browser and rebuild shortly.
                    self.isSearching = false
                    try? await Task.sleep(for: .seconds(3))
                    if self.browser === browser { self.start() }
                case .cancelled:
                    self.isSearching = false
                default:
                    break
                }
            }
        }
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolvers.forEach { $0.cancel() }
        resolvers.removeAll()
        isSearching = false
    }

    /// Clears the current results and scans again from scratch.
    func refresh() {
        servers.removeAll()
        start()
    }

    // MARK: - Internal

    private func handle(_ results: Set<NWBrowser.Result>) {
        // Drop entries that disappeared.
        let liveNames = results.compactMap { result -> String? in
            if case let .service(name, _, _, _) = result.endpoint { return name }
            return nil
        }
        servers.removeAll { !liveNames.contains($0.id) }

        // Resolve any new ones to an IP + port.
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            if servers.contains(where: { $0.id == name }) { continue }
            resolve(endpoint: result.endpoint, name: name)
        }
    }

    private func resolve(endpoint: NWEndpoint, name: String) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        resolvers.append(connection)

        connection.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else {
                if case .failed = state { connection.cancel() }
                return
            }
            guard case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint else {
                connection.cancel(); return
            }
            let hostString = Self.string(from: host)
            Task { @MainActor in
                self?.add(DiscoveredServer(id: name, name: name,
                                           host: hostString, port: Int(port.rawValue)))
            }
            connection.cancel()
        }
        connection.start(queue: .main)
    }

    private func add(_ server: DiscoveredServer) {
        guard !server.host.isEmpty else { return }
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            servers[idx] = server
        } else {
            servers.append(server)
        }
    }

    /// Turns an NWEndpoint.Host into a plain string, preferring a clean IPv4
    /// address and stripping any "%en0" interface scope.
    nonisolated private static func string(from host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let addr):
            return "\(addr)".components(separatedBy: "%").first ?? "\(addr)"
        case .ipv6(let addr):
            return "\(addr)".components(separatedBy: "%").first ?? "\(addr)"
        case .name(let name, _):
            return name
        @unknown default:
            return ""
        }
    }
}
