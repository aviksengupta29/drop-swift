//
//  ContentView.swift
//  DropSwift
//
//  Root: layered background + screens + a custom floating tab bar.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var server = ServerConnection()
    @State private var tab: AppTab = .connect

    var body: some View {
        ZStack(alignment: .bottom) {
            AppBackground()

            // Keep all three alive (preserves state) and cross-fade between them.
            ZStack {
                screen(.connect) { ConnectionView() }
                screen(.browse)  { BrowseView(goToConnect: goToConnect) }
                screen(.send)    { UploadView(goToConnect: goToConnect) }
            }
            .animation(.smooth(duration: 0.32), value: tab)

            FloatingTabBar(selection: $tab)
        }
        .environmentObject(server)
        .tint(Theme.accent)
        .alert("Disconnected", isPresented: $server.didDisconnectUnexpectedly) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Lost connection to your computer. Make sure the DropSwift server is running and both devices are on the same Wi‑Fi.")
        }
        .sheet(isPresented: $server.needsCode) {
            CodeEntryView().environmentObject(server)
        }
        .onAppear { server.startDiscovery(); Haptics.warmUp() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                server.startDiscovery()   // re-arm browser after backgrounding / permission grant
                Task { await server.checkNow() }
            }
        }
        .onChange(of: tab) { _, _ in Haptics.rigid() }   // section switch — clearly felt
        .onChange(of: server.isConnected) { _, connected in
            if connected { Haptics.success() }
        }
        .onChange(of: server.didDisconnectUnexpectedly) { _, disconnected in
            if disconnected { Haptics.warning() }
        }
    }

    private func goToConnect() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.74)) { tab = .connect }
    }

    @ViewBuilder
    private func screen<Content: View>(_ which: AppTab, @ViewBuilder _ content: () -> Content) -> some View {
        let active = tab == which
        content()
            .opacity(active ? 1 : 0)
            .scaleEffect(active ? 1 : 0.98)
            .allowsHitTesting(active)
    }
}

#Preview {
    ContentView()
}
