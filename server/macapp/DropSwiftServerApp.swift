//
//  DropSwiftServerApp.swift
//  Native macOS front-end for the DropSwift server.
//
//  Shows a Liquid-Glass UI with the logo, the Mac's IP/port, and a folder
//  picker. It runs the bundled Python server (server.py) as a subprocess so
//  the phone app keeps auto-discovering this Mac over the local network.
//

import SwiftUI
import AppKit
import Darwin

// MARK: - Liquid Glass theme (matches the iOS app)

enum Theme {
    static let accent = Color(red: 0.42, green: 0.28, blue: 1.0)
    static let green  = Color(red: 0.18, green: 0.80, blue: 0.42)
    static let red    = Color(red: 0.95, green: 0.27, blue: 0.32)
}

extension View {
    func glass<S: Shape>(_ shape: S) -> some View {
        glassEffect(.regular, in: shape)
    }
}

/// Minimal backdrop: window background + a soft accent glow.
struct GlassBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Circle()
                .fill(Theme.accent)
                .frame(width: 420, height: 420)
                .blur(radius: 140)
                .opacity(scheme == .dark ? 0.40 : 0.16)
                .offset(x: 130, y: -240)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Server controller

@MainActor
final class ServerController: ObservableObject {
    @Published var isRunning = false
    @Published var ip = "—"
    @Published var port = 8080
    @Published var folder: URL
    @Published var code: String

    private var process: Process?

    init() {
        let saved = UserDefaults.standard.url(forKey: "dropswift.folder")
        let def = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/DropSwift")
        self.folder = saved ?? def

        // A stable 6-digit access code, generated once and remembered.
        if let savedCode = UserDefaults.standard.string(forKey: "dropswift.code"),
           savedCode.count == 6 {
            self.code = savedCode
        } else {
            let c = String(format: "%06d", Int.random(in: 0...999_999))
            UserDefaults.standard.set(c, forKey: "dropswift.code")
            self.code = c
        }

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.ip = Self.localIPv4()
    }

    /// Generates a new access code (invalidates the old one on next start).
    func regenerateCode() {
        let c = String(format: "%06d", Int.random(in: 0...999_999))
        UserDefaults.standard.set(c, forKey: "dropswift.code")
        code = c
        if isRunning { start() }   // restart so the server uses the new code
    }

    func start() {
        stop()
        killStray()   // clear any server left over from a previous launch
        guard let py = Self.findPython(),
              let script = Bundle.main.url(forResource: "server", withExtension: "py") else {
            return
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: py)
        task.arguments = [script.path, "--dir", folder.path, "--port", String(port), "--code", code]
        task.standardOutput = nil
        task.standardError = nil
        do {
            try task.run()
            process = task
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        killStray()
        isRunning = false
    }

    /// Kills any DropSwift server / Bonjour advertiser left running, so we never
    /// leave an orphan holding the port.
    private func killStray() {
        for args in [["-f", "server.py --dir"], ["-f", "dns-sd -R"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            p.arguments = args
            try? p.run()
            p.waitUntilExit()
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder where files from your phone will be saved"
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
            UserDefaults.standard.set(url, forKey: "dropswift.folder")
            if isRunning { start() }   // restart with the new folder
        }
    }

    // Best non-loopback IPv4 address on Wi-Fi/Ethernet.
    static func localIPv4() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return address }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING) else { continue }
            guard ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" || name == "en1" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ptr.pointee.ifa_addr,
                        socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            address = String(cString: host)
        }
        return address
    }

    static func findPython() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3",
                          "/usr/local/bin/python3",
                          "\(home)/anaconda3/bin/python3", "/opt/anaconda3/bin/python3"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - Main view (Material 3 — matches the iOS app)

struct ServerView: View {
    @EnvironmentObject var server: ServerController

    var body: some View {
        ZStack {
            GlassBackground()

            VStack(spacing: 18) {
                logo
                Text("DropSwift Server")
                    .font(.system(size: 25, weight: .bold))
                Text("Sharing files over your local Wi‑Fi")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                MacStatusPill(running: server.isRunning)
                infoCard

                HStack(spacing: 12) {
                    Button(action: server.chooseFolder) {
                        Label("Choose Folder", systemImage: "folder")
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.glass)
                    .tint(Theme.accent)

                    Button { server.isRunning ? server.stop() : server.start() } label: {
                        Label(server.isRunning ? "Stop" : "Start",
                              systemImage: server.isRunning ? "stop.fill" : "play.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(server.isRunning ? Theme.red : Theme.accent)
                }

                Text("Open DropSwift on your phone — it finds this Mac automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }
            .padding(28)
        }
        .frame(width: 420, height: 600)
    }

    private var logo: some View {
        Group {
            if let url = Bundle.main.url(forResource: "AppLogo", withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable()
            } else {
                Image(systemName: "arrow.left.arrow.right.circle.fill").resizable()
            }
        }
        .frame(width: 92, height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Theme.accent.opacity(0.35), radius: 14, y: 6)
    }

    private var infoCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Access code").foregroundStyle(.secondary)
                Spacer()
                Text(server.code)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Theme.accent)
                Button { server.regenerateCode() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Generate a new code")
            }
            .font(.callout)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            Divider()
            row("IP Address", server.ip)
            Divider()
            row("Port", String(server.port))
            Divider()
            row("Saving to", server.folder.path)
        }
        .padding(.vertical, 6)
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .trailing)
        }
        .font(.callout)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }
}

/// Status pill (glass), isolated so its animation never re-renders the rest of
/// the UI. Steady green when running; flashing red glow when stopped.
struct MacStatusPill: View {
    let running: Bool
    @State private var pulse = false

    var body: some View {
        let color = running ? Theme.green : Theme.red
        return HStack(spacing: 9) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(running ? "Running" : "Stopped")
                .font(.system(size: 14, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .glass(Capsule())
        .overlay(Capsule().strokeBorder(color, lineWidth: 1.6))
        .shadow(color: running ? Theme.green.opacity(0.45) : Theme.red.opacity(pulse ? 0.9 : 0.2),
                radius: running ? 7 : (pulse ? 16 : 4))
        .onAppear { update() }
        .onChange(of: running) { _, _ in update() }
    }

    private func update() {
        if running {
            withAnimation(.easeInOut(duration: 0.3)) { pulse = false }
        } else {
            pulse = false
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct DropSwiftServerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var server = ServerController()

    var body: some Scene {
        Window("DropSwift Server", id: "main") {
            ServerView()
                .environmentObject(server)
                .onAppear { server.start() }
                .onDisappear { server.stop() }
        }
        .windowResizability(.contentSize)
    }
}
