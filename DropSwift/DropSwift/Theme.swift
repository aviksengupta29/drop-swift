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

/// Soft branded gradient backdrop. Light & airy in light mode, deep-tinted in
/// dark mode so foreground text stays readable.
struct BrandBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if scheme == .dark {
                LinearGradient(
                    colors: [Color(red: 0.07, green: 0.05, blue: 0.15),
                             Color(red: 0.10, green: 0.06, blue: 0.20)],
                    startPoint: .top, endPoint: .bottom)
            } else {
                LinearGradient(
                    colors: [Color(red: 0.95, green: 0.93, blue: 1.00),
                             Color(red: 0.99, green: 0.96, blue: 1.00),
                             Color(red: 0.91, green: 0.95, blue: 1.00)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            }

            // Soft brand-coloured glows for a subtle liquid feel.
            GeometryReader { geo in
                Circle()
                    .fill(Brand.violet.opacity(scheme == .dark ? 0.22 : 0.12))
                    .frame(width: 300, height: 300)
                    .blur(radius: 90)
                    .offset(x: -70, y: -50)
                Circle()
                    .fill(Brand.indigo.opacity(scheme == .dark ? 0.20 : 0.10))
                    .frame(width: 340, height: 340)
                    .blur(radius: 100)
                    .offset(x: geo.size.width - 180, y: geo.size.height - 240)
            }
        }
        .ignoresSafeArea()
    }
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
