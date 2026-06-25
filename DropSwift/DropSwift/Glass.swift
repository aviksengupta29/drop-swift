//
//  Glass.swift
//  DropSwift
//
//  Minimal, modern Liquid Glass design system (Apple's glassEffect + glass
//  buttons). Replaces the old Material 3 kit.
//

import SwiftUI

enum Theme {
    static let accent = Color(red: 0.42, green: 0.28, blue: 1.0)   // indigo-violet
    static let green  = Color(red: 0.18, green: 0.80, blue: 0.42)
    static let red    = Color(red: 0.95, green: 0.27, blue: 0.32)
}

extension View {
    /// A Liquid Glass surface clipped to `shape`.
    func glass<S: Shape>(_ shape: S) -> some View {
        glassEffect(.regular, in: shape)
    }
}

/// Minimal backdrop: the system background plus two very soft accent glows so
/// the glass has something to refract. No animation, no clutter.
struct GlassBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color(.systemBackground)
            Circle()
                .fill(Theme.accent)
                .frame(width: 480, height: 480)
                .blur(radius: 150)
                .opacity(scheme == .dark ? 0.40 : 0.16)
                .offset(x: 150, y: -300)
            Circle()
                .fill(Theme.accent)
                .frame(width: 360, height: 360)
                .blur(radius: 160)
                .opacity(scheme == .dark ? 0.22 : 0.09)
                .offset(x: -160, y: 380)
        }
        .ignoresSafeArea()
    }
}

/// Page scaffold: glass backdrop + content (scrolling or vertically centered).
struct GlassScreen<Content: View>: View {
    var scrolls: Bool = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            GlassBackground()
            if scrolls {
                ScrollView {
                    content()
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                        .padding(.bottom, 130)   // clear the floating tab bar
                        .frame(maxWidth: .infinity)
                }
            } else {
                content().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// A full-width glass capsule that can carry a coloured (optionally pulsing)
/// glow — used for the status pill and the disconnect button.
struct GlowPill<Content: View>: View {
    var tint: Color? = nil
    var glow: Bool = false
    var pulse: Bool = false
    @ViewBuilder var content: () -> Content
    @State private var on = false

    var body: some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .glass(Capsule())
            .overlay(Capsule().strokeBorder(tint ?? .clear, lineWidth: tint == nil ? 0 : 1.5))
            .shadow(color: glow ? (tint ?? .clear).opacity(pulse ? (on ? 0.75 : 0.25) : 0.45) : .clear,
                    radius: glow ? (pulse ? (on ? 16 : 5) : 8) : 0)
            .onAppear { startPulse() }
            .onChange(of: pulse) { _, _ in startPulse() }
    }

    private func startPulse() {
        if pulse {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { on = true }
        } else {
            on = false
        }
    }
}
