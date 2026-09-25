import SwiftUI

enum Theme {
    static let accent = Color(red: 0.42, green: 0.45, blue: 1.0)
    static let accentSecondary = Color(red: 0.24, green: 0.84, blue: 0.96)
    static let background = Color(red: 0.035, green: 0.04, blue: 0.07)
    static let surface = Color.white.opacity(0.07)
    static let surfaceStroke = Color.white.opacity(0.10)
    static let recording = Color(red: 1.0, green: 0.28, blue: 0.34)
    static let success = Color(red: 0.30, green: 0.85, blue: 0.55)
    static let warning = Color(red: 1.0, green: 0.74, blue: 0.30)

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accentSecondary], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var backdrop: LinearGradient {
        LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.13), background], startPoint: .top, endPoint: .bottom)
    }
}

/// Rounded translucent panel used for HUD elements and cards.
struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.surfaceStroke))
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 18) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius))
    }
}

/// Circular translucent icon button used on top of camera and 3D views.
struct CircleIconButton: View {
    let systemImage: String
    var isActive = false
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(isActive ? Color.black : Color.white)
                .frame(width: size, height: size)
                .background {
                    if isActive {
                        Circle().fill(Color.white)
                    } else {
                        Circle().fill(.ultraThinMaterial)
                    }
                }
                .overlay(Circle().strokeBorder(Theme.surfaceStroke))
        }
        .buttonStyle(.plain)
    }
}

/// Small capsule with an icon and a value, used for live capture stats.
struct StatPill: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.caption.weight(.semibold))
            Text(text).font(.caption.weight(.semibold)).monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.surfaceStroke))
    }
}

struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(Theme.accentGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: progress)
        }
    }
}
