//
//  ContentView.swift
//  DropSwift
//
//  Root view: three tabs — Connect, Browse laptop, Send to laptop.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.colorScheme) private var scheme
    @StateObject private var server = ServerConnection()

    var body: some View {
        // Native Liquid Glass tab bar, tinted with the Material 3 primary.
        TabView {
            ConnectionView()
                .tabItem { Label("Connect", systemImage: "wifi") }

            BrowseView()
                .tabItem { Label("Browse", systemImage: "folder") }

            UploadView()
                .tabItem { Label("Send", systemImage: "square.and.arrow.up") }
        }
        .tint(M3(scheme).primary)
        .environmentObject(server)
    }
}

#Preview {
    ContentView()
}
