//
//  ContentView.swift
//  DropSwift
//
//  Root view: three tabs — Connect, Browse laptop, Send to laptop.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var server = ServerConnection()

    var body: some View {
        TabView {
            ConnectionView()
                .tabItem { Label("Connect", systemImage: "wifi") }

            BrowseView()
                .tabItem { Label("Browse", systemImage: "folder") }

            UploadView()
                .tabItem { Label("Send", systemImage: "square.and.arrow.up") }
        }
        .environmentObject(server)
    }
}

#Preview {
    ContentView()
}
