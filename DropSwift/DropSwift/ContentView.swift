//
//  ContentView.swift
//  DropSwift
//
//  Root view: three tabs — Connect, Browse laptop, Send to laptop.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var server = ServerConnection()

    var body: some View {
        // Native Liquid Glass tab bar, tinted with the brand accent.
        TabView {
            ConnectionView()
                .tabItem { Label("Connect", systemImage: "wifi") }

            BrowseView()
                .tabItem { Label("Browse", systemImage: "folder") }

            UploadView()
                .tabItem { Label("Send", systemImage: "square.and.arrow.up") }
        }
        .tint(Theme.accent)
        .environmentObject(server)
        .alert("Disconnected", isPresented: $server.didDisconnectUnexpectedly) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Lost connection to your computer. Make sure the DropSwift server is running and both devices are on the same Wi-Fi.")
        }
        .sheet(isPresented: $server.needsCode) {
            CodeEntryView().environmentObject(server)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await server.checkNow() }
            }
        }
    }
}

#Preview {
    ContentView()
}
