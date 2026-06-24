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

// MARK: - Brand

enum Brand {
    static let indigo = Color(red: 0.36, green: 0.09, blue: 1.0)
    static let violet = Color(red: 0.69, green: 0.15, blue: 1.0)
    static let pink   = Color(red: 0.95, green: 0.35, blue: 0.95)
}

// MARK: - Liquid glass helper (Liquid Glass on macOS 26, material before that)

extension View {
    @ViewBuilder
    func liquidCard<S: Shape>(_ shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

// MARK: - Server controller

@MainActor
final class ServerController: ObservableObject {
    @Published var isRunning = false
    @Published var ip = "—"
    @Published var port = 8080
    @Published var folder: URL

    private var process: Process?

    init() {
        let saved = UserDefaults.standard.url(forKey: "dropswift.folder")
        let def = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/DropSwift")
        self.folder = saved ?? def
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.ip = Self.localIPv4()
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
        task.arguments = [script.path, "--dir", folder.path, "--port", String(port)]
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

// MARK: - Liquid background

struct LiquidBackground: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Brand.indigo, Brand.violet],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            blob(Brand.pink, 360).offset(x: animate ? -120 : -80, y: animate ? -160 : -120)
            blob(Brand.indigo, 420).offset(x: animate ? 150 : 110, y: animate ? 180 : 140)
            blob(.white.opacity(0.5), 240).offset(x: animate ? 120 : 80, y: animate ? -180 : -140)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }

    private func blob(_ color: Color, _ size: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .blur(radius: 70)
            .opacity(0.55)
    }
}

// MARK: - Main view

struct ServerView: View {
    @EnvironmentObject var server: ServerController

    var body: some View {
        ZStack {
            LiquidBackground()

            VStack(spacing: 18) {
                logo
                Text("DropSwift Server")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Sharing files over your local Wi‑Fi")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))

                infoCard

                HStack(spacing: 12) {
                    Button(action: server.chooseFolder) {
                        Label("Choose Folder", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .liquidCard(Capsule())

                    Button(action: { server.isRunning ? server.stop() : server.start() }) {
                        Label(server.isRunning ? "Stop" : "Start",
                              systemImage: server.isRunning ? "stop.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .background(server.isRunning ? Color.red.opacity(0.9) : Color.white.opacity(0.22),
                                in: Capsule())
                }
                .padding(.horizontal, 4)

                Text("Open DropSwift on your phone — it finds this Mac automatically.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }
            .padding(28)
        }
        .frame(width: 420, height: 580)
    }

    private var logo: some View {
        Group {
            if let url = Bundle.main.url(forResource: "AppLogo", withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable()
            } else {
                Image(systemName: "arrow.left.arrow.right.circle.fill").resizable()
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 92, height: 92)
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
    }

    private var infoCard: some View {
        VStack(spacing: 0) {
            statusRow
            Divider().overlay(.white.opacity(0.25))
            row("IP Address", server.ip)
            Divider().overlay(.white.opacity(0.25))
            row("Port", String(server.port))
            Divider().overlay(.white.opacity(0.25))
            row("Saving to", server.folder.path)
        }
        .padding(.vertical, 6)
        .liquidCard(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
    }

    private var statusRow: some View {
        HStack {
            Circle()
                .fill(server.isRunning ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
                .shadow(color: server.isRunning ? .green : .orange, radius: 5)
            Text(server.isRunning ? "Running" : "Stopped")
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            Text(value)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .trailing)
        }
        .font(.callout)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
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
