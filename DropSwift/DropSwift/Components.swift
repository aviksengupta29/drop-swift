//
//  Components.swift
//  DropSwift
//
//  Reusable premium components: floating tab bar, empty state, section header,
//  and small building blocks shared across screens.
//

import SwiftUI

// MARK: - Tabs

enum AppTab: CaseIterable {
    case connect, browse, send

    var title: String {
        switch self {
        case .connect: return "Connect"
        case .browse:  return "Browse"
        case .send:    return "Send"
        }
    }
    var icon: String {
        switch self {
        case .connect: return "wifi"
        case .browse:  return "square.grid.2x2"
        case .send:    return "paperplane"
        }
    }
}

/// Floating, blurred pill tab bar. The active tab expands with a label and a
/// spring-driven gradient indicator.
struct FloatingTabBar: View {
    @Binding var selection: AppTab
    @Namespace private var ns
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
        .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.12), radius: 22, y: 10)
        .padding(.horizontal, Space.xl)
    }

    private func tabButton(_ tab: AppTab) -> some View {
        let active = selection == tab
        return Button {
            guard selection != tab else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.74)) { selection = tab }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: tab.icon)
                    .symbolVariant(active ? .fill : .none)
                    .font(.system(size: 18, weight: .semibold))
                    .symbolEffect(.bounce, value: active)
                if active {
                    Text(tab.title)
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(Color.secondary))
            .padding(.vertical, 12)
            .padding(.horizontal, active ? 20 : 16)
            .background {
                if active {
                    Capsule()
                        .fill(Theme.accentGradient)
                        .matchedGeometryEffect(id: "tab.indicator", in: ns)
                        .shadow(color: Theme.accent.opacity(0.4), radius: 10, y: 4)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tab-\(tab.title)")   // UI-test hook
    }
}

// MARK: - Empty state

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    @State private var appear = false

    var body: some View {
        VStack(spacing: Space.m) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.12)).frame(width: 116, height: 116)
                Image(systemName: icon)
                    .font(.system(size: 46, weight: .medium))
                    .foregroundStyle(Theme.accentGradient)
                    .symbolEffect(.pulse, options: .repeating)
            }
            .scaleEffect(appear ? 1 : 0.82)

            VStack(spacing: Space.xs) {
                Text(title).font(.title3.weight(.bold))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let actionTitle, let action {
                PrimaryButton(title: actionTitle, action: action)
                    .frame(maxWidth: 260)
                    .padding(.top, Space.s)
            }
        }
        .padding(Space.xl)
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 12)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.82)) { appear = true }
        }
    }
}

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var trailing: AnyView? = nil
    init(_ title: String) { self.title = title }
    init(_ title: String, @ViewBuilder trailing: () -> some View) {
        self.title = title
        self.trailing = AnyView(trailing())
    }
    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            trailing
        }
        .padding(.horizontal, Space.xs)
    }
}

// MARK: - Hero header (logo + title), shared element friendly

struct HeroHeader: View {
    var title: String
    var subtitle: String
    @State private var float = false

    var body: some View {
        VStack(spacing: Space.m) {
            Image("AppLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: Theme.accent.opacity(0.45), radius: 22, y: 12)
                .offset(y: float ? -5 : 5)
                .animation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true), value: float)

            VStack(spacing: Space.xs) {
                Text(title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { float = true }
    }
}
