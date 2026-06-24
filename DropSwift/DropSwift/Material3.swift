//
//  Material3.swift
//  DropSwift
//
//  A small Material Design 3 component kit (color roles, shapes, buttons,
//  cards, top app bar, list items, progress) used to give the app a
//  consistent Material You look. The bottom tab bar stays native Liquid Glass.
//

import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// Material 3 baseline (purple) color scheme, resolved for light/dark.
struct M3 {
    let dark: Bool
    init(_ scheme: ColorScheme) { dark = scheme == .dark }

    private func c(_ light: UInt32, _ darkV: UInt32) -> Color { Color(hex: dark ? darkV : light) }

    var primary: Color            { c(0x6750A4, 0xD0BCFF) }
    var onPrimary: Color          { c(0xFFFFFF, 0x381E72) }
    var primaryContainer: Color   { c(0xEADDFF, 0x4F378B) }
    var onPrimaryContainer: Color { c(0x21005D, 0xEADDFF) }
    var secondaryContainer: Color { c(0xE8DEF8, 0x4A4458) }
    var onSecondaryContainer: Color { c(0x1D192B, 0xE8DEF8) }
    var tertiaryContainer: Color  { c(0xFFD8E4, 0x633B48) }
    var onTertiaryContainer: Color { c(0x31111D, 0xFFD8E4) }
    var error: Color              { c(0xB3261E, 0xF2B8B5) }
    var surface: Color            { c(0xFEF7FF, 0x141218) }
    var onSurface: Color          { c(0x1D1B20, 0xE6E0E9) }
    var onSurfaceVariant: Color   { c(0x49454F, 0xCAC4D0) }
    var surfaceContainerLow: Color { c(0xF7F2FA, 0x1D1B20) }
    var surfaceContainer: Color   { c(0xF3EDF7, 0x211F26) }
    var surfaceContainerHigh: Color { c(0xECE6F0, 0x2B2930) }
    var outline: Color            { c(0x79747E, 0x938F99) }
    var outlineVariant: Color     { c(0xCAC4D0, 0x49454F) }
}

private struct M3Key: EnvironmentKey {
    static let defaultValue = M3(.light)
}
extension EnvironmentValues {
    var m3: M3 {
        get { self[M3Key.self] }
        set { self[M3Key.self] = newValue }
    }
}

// MARK: - Scaffold + top app bar

/// Consistent page scaffold: Material surface + top app bar + scrolling content.
/// Used by all three tabs so they're symmetrical.
struct M3Scaffold<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    var showLogo: Bool = false
    var showBack: Bool = false
    var onBack: (() -> Void)? = nil
    var scrolls: Bool = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        let m3 = M3(scheme)
        ZStack(alignment: .top) {
            m3.surface.ignoresSafeArea()
            VStack(spacing: 0) {
                M3TopAppBar(title: title, showLogo: showLogo, showBack: showBack, onBack: onBack)
                if scrolls {
                    ScrollView {
                        content()
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                            .padding(.bottom, 130)   // clear the floating tab bar
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    content()
                }
            }
        }
        .environment(\.m3, m3)
    }
}

struct M3TopAppBar: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    var showLogo = false
    var showBack = false
    var onBack: (() -> Void)? = nil

    var body: some View {
        let m3 = M3(scheme)
        HStack(spacing: 10) {
            if showBack {
                Button { onBack?() } label: {
                    Image(systemName: "arrow.left")
                        .font(.title3)
                        .foregroundStyle(m3.onSurface)
                        .frame(width: 40, height: 40)
                }
            } else if showLogo {
                Image("AppLogo")
                    .resizable()
                    .frame(width: 32, height: 32)
            }
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(m3.onSurface)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 60)
        .padding(.horizontal, 14)
        .background(m3.surface)
    }
}

// MARK: - Buttons

struct M3FilledButton: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    var icon: String? = nil
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        let m3 = M3(scheme)
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) }
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .foregroundStyle(enabled ? m3.onPrimary : m3.onSurface.opacity(0.38))
            .background(enabled ? m3.primary : m3.onSurface.opacity(0.12), in: Capsule())
        }
        .disabled(!enabled)
    }
}

struct M3TonalButton: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    var icon: String? = nil
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        let m3 = M3(scheme)
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) }
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .foregroundStyle(enabled ? m3.onSecondaryContainer : m3.onSurface.opacity(0.38))
            .background(enabled ? m3.secondaryContainer : m3.onSurface.opacity(0.12), in: Capsule())
        }
        .disabled(!enabled)
    }
}

struct M3OutlinedButton: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    var icon: String? = nil
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        let m3 = M3(scheme)
        let tint = role == .destructive ? m3.error : m3.primary
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) }
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .foregroundStyle(tint)
            .overlay(Capsule().stroke(m3.outline, lineWidth: 1))
        }
    }
}

// MARK: - Card, section header, list item

struct M3Card<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        let m3 = M3(scheme)
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(m3.surfaceContainerHigh,
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct M3SectionHeader: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    var body: some View {
        let m3 = M3(scheme)
        Text(title.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(m3.onSurfaceVariant)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8)
            .padding(.top, 6)
    }
}

struct M3ListItem: View {
    @Environment(\.colorScheme) private var scheme
    let icon: String
    let headline: String
    var supporting: String? = nil
    var trailingSelected: Bool = false

    var body: some View {
        let m3 = M3(scheme)
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(m3.onPrimaryContainer)
                .frame(width: 42, height: 42)
                .background(m3.primaryContainer, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.system(size: 16, weight: .medium)).foregroundStyle(m3.onSurface)
                if let supporting {
                    Text(supporting).font(.system(size: 13)).foregroundStyle(m3.onSurfaceVariant)
                }
            }
            Spacer(minLength: 0)
            if trailingSelected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(m3.primary)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Linear progress

struct M3LinearProgress: View {
    @Environment(\.colorScheme) private var scheme
    let value: Double

    var body: some View {
        let m3 = M3(scheme)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(m3.primary.opacity(0.24))
                Capsule().fill(m3.primary)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: 6)
    }
}
