//
//  DropSwiftServerApp.swift
//  Native macOS front-end for the DropSwift server.
//
//  A premium, Apple-grade UI (matching the iOS app): purple accent, gradient
//  highlights, floating cards and a hero access code. It runs the bundled
//  Python server (server.py) as a subprocess so the phone app keeps
//  auto-discovering this Mac over the local network.
//

import SwiftUI
import AppKit
import Darwin
import CoreImage.CIFilterBuiltins

// MARK: - Design system (matches the iOS app)

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

enum Theme {
    static let accent  = Color(hex: 0x6E4BFF)
    static let success = Color(hex: 0x30D158)
    static let warning = Color(hex: 0xFF9F0A)
    static let error   = Color(hex: 0xFF5247)
    static let green   = success      // back-compat
    static let red     = error

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [Color(hex: 0x835CFF), Color(hex: 0x6E4BFF)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Soft, layered backdrop with accent glows.
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            (scheme == .dark ? Color(hex: 0x0C0C10) : Color(hex: 0xF6F5FB))
            Circle().fill(Theme.accent)
                .frame(width: 440, height: 440).blur(radius: 165)
                .opacity(scheme == .dark ? 0.38 : 0.16)
                .offset(x: -150, y: -270)
            Circle().fill(Color(hex: 0x59C2FF))
                .frame(width: 360, height: 360).blur(radius: 185)
                .opacity(scheme == .dark ? 0.16 : 0.08)
                .offset(x: 170, y: 320)
        }
        .ignoresSafeArea()
    }
}

struct CardModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var padding: CGFloat
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(scheme == .dark ? Color(hex: 0x18181E) : Color.white,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.07 : 0.05), lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.08), radius: 18, x: 0, y: 10)
    }
}

extension View {
    func card(padding: CGFloat = 18, radius: CGFloat = 22) -> some View {
        modifier(CardModifier(padding: padding, radius: radius))
    }
}

struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Filled (gradient/colour) call-to-action button.
struct FillButton: View {
    let title: String
    var icon: String? = nil
    var fill: AnyShapeStyle
    var glow: Color = .clear
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: 14, weight: .semibold)) }
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity).frame(height: 46)
            .background(fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: glow.opacity(0.4), radius: 12, y: 5)
        }
        .buttonStyle(PressStyle())
    }
}

/// Tinted, low-emphasis button.
struct TintButton: View {
    let title: String
    var icon: String? = nil
    var tint: Color = Theme.accent
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: 14, weight: .semibold)) }
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity).frame(height: 46)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressStyle())
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

    // Live transfer status, fed by the server's stdout.
    @Published var receiving = false
    @Published var receivedCount = 0
    @Published var lastFile = ""

    private var process: Process?
    private var outPipe: Pipe?
    private var outBuffer = ""

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

    /// The data encoded in the pairing QR code — scanning it in the DropSwift
    /// iPhone app connects and authenticates without typing the access code.
    var pairingURL: String { "dropswift://pair?host=\(ip)&port=\(port)&code=\(code)" }

    /// Renders the pairing QR code as a template image — opaque ink, fully
    /// transparent background — so the view can tint it with the app's accent
    /// gradient instead of plain black. A computed property (not cached) is
    /// fine here: it's a tiny image, only re-drawn when ip/port/code change.
    var qrImage: NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(pairingURL.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))

        let recolor = CIFilter.falseColor()
        recolor.inputImage = scaled
        recolor.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)   // ink
        recolor.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)   // background
        guard let colored = recolor.outputImage else { return nil }

        let rep = NSCIImageRep(ciImage: colored)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
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

        // Read the server's stdout to surface live transfer status.
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = nil
        outPipe = pipe
        outBuffer = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // Empty data means EOF (the subprocess's stdout closed, e.g. it
            // exited). The pipe stays "readable" at EOF forever, so leaving
            // the handler attached spins the run loop at 100% CPU — detach it.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor in self?.ingest(data) }
        }

        do {
            try task.run()
            process = task
            isRunning = true
            preventSleep()
        } catch {
            isRunning = false
        }
    }

    func stop() {
        outPipe?.fileHandleForReading.readabilityHandler = nil
        outPipe = nil
        outBuffer = ""
        process?.terminate()
        process = nil
        killStray()
        isRunning = false
        receiving = false
        receivedCount = 0
        lastFile = ""
        allowSleep()
    }

    // MARK: Live status parsing

    private func ingest(_ data: Data) {
        outBuffer += String(decoding: data, as: UTF8.self)
        while let nl = outBuffer.firstIndex(of: "\n") {
            let line = String(outBuffer[outBuffer.startIndex..<nl])
            outBuffer.removeSubrange(outBuffer.startIndex...nl)
            parseStatus(line)
        }
    }

    private func parseStatus(_ line: String) {
        let prefix = "@@DROPSWIFT_STATUS@@ "
        guard line.hasPrefix(prefix) else { return }   // ignore ordinary log lines
        let json = String(line.dropFirst(prefix.count))
        guard let d = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        let active = obj["active"] as? Int ?? 0
        let received = obj["received"] as? Int ?? 0
        let name = obj["name"] as? String ?? ""
        receivedCount = received
        if !name.isEmpty { lastFile = name }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { receiving = active > 0 }
    }

    // Keep the Mac awake while the server runs, so long (overnight) transfers
    // don't drop when the system would otherwise idle-sleep.
    private var sleepActivity: NSObjectProtocol?

    private func preventSleep() {
        guard sleepActivity == nil else { return }
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "DropSwift server is running")
    }

    private func allowSleep() {
        if let sleepActivity {
            ProcessInfo.processInfo.endActivity(sleepActivity)
            self.sleepActivity = nil
        }
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

// MARK: - Main view

struct ServerView: View {
    @EnvironmentObject var server: ServerController
    @State private var float = false

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 18) {
                // Hero
                logo
                    .offset(y: float ? -4 : 4)
                    .animation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true), value: float)
                VStack(spacing: 3) {
                    Text("DropSwift Server")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("Share files over your local Wi‑Fi")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                MacStatusPill(running: server.isRunning)

                accessCard
                infoCard

                if server.receiving { transferCard }

                HStack(spacing: 12) {
                    TintButton(title: "Choose Folder", icon: "folder") { server.chooseFolder() }
                    if server.isRunning {
                        FillButton(title: "Stop", icon: "stop.fill",
                                   fill: AnyShapeStyle(Theme.error), glow: Theme.error) { server.stop() }
                    } else {
                        FillButton(title: "Start", icon: "play.fill",
                                   fill: AnyShapeStyle(Theme.accentGradient), glow: Theme.accent) { server.start() }
                    }
                }

                Text("Open DropSwift on your phone — it finds this Mac automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(28)
        }
        .frame(width: 440)
        .onAppear { float = true }
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
        .frame(width: 88, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Theme.accent.opacity(0.45), radius: 20, y: 12)
    }

    /// Hero access-code card — code and QR are both always visible, since
    /// either one authenticates the phone on first connect.
    private var accessCard: some View {
        VStack(spacing: 14) {
            VStack(spacing: 8) {
                Text("ACCESS CODE")
                    .font(.system(size: 11, weight: .semibold)).tracking(2)
                    .foregroundStyle(.secondary)
                Text(server.code)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .tracking(8)
                    .foregroundStyle(Theme.accentGradient)
            }

            if let qr = server.qrImage {
                Image(nsImage: qr)
                    .renderingMode(.template)
                    .interpolation(.none)
                    .resizable()
                    .foregroundStyle(Theme.accentGradient)
                    .frame(width: 168, height: 168)
                    .padding(14)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.18), lineWidth: 1))
            }

            Button { server.regenerateCode() } label: {
                Label("New code", systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(PressStyle())
            .foregroundStyle(Theme.accent)
            .help("Generate a new code")

            Text("Scan the QR or enter the code in the app the first time you connect")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .card(padding: 20)
    }

    private var infoCard: some View {
        VStack(spacing: 0) {
            infoRow("network", "IP Address", server.ip)
            divider
            infoRow("number.circle", "Port", String(server.port))
            divider
            infoRow("folder", "Saving to", server.folder.path)
        }
        .card(padding: 6)
    }

    /// Live "Receiving files…" status, shown while a transfer is in progress.
    private var transferCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.15)).frame(width: 44, height: 44)
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Receiving files…").font(.system(size: 14, weight: .semibold))
                Text(server.lastFile.isEmpty ? "From your phone" : server.lastFile)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(server.receivedCount)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.accentGradient).monospacedDigit()
                    .contentTransition(.numericText())
                Text("received").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .card(padding: 14)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var divider: some View { Divider().opacity(0.5).padding(.horizontal, 14) }

    private func infoRow(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.accent).frame(width: 20)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 210, alignment: .trailing)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// Status pill matching the iOS connected indicator. Steady when running, with a
/// gentle glowing dot; muted red when stopped.
struct MacStatusPill: View {
    let running: Bool
    @State private var pulse = false

    var body: some View {
        let color = running ? Theme.success : Theme.error
        return HStack(spacing: 9) {
            Circle().fill(color).frame(width: 9, height: 9)
                .shadow(color: color.opacity(0.9), radius: pulse ? 6 : 1)
            Text(running ? "Running" : "Stopped")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 1))
        .onAppear { update() }
        .onChange(of: running) { _, _ in update() }
    }

    private func update() {
        pulse = false
        if running {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
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
