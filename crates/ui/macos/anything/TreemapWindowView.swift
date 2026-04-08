import AppKit
import SwiftUI

private let treemapWindowIdentifier = NSUserInterfaceItemIdentifier("treemap-window")

private enum TreemapMetrics {
    static let tileGap: CGFloat = 0
    static let minLabelWidth: CGFloat = 88
    static let minLabelHeight: CGFloat = 54
    static let minNestedWidth: CGFloat = 92
    static let minNestedHeight: CGFloat = 84
    static let nestedInset: CGFloat = 0
    static let titleBarHeight: CGFloat = 22
}

struct TreemapWindowView: View {
    @StateObject private var treeStore = TreemapTreeStore()

    var body: some View {
        ZStack {
            GeometryReader { geo in
                treemapBackground(in: geo.size)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            Group {
                if treeStore.isLoadingRoot {
                    loadingState
                } else if let root = treeStore.root, let children = root.children, !children.isEmpty {
                    TreemapLevelView(
                        nodes: children,
                        depth: 0,
                        treeStore: treeStore
                    )
                } else if let errorMessage = treeStore.errorMessage {
                    errorState(errorMessage)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(6)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.06, blue: 0.14),
                    Color(red: 0.04, green: 0.08, blue: 0.16),
                    Color(red: 0.01, green: 0.03, blue: 0.09)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .background(
            WindowKeyMonitor { event in
                handleKeyDown(event)
            }
        )
        .background(TreemapWindowConfigurator())
        .frame(minWidth: 860, minHeight: 620)
        .task {
            await treeStore.loadRootIfNeeded()
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(.white.opacity(0.78))
            Text("Loading indexed file sizes…")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.64))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundColor(.white.opacity(0.30))
            Text("No indexed files available")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.56))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundColor(Color(red: 1.0, green: 0.78, blue: 0.80))
            Text("Treemap request failed")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.72))
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.46))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func treemapBackground(in size: CGSize) -> some View {
        ZStack {
            radialOrb(
                color: Color(red: 0.54, green: 0.82, blue: 1.0).opacity(0.20),
                size: 460,
                blur: 52
            )
            .offset(x: -size.width * 0.18, y: -size.height * 0.22)

            radialOrb(
                color: Color(red: 0.24, green: 0.58, blue: 1.0).opacity(0.20),
                size: 380,
                blur: 48
            )
            .offset(x: size.width * 0.34, y: size.height * 0.20)

            radialOrb(
                color: Color.white.opacity(0.16),
                size: 320,
                blur: 44
            )
            .offset(x: size.width * 0.18, y: -size.height * 0.28)
        }
    }

    private func radialOrb(color: Color, size: CGFloat, blur: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color, .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
            .blur(radius: blur)
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard NSApp.keyWindow?.identifier == treemapWindowIdentifier else {
            return false
        }

        switch event.keyCode {
        case 49:
            if let selectedNode = treeStore.selectedNode {
                QuickPreviewCoordinator.shared.togglePreview(for: previewURL(for: selectedNode))
                return true
            }
        case 53:
            if QuickPreviewCoordinator.shared.isVisible {
                QuickPreviewCoordinator.shared.dismissPreview()
                return true
            }
        default:
            break
        }

        return false
    }

    private func previewURL(for node: TreemapNodeItem) -> URL? {
        let expandedPath = NSString(string: node.path).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

private struct TreemapLevelView: View {
    let nodes: [TreemapNodeItem]
    let depth: Int
    @ObservedObject var treeStore: TreemapTreeStore

    var body: some View {
        GeometryReader { geometry in
            let layoutItems = SquarifiedTreemapLayout.layout(
                nodes: nodes,
                in: CGRect(origin: .zero, size: geometry.size)
            )

            ZStack(alignment: .topLeading) {
                ForEach(layoutItems) { item in
                    let rect = item.rect.insetBy(dx: TreemapMetrics.tileGap / 2, dy: TreemapMetrics.tileGap / 2)

                    if rect.width > 1, rect.height > 1 {
                        TreemapTileView(
                            node: item.node,
                            depth: depth,
                            size: rect.size,
                            treeStore: treeStore
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
        }
    }
}

private struct TreemapTileView: View {
    let node: TreemapNodeItem
    let depth: Int
    let size: CGSize
    @ObservedObject var treeStore: TreemapTreeStore

    @State private var isHovering = false

    private var isSelected: Bool {
        treeStore.selectedPath == node.path
    }

    private var canNestChildren: Bool {
        size.width >= TreemapMetrics.minNestedWidth && size.height >= TreemapMetrics.minNestedHeight
    }

    private var showsExpandedTreemap: Bool {
        node.isExpanded && node.isDirectory && canNestChildren
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            tileChrome

            if showsExpandedTreemap {
                expandedDirectoryBody
            } else {
                centeredTileLabel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            selectionSurface

            if node.isDirectory {
                directoryControls
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open in Folder") {
                treeStore.selectNode(at: node.path)
                revealInFinder()
            }
        }
    }

    private var cornerRadius: CGFloat {
        max(2, min(size.width, size.height) * 0.025)
    }

    private var tileChrome: some View {
        let baseColor = tileColor(for: node, depth: depth)

        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        baseColor.opacity(isHovering ? 0.52 : 0.42),
                        baseColor.opacity(isHovering ? 0.34 : 0.26),
                        Color.white.opacity(0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isHovering ? 0.18 : 0.12),
                                .clear,
                                Color.black.opacity(0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        isSelected
                            ? Color.white.opacity(0.84)
                            : Color.white.opacity(isHovering ? 0.34 : 0.22),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .shadow(color: .black.opacity(0.16), radius: 10, y: 6)
    }

    private var expandedDirectoryBody: some View {
        VStack(spacing: 0) {
            directoryTitleBar
                .frame(height: TreemapMetrics.titleBarHeight)

            nestedTreemap
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var directoryTitleBar: some View {
        ZStack {
            Text("\(node.name)  \(node.displaySize)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.90))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    treeStore.selectNode(at: node.path)
                }

            Button {
                treeStore.selectNode(at: node.path)
                treeStore.toggleDirectory(at: node.path)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.white.opacity(0.72))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var nestedTreemap: some View {
        if node.isLoadingChildren {
            VStack {
                Spacer(minLength: 0)
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.80))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let children = node.children, !children.isEmpty {
            TreemapLevelView(nodes: children, depth: depth + 1, treeStore: treeStore)
        }
    }

    private var centeredTileLabel: some View {
        Text("\(node.name)  \(node.displaySize)")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(.white.opacity(0.92))
            .lineLimit(1)
            .minimumScaleFactor(0.42)
            .truncationMode(.tail)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
    }

    @ViewBuilder
    private var selectionSurface: some View {
        if !showsExpandedTreemap {
            Color.clear
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .onTapGesture {
                    handlePrimaryAction()
                }
        }
    }

    @ViewBuilder
    private var directoryControls: some View {
        if node.isExpanded && !showsExpandedTreemap {
            Button {
                treeStore.selectNode(at: node.path)
                treeStore.toggleDirectory(at: node.path)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.78))
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(Color.black.opacity(0.18))
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    private func handlePrimaryAction() {
        treeStore.selectNode(at: node.path)

        if node.isDirectory && !node.isExpanded {
            treeStore.toggleDirectory(at: node.path)
        }
    }

    private func revealInFinder() {
        let expandedPath = NSString(string: node.path).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func tileColor(for node: TreemapNodeItem, depth: Int) -> Color {
        let depthShift = Double(depth) * 0.06

        if node.isDirectory {
            return Color(
                red: max(0.10, 0.20 - depthShift * 0.3),
                green: min(0.72, 0.46 + depthShift * 0.4),
                blue: min(1.0, 0.92 + depthShift * 0.12)
            )
        }

        return Color(
            red: min(1.0, 0.54 + depthShift * 0.3),
            green: min(1.0, 0.76 + depthShift * 0.1),
            blue: min(1.0, 0.96)
        )
    }
}

private struct TreemapLayoutItem: Identifiable {
    let node: TreemapNodeItem
    let rect: CGRect

    var id: String { node.path }
}

private enum SquarifiedTreemapLayout {
    static func layout(nodes: [TreemapNodeItem], in rect: CGRect) -> [TreemapLayoutItem] {
        let filteredNodes = nodes.filter { $0.sizeBytes > 0 }
        guard !filteredNodes.isEmpty, rect.width > 0, rect.height > 0 else {
            return []
        }

        let sortedNodes = filteredNodes.sorted {
            if $0.sizeBytes == $1.sizeBytes {
                return $0.path < $1.path
            }
            return $0.sizeBytes > $1.sizeBytes
        }

        let totalWeight = Double(sortedNodes.reduce(Int64(0)) { $0 + $1.sizeBytes })
        guard totalWeight > 0 else { return [] }

        let totalArea = rect.width * rect.height
        var remaining = sortedNodes.map { node in
            (node: node, area: CGFloat(Double(node.sizeBytes) / totalWeight) * totalArea)
        }
        var remainingRect = rect
        var row: [(node: TreemapNodeItem, area: CGFloat)] = []
        var layoutItems: [TreemapLayoutItem] = []

        while let next = remaining.first {
            let shortSide = min(remainingRect.width, remainingRect.height)
            let currentScore = worstAspectRatio(for: row, shortSide: shortSide)
            let candidateScore = worstAspectRatio(for: row + [next], shortSide: shortSide)

            if row.isEmpty || candidateScore <= currentScore {
                row.append(next)
                remaining.removeFirst()
            } else {
                let result = layoutRow(row, in: remainingRect)
                layoutItems.append(contentsOf: result.items)
                remainingRect = result.remainingRect
                row.removeAll(keepingCapacity: true)
            }
        }

        if !row.isEmpty {
            let result = layoutRow(row, in: remainingRect)
            layoutItems.append(contentsOf: result.items)
        }

        return layoutItems
    }

    private static func worstAspectRatio(
        for row: [(node: TreemapNodeItem, area: CGFloat)],
        shortSide: CGFloat
    ) -> CGFloat {
        guard !row.isEmpty, shortSide > 0 else {
            return .greatestFiniteMagnitude
        }

        let areas = row.map(\.area)
        let sum = areas.reduce(0, +)
        guard let minArea = areas.min(), let maxArea = areas.max(), minArea > 0 else {
            return .greatestFiniteMagnitude
        }

        let sideSquared = shortSide * shortSide
        let sumSquared = sum * sum

        return max((sideSquared * maxArea) / sumSquared, sumSquared / (sideSquared * minArea))
    }

    private static func layoutRow(
        _ row: [(node: TreemapNodeItem, area: CGFloat)],
        in rect: CGRect
    ) -> (items: [TreemapLayoutItem], remainingRect: CGRect) {
        guard !row.isEmpty else {
            return ([], rect)
        }

        let rowArea = row.map(\.area).reduce(0, +)
        var items: [TreemapLayoutItem] = []

        if rect.width >= rect.height {
            let rowWidth = rowArea / max(rect.height, 1)
            var currentY = rect.minY

            for item in row {
                let height = item.area / max(rowWidth, 1)
                items.append(
                    TreemapLayoutItem(
                        node: item.node,
                        rect: CGRect(x: rect.minX, y: currentY, width: rowWidth, height: height)
                    )
                )
                currentY += height
            }

            return (
                items,
                CGRect(
                    x: rect.minX + rowWidth,
                    y: rect.minY,
                    width: max(0, rect.width - rowWidth),
                    height: rect.height
                )
            )
        }

        let rowHeight = rowArea / max(rect.width, 1)
        var currentX = rect.minX

        for item in row {
            let width = item.area / max(rowHeight, 1)
            items.append(
                TreemapLayoutItem(
                    node: item.node,
                    rect: CGRect(x: currentX, y: rect.minY, width: width, height: rowHeight)
                )
            )
            currentX += width
        }

        return (
            items,
            CGRect(
                x: rect.minX,
                y: rect.minY + rowHeight,
                width: rect.width,
                height: max(0, rect.height - rowHeight)
            )
        )
    }
}

private struct TreemapWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.identifier = treemapWindowIdentifier
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.hasShadow = true
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

#Preview {
    TreemapWindowView()
}
