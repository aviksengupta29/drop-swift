//
//  Discovery.swift
//  DropSwift
//
//  Finds DropSwift servers on the local network automatically via Bonjour,
//  so the user never has to type an IP address or port.
//
//  Uses NetServiceBrowser/NetService: it resolves a server's IP straight from
//  the mDNS address records, without opening a TCP connection to the server.
//  That makes discovery work reliably on real Wi-Fi networks (a firewall or a
//  flaky first connection can't hide a server that's actually advertising).
//

import Foundation
import Combine

/// One computer found on the network.
struct DiscoveredServer: Identifiable, Hashable {
    let id: String      // stable id (the Bonjour service name)
    let name: String    // friendly name, e.g. "DropSwift on Aviks-MacBook-Pro"
    let host: String    // resolved IP, e.g. "192.168.1.7"
    let port: Int
}

@MainActor
final class Discovery: NSObject, ObservableObject {
    @Published var servers: [DiscoveredServer] = []
    @Published var isSearching = false

    private var browser: NetServiceBrowser?
    private var resolving: [NetService] = []

    /// Service type must match what the laptop server advertises.
    private let serviceType = "_dropswift._tcp."

    func start() {
        stop()
        isSearching = true
        let b = NetServiceBrowser()
        b.includesPeerToPeer = false       // LAN-only: no AWDL / Wi-Fi Direct
        b.delegate = self
        b.searchForServices(ofType: serviceType, inDomain: "local.")
        browser = b
    }

    func stop() {
        browser?.stop()
        browser?.delegate = nil
        browser = nil
        for s in resolving { s.stop(); s.delegate = nil }
        resolving.removeAll()
        isSearching = false
    }

    /// Clears the current results and scans again from scratch.
    func refresh() {
        servers.removeAll()
        start()
    }

    fileprivate func add(_ server: DiscoveredServer) {
        guard !server.host.isEmpty else { return }
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            servers[idx] = server
        } else {
            servers.append(server)
        }
    }

    fileprivate func remove(named name: String) {
        servers.removeAll { $0.id == name }
    }

    /// Picks the most reachable address a service advertises. A Mac often has
    /// several interfaces (Wi-Fi, Ethernet, VPN, a disconnected port with a
    /// 169.254 self-assigned address), so we rank them: a real private-LAN IPv4
    /// beats other IPv4, which beats link-local (169.254), which beats IPv6.
    nonisolated fileprivate static func ip(from addresses: [Data]) -> String? {
        var best: (score: Int, ip: String)?
        for data in addresses {
            let parsed: (String, Bool)? = data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return nil }
                let sa = base.assumingMemoryBound(to: sockaddr.self)
                let family = sa.pointee.sa_family
                guard family == sa_family_t(AF_INET) || family == sa_family_t(AF_INET6) else { return nil }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(sa, socklen_t(data.count), &host, socklen_t(host.count),
                                  nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                let s = String(cString: host).components(separatedBy: "%").first ?? String(cString: host)
                return (s, family == sa_family_t(AF_INET))
            }
            guard let (s, isV4) = parsed, !s.isEmpty else { continue }
            let score = rank(ip: s, isV4: isV4)
            guard score > 0 else { continue }
            if best == nil || score > best!.score { best = (score, s) }
        }
        return best?.ip
    }

    nonisolated private static func rank(ip: String, isV4: Bool) -> Int {
        if isV4 {
            if ip.hasPrefix("127.") { return 0 }                 // loopback — skip
            if ip.hasPrefix("169.254.") { return 20 }            // self-assigned — last resort
            if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") { return 100 }
            if ip.hasPrefix("172.") {                            // 172.16–172.31 are private
                let octet = Int(ip.split(separator: ".").dropFirst().first ?? "") ?? 0
                if (16...31).contains(octet) { return 100 }
            }
            return 80                                            // other routable IPv4
        }
        if ip.hasPrefix("fe80") || ip == "::1" { return 0 }      // link-local / loopback IPv6 — skip
        return 40                                                // global IPv6
    }
}

extension Discovery: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser,
                                       didFind service: NetService, moreComing: Bool) {
        Task { @MainActor in
            service.delegate = self
            self.resolving.append(service)
            service.resolve(withTimeout: 6)
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser,
                                       didRemove service: NetService, moreComing: Bool) {
        let name = service.name
        Task { @MainActor in self.remove(named: name) }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let name = sender.name
        let port = sender.port
        guard let addresses = sender.addresses,
              let host = Discovery.ip(from: addresses), port > 0 else { return }
        Task { @MainActor in
            self.add(DiscoveredServer(id: name, name: name, host: host, port: port))
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        // Leave it for the next browse cycle; not fatal.
    }
}
