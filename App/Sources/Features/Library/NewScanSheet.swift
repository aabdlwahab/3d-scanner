import SwiftUI

struct NewScanSheet: View {
    let onSelect: (ScanKind) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showTips = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(ScanKind.allCases) { kind in
                        Button {
                            Haptics.tap()
                            onSelect(kind)
                        } label: {
                            ModeCard(kind: kind)
                        }
                        .buttonStyle(.plain)
                        .disabled(!LiDARSessionController.isSupported)
                    }
                    Button {
                        showTips = true
                    } label: {
                        Label("Tips for a great scan", systemImage: "lightbulb")
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.top, 6)
                }
                .padding(16)
            }
            .navigationTitle("New Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $showTips) { ScanTipsView() }
        }
        .presentationDetents([.height(430), .large])
        .presentationDragIndicator(.visible)
    }
}

private struct ModeCard: View {
    let kind: ScanKind

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(kind.title).font(.headline)
                Text(kind.tagline).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                Text(kind == .lidar ? "Best for: detail, textures, objects" : "Best for: layouts, measurements, real estate")
                    .font(.caption).foregroundStyle(Theme.accentSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(16)
        .glassPanel(cornerRadius: 22)
    }
}

struct ScanTipsView: View {
    @Environment(\.dismiss) private var dismiss

    private let tips: [(String, String, String)] = [
        ("tortoise", "Move slowly", "Walk at half your normal pace and turn gradually. Fast motion blurs photos and breaks tracking."),
        ("arrow.up.and.down", "Scan from several heights", "Sweep once at chest height, then low for furniture and floor, then high for the ceiling."),
        ("ruler", "Keep 0.5–3 m away", "LiDAR is most accurate at arm's length to a few meters. Step closer for details."),
        ("lightbulb.max", "Light it up", "Turn on the lights and open curtains. Even lighting gives better textures."),
        ("rectangle.on.rectangle.slash", "Watch out for mirrors and glass", "Reflective and transparent surfaces confuse the depth sensor."),
        ("square.split.bottomrightquarter", "Apartments: one room at a time", "In Room Plan mode finish each room, walk to the next with the camera pointed at the floor, then tap Scan Next Room."),
    ]

    var body: some View {
        NavigationStack {
            List(tips, id: \.1) { tip in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: tip.0)
                        .font(.title3)
                        .foregroundStyle(Theme.accentGradient)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tip.1).font(.headline)
                        Text(tip.2).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Scanning Tips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
