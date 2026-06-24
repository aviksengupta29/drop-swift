//
//  Theme.swift
//  DropSwift
//
//  Brand colors and a reusable logo header for a consistent modern look.
//

import SwiftUI

enum Brand {
    static let indigo = Color(red: 0.36, green: 0.09, blue: 1.0)
    static let violet = Color(red: 0.69, green: 0.15, blue: 1.0)

    static let gradient = LinearGradient(
        colors: [indigo, violet],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// App logo + wordmark, used at the top of screens.
struct BrandHeader: View {
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image("AppLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 76, height: 76)
                .shadow(color: Brand.indigo.opacity(0.35), radius: 12, y: 5)

            Text("DropSwift")
                .font(.system(.title2, design: .rounded).weight(.bold))

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
