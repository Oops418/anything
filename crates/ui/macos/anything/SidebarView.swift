import SwiftUI

struct SidebarView: View {
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
                Text("FileSearch")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))

                HStack(spacing: 4) {
                    Circle()
                        .fill(Color(red: 0.71, green: 0.65, blue: 1.0).opacity(0.95))
                        .frame(width: 5, height: 5)
                    Text("BETA 0.4.1")
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
            .frame(maxWidth: .infinity)
        }
        .padding(.bottom, 12)
    }

    // MARK: Index Stats

    private var indexStats: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Index")
            statRow("Total files",   "\(mockFiles.count)", accent: .white.opacity(0.8))
            statRow("Last indexed",  "Just now")
            statRow("Status",        "● Live",  accent: Color(red: 0.27, green: 0.86, blue: 0.43))
            statRow("Avg query",     "~220 ms")
        }
    }

    // MARK: Excluded Paths

    private let locationPaths = [
        "~/Documents", "~/Desktop", "~/Projects",
        "~/Pictures",  "~/Music",   "~/Movies", "~/Downloads"
    ]

    private var excludedPaths: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                sectionLabel("Excluded Paths")
                    .padding(.bottom, 0)
                Spacer(minLength: 4)
                addPathButton
            }
            .padding(.bottom, 5)

            ForEach(locationPaths, id: \.self) { path in
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
        Button(action: {}) {
            Text("↺  Re-index now")
                .font(.system(size: 9.5))
                .foregroundColor(.white.opacity(0.45))
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
}

#Preview {
    SidebarView()
        .background(Color(red: 0.08, green: 0.08, blue: 0.15))
        .frame(height: 600)
}
