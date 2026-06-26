//
//  Glass.swift
//  DropSwift
//
//  Design system: colours, spacing (8pt grid), radii, materials, haptics and
//  reusable view styles. The premium, Apple-grade foundation for every screen.
//

import SwiftUI
import UIKit

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
    static let accent2 = Color(hex: 0x9B7BFF)
    static let success = Color(hex: 0x30D158)
    static let warning = Color(hex: 0xFF9F0A)
    static let error   = Color(hex: 0xFF5247)

    // Back-compat used by Media.swift
    static var green: Color { success }
    static var red: Color { error }

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [Color(hex: 0x835CFF), Color(hex: 0x6E4BFF)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// 8pt spacing grid.
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
}

enum Radius {
    static let card: CGFloat = 26
    static let inner: CGFloat = 18
    static let pill: CGFloat = 999
}

/// Haptic feedback helpers.
enum Haptics {
    static func light()  { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func soft()   { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func rigid()  { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

// MARK: - Background

/// Soft, layered app background with a subtle accent glow.
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            (scheme == .dark ? Color(hex: 0x0C0C10) : Color(hex: 0xF6F5FB))
            Circle()
                .fill(Theme.accent)
                .frame(width: 380, height: 380)
                .blur(radius: 170)
                .opacity(scheme == .dark ? 0.34 : 0.14)
                .offset(x: -120, y: -320)
            Circle()
                .fill(Color(hex: 0x59C2FF))
                .frame(width: 320, height: 320)
                .blur(radius: 180)
                .opacity(scheme == .dark ? 0.16 : 0.08)
                .offset(x: 150, y: 360)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Cards & buttons

struct AppCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var padding: CGFloat
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(scheme == .dark ? Color(hex: 0x18181E) : Color.white,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.07 : 0.04), lineWidth: 1)
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.07), radius: 20, x: 0, y: 12)
    }
}

extension View {
    func appCard(padding: CGFloat = Space.l, radius: CGFloat = Radius.card) -> some View {
        modifier(AppCardModifier(padding: padding, radius: radius))
    }

    /// Liquid Glass surface — used for the in-video playback controls.
    func glass<S: Shape>(_ shape: S) -> some View {
        glassEffect(.regular, in: shape)
    }
}

/// Scales + softens slightly while pressed (the "card lift" feel).
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

/// Primary gradient call-to-action button.
struct PrimaryButton: View {
    let title: String
    var icon: String? = nil
    var enabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            HStack(spacing: Space.s) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                }
                Text(title).font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                Theme.accentGradient.opacity(enabled ? 1 : 0.4),
                in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
            )
            .shadow(color: Theme.accent.opacity(enabled ? 0.35 : 0), radius: 16, y: 8)
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
    }
}

/// Secondary, tinted/glassy button.
struct SecondaryButton: View {
    let title: String
    var icon: String? = nil
    var tint: Color = Theme.accent
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            HStack(spacing: Space.s) {
                if let icon { Image(systemName: icon).font(.system(size: 15, weight: .semibold)) }
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }
}
