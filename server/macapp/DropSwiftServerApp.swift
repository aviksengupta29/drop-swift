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

// MARK: - Material 3 theme (matches the iOS app)

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

struct M3 {
    let dark: Bool
    init(_ scheme: ColorScheme) { dark = scheme == .dark }
    private func c(_ l: UInt32, _ d: UInt32) -> Color { Color(hex: dark ? d : l) }

    var primary: Color { c(0x6750A4, 0xD0BCFF) }
    var onPrimary: Color { c(0xFFFFFF, 0x381E72) }
    var primaryContainer: Color { c(0xEADDFF, 0x4F378B) }
    var secondaryContainer: Color { c(0xE8DEF8, 0x4A4458) }
    var onSecondaryContainer: Color { c(0x1D192B, 0xE8DEF8) }
    var error: Color { c(0xB3261E, 0xF2B8B5) }
    var surface: Color { c(0xFEF7FF, 0x141218) }
    var onSurface: Color { c(0x1D1B20, 0xE6E0E9) }
    var onSurfaceVariant: Color { c(0x49454F, 0xCAC4D0) }
    var surfaceContainerHigh: Color { c(0xECE6F0, 0x2B2930) }
    var outlineVariant: Color { c(0xCAC4D0, 0x49454F) }
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
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject var server: ServerController

    var body: some View {
        let m3 = M3(scheme)
        ZStack {
            m3.surface.ignoresSafeArea()

            VStack(spacing: 18) {
                logo
                Text("DropSwift Server")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(m3.onSurface)
                Text("Sharing files over your local Wi‑Fi")
                    .font(.subheadline)
                    .foregroundStyle(m3.onSurfaceVariant)

                MacStatusPill(running: server.isRunning)
                infoCard(m3)

                HStack(spacing: 12) {
                    m3Button("Choose Folder", icon: "folder",
                             bg: m3.secondaryContainer, fg: m3.onSecondaryContainer,
                             action: server.chooseFolder)
                    m3Button(server.isRunning ? "Stop" : "Start",
                             icon: server.isRunning ? "stop.fill" : "play.fill",
                             bg: server.isRunning ? m3.error : m3.primary, fg: m3.onPrimary,
                             action: { server.isRunning ? server.stop() : server.start() })
                }

                Text("Open DropSwift on your phone — it finds this Mac automatically.")
                    .font(.caption)
                    .foregroundStyle(m3.onSurfaceVariant)
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
        .shadow(color: M3(scheme).primary.opacity(0.35), radius: 14, y: 6)
    }

    private func infoCard(_ m3: M3) -> some View {
        VStack(spacing: 0) {
            // Access code — emphasized.
            HStack {
                Text("Access code").foregroundStyle(m3.onSurfaceVariant)
                Spacer()
                Text(server.code)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(m3.primary)
                Button { server.regenerateCode() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(m3.onSurfaceVariant)
                .help("Generate a new code")
            }
            .font(.callout)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            Divider().overlay(m3.outlineVariant)
            row(m3, "IP Address", server.ip)
            Divider().overlay(m3.outlineVariant)
            row(m3, "Port", String(server.port))
            Divider().overlay(m3.outlineVariant)
            row(m3, "Saving to", server.folder.path)
        }
        .padding(.vertical, 6)
        .background(m3.surfaceContainerHigh,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func row(_ m3: M3, _ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(m3.onSurfaceVariant)
            Spacer()
            Text(value)
                .foregroundStyle(m3.onSurface)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .trailing)
        }
        .font(.callout)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private func m3Button(_ title: String, icon: String, bg: Color, fg: Color,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .foregroundStyle(fg)
            .background(bg, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Status pill, isolated so its animation never re-renders the rest of the UI.
/// Steady green when running; flashing red boundary glow when stopped.
struct MacStatusPill: View {
    @Environment(\.colorScheme) private var scheme
    let running: Bool
    @State private var pulse = false

    var body: some View {
        let m3 = M3(scheme)
        let green = Color(red: 0.18, green: 0.80, blue: 0.42)
        let red = Color(red: 0.95, green: 0.26, blue: 0.30)
        let color = running ? green : red

        return HStack(spacing: 9) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(running ? "Running" : "Stopped")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(m3.onSurface)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(Capsule().fill(m3.surfaceContainerHigh))
        .overlay(Capsule().strokeBorder(color, lineWidth: 1.8))
        .shadow(color: running ? green.opacity(0.45) : red.opacity(pulse ? 0.9 : 0.2),
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
