import AppKit
import SwiftUI
import GeneratedStore

struct SidebarView: View {
    @EnvironmentObject private var config: StoreConfigService
    @State private var isHoveringAddPath = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            appIdentity
            divider
            indexStats
            divider
            excludedPaths
            Spacer(minLength: 24)
            reindexButton
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 16)
        .frame(width: 176)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    // MARK: App Identity

    private var appIdentity: some View {
        VStack(alignment: .center, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(
                        colors: [
                            Color(red: 0.43, green: 0.35, blue: 1.0).opacity(0.55),
                            Color(red: 0.20, green: 0.67, blue: 1.0).opacity(0.45)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    )
                    .shadow(color: Color(red: 0.39, green: 0.31, blue: 1.0).opacity(0.35),
                            radius: 10, y: 3)
                Text("🔍").font(.system(size: 24))
            }
            .frame(width: 52, height: 52)
            .padding(.top, 10)

            VStack(spacing: 4) {
                Text("Anything")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))

                Button(action: {
                    if let url = URL(string: "https://github.com/Oops418/anything-rs/releases") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 4) {
                        Text("BETA")
                            .font(.system(size: 6.5, weight: .bold))
                            .foregroundColor(.white.opacity(0.9))
                            .kerning(0.6)
                        Text(config.version.isEmpty ? "–" : config.version)
                            .font(.system(size: 7.5, weight: .medium))
                            .foregroundColor(Color(red: 0.78, green: 0.74, blue: 1.0).opacity(0.9))
                            .kerning(0.5)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color(red: 0.43, green: 0.35, blue: 1.0).opacity(0.28))
                            .overlay(Capsule().stroke(
                                Color(red: 0.51, green: 0.43, blue: 1.0).opacity(0.4), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor(.pointingHand)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.bottom, 12)
    }

    // MARK: Index Stats

    private var indexStats: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Index")

            if config.indexing {
                indexingInProgress
            } else {
                statRow("Total files",  formatFileCount(config.totalFiles), accent: .white.opacity(0.8))
                statRow("Last indexed", formatLastIndexed(config.lastIndexed))
                statRow(
                    "Monitor",
                    config.monitoring ? "● Watching" : "● Off",
                    accent: config.monitoring
                        ? Color(red: 0.27, green: 0.86, blue: 0.43)
                        : .white.opacity(0.4)
                )
            }
        }
    }

    private var indexingInProgress: some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .tint(.white.opacity(0.6))
            Text("Indexing…")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.55))
        }
        .padding(.vertical, 6)
    }

    // MARK: Excluded Paths

    private var excludedPaths: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                sectionLabel("Excluded Paths")
                    .padding(.bottom, 0)
                Spacer(minLength: 4)
                addPathButton
            }
            .padding(.bottom, 5)

            if config.excludePaths.isEmpty {
                Text("None")
                    .font(.system(size: 9.5))
                    .foregroundColor(.white.opacity(0.22))
                    .padding(.vertical, 2)
            } else {
                ForEach(config.excludePaths, id: \.self) { path in
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.minus")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.28))
                            .frame(width: 11)
                        Text(path)
                            .font(.system(size: 9.5))
                            .foregroundColor(.white.opacity(0.32))
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var addPathButton: some View {
        Button(action: {}) {
            Text("+ Add Path")
                .font(.system(size: 8.5, weight: .medium))
                .foregroundColor(.white.opacity(isHoveringAddPath ? 0.72 : 0.46))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(isHoveringAddPath ? 0.08 : 0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.white.opacity(isHoveringAddPath ? 0.12 : 0.08), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { isHoveringAddPath = $0 }
    }

    // MARK: Re-index Button

    private var reindexButton: some View {
        Button(action: {
            Task { await config.refresh() }
        }) {
            Text("↺  Re-index now")
                .font(.system(size: 9.5))
                .foregroundColor(.white.opacity(config.indexing ? 0.25 : 0.45))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.05))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.09), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .disabled(config.indexing)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: Helpers

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
            .padding(.vertical, 12)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 8, weight: .regular))
            .foregroundColor(.white.opacity(0.28))
            .kerning(0.8)
            .padding(.bottom, 5)
    }

    private func statRow(_ label: String, _ value: String,
                         accent: Color = .white.opacity(0.65)) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))
            Spacer()
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(accent)
        }
        .padding(.vertical, 2)
    }

    private func formatFileCount(_ count: Int64) -> String {
        count == 0 ? "–" : count.formatted(.number)
    }

    private func formatLastIndexed(_ date: Date?) -> String {
        guard let date else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    SidebarView()
        .environmentObject(StoreConfigService())
        .background(Color(red: 0.08, green: 0.08, blue: 0.15))
        .frame(height: 600)
}

private extension View {
    func pointerCursor(_ cursor: NSCursor) -> some View {
        onHover { isHovering in
            if isHovering {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
