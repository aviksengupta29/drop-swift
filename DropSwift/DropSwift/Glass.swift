//
//  Glass.swift
//  DropSwift
//
//  Basic theme (accent colour) kept after moving to native iOS components.
//

import SwiftUI

enum Theme {
    static let accent = Color(red: 0.42, green: 0.28, blue: 1.0)   // indigo-violet
    static let green  = Color(red: 0.18, green: 0.80, blue: 0.42)
    static let red    = Color(red: 0.95, green: 0.27, blue: 0.32)
}

extension View {
    /// A Liquid Glass surface — used for the in-video playback controls.
    func glass<S: Shape>(_ shape: S) -> some View {
        glassEffect(.regular, in: shape)
    }
}
