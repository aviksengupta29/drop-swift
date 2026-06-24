//
//  Models.swift
//  DropSwift
//
//  Data types exchanged with the laptop server.
//

import Foundation

/// A file or folder living on the laptop, as returned by /api/list.
struct RemoteFile: Identifiable, Codable, Hashable {
    let name: String
    let isDir: Bool
    let size: Int

    var id: String { name }

    /// Human-readable size, e.g. "1.2 MB". Empty for folders.
    var displaySize: String {
        guard !isDir else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

/// The response from /api/list.
struct Listing: Codable {
    let path: String
    let items: [RemoteFile]
}

/// The response from /api/health.
struct Health: Codable {
    let status: String
    let name: String
}
