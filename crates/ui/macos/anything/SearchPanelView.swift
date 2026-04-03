import SwiftUI
import AppKit
@preconcurrency import QuickLookUI

private let tableResizeAnimation = Animation.interactiveSpring(
    response: 0.24,
    dampingFraction: 0.88,
    blendDuration: 0.12
)

private struct SearchTableMetrics {
    static let tableInset: CGFloat = 16
    static let horizontalPadding: CGFloat = 10
    static let columnSpacing: CGFloat = 10
    static let indicatorWidth: CGFloat = 6
    static let iconWidth: CGFloat = 20
    static let sizeWidth: CGFloat = 104
    static let modifiedWidth: CGFloat = 112

    let contentWidth: CGFloat
    let nameWidth: CGFloat
    let pathWidth: CGFloat

    init(availableWidth: CGFloat) {
        let resolvedContentWidth = max(availableWidth - (Self.tableInset * 2), 0)
        let fixedWidth =
            Self.horizontalPadding * 2 +
            Self.columnSpacing * 5 +
            Self.indicatorWidth +
            Self.iconWidth +
            Self.sizeWidth +
            Self.modifiedWidth
        let flexibleWidth = max(resolvedContentWidth - fixedWidth, 0)
        let minimumNameWidth = max(120, min(170, flexibleWidth * 0.42))
        let maximumNameWidth = min(280, max(150, flexibleWidth - 120))
        let preferredNameWidth = (flexibleWidth * 0.32) + 36
        let resolvedNameWidth = min(max(preferredNameWidth, minimumNameWidth), maximumNameWidth)
        let resolvedPathWidth = max(flexibleWidth - resolvedNameWidth, 0)

        contentWidth = resolvedContentWidth
        nameWidth = resolvedNameWidth
        pathWidth = resolvedPathWidth
    }
}

// MARK: - SearchPanelView

private enum SearchPanelFocusArea {
    case search
    case results
}

@MainActor
private final class PreviewCoordinator: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = PreviewCoordinator()

    private var currentURL: URL?
    private(set) var isVisible = false

    func togglePreview(for file: FileItem) {
        guard let previewURL = file.previewURL else {
            NSSound.beep()
            return
        }

        if isVisible, currentURL == previewURL {
            dismissPreview()
            return
        }

        currentURL = previewURL
        presentPreview()
    }

    func dismissPreview() {
        QLPreviewPanel.shared()?.orderOut(nil)
        isVisible = false
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        currentURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        currentURL as NSURL?
    }

    func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        isVisible = false
    }

    private func presentPreview() {
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
        isVisible = true
    }
}

struct SearchPanelView: View {
    @State private var query      = ""
    @State private var results    = [FileItem]()
    @State private var hasSearched  = false
    @State private var isLoading    = false
    @State private var selectedId: String? = nil
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var activeArea: SearchPanelFocusArea = .search
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            resultsBody
        }
        .padding(14)
        .background(
            SearchPanelKeyMonitor { event in
                handleKeyDown(event)
            }
        )
        .background {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.06),
                                    Color(red: 0.35, green: 0.56, blue: 0.86).opacity(0.05),
                                    Color.white.opacity(0.02)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(Color.white.opacity(0.24), lineWidth: 1)
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: .black.opacity(0.38), radius: 44, y: 22)
    }

    // MARK: Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.55))

            TextField("Search files by name, extension, or path…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .focused($isSearchFieldFocused)
                .onChange(of: query) { _ in scheduleSearch() }

            if isLoading {
                ProgressView()
                    .scaleEffect(0.6)
                    .tint(.white.opacity(0.65))
            } else if !query.isEmpty {
                Button(action: clearSearch) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.18))
                            .frame(width: 16, height: 16)
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .contentShape(Rectangle())
        .onTapGesture {
            activeArea = .search
            isSearchFieldFocused = true
        }
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.20), lineWidth: 1)
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
        }
    }

    // MARK: Results Body

    @ViewBuilder
    private var resultsBody: some View {
        if !hasSearched {
            idleState
        } else if isLoading {
            Spacer()
        } else if results.isEmpty {
            emptyState
        } else {
            resultsState
        }
    }

    private var idleState: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1))
                Text("🔍").font(.system(size: 28))
            }
            .frame(width: 60, height: 60)

            VStack(spacing: 4) {
                Text("Start typing to query your files")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                Text("\(mockFiles.count) files ready to search")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.25))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 24)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("🪹").font(.system(size: 36))
            Text("No results for \"\(query)\"")
                .font(.system(size: 11.5))
                .foregroundColor(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 24)
    }

    private var resultsState: some View {
        GeometryReader { geo in
            let metrics = SearchTableMetrics(availableWidth: geo.size.width)

            VStack(spacing: 0) {
                HStack {
                    HStack(spacing: 3) {
                        Text("\(results.count)")
                            .foregroundColor(.white.opacity(0.75))
                        Text(results.count == 1 ? "result" : "results")
                            .foregroundColor(.white.opacity(0.5))
                        Text("·")
                            .foregroundColor(.white.opacity(0.25))
                        Text("\(mockFiles.count) indexed")
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .font(.system(size: 9.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .overlay(Capsule()
                                .stroke(Color.white.opacity(0.13), lineWidth: 1))
                    )
                    Spacer()
                }
                .frame(width: metrics.contentWidth, alignment: .leading)
                .padding(.horizontal, SearchTableMetrics.tableInset)
                .padding(.top, 10)
                .padding(.bottom, 1)

                columnHeaders(metrics: metrics)

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(results) { file in
                            FileRowView(
                                file: file,
                                isSelected: selectedId == file.id,
                                metrics: metrics
                            ) {
                                selectResult(file.id)
                            }
                        }
                    }
                    .frame(width: metrics.contentWidth, alignment: .leading)
                    .padding(.horizontal, SearchTableMetrics.tableInset)
                    .padding(.vertical, 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(tableResizeAnimation, value: metrics.contentWidth)
            .animation(tableResizeAnimation, value: metrics.nameWidth)
            .animation(tableResizeAnimation, value: metrics.pathWidth)
        }
    }

    private var selectedFile: FileItem? {
        results.first(where: { $0.id == selectedId })
    }

    private func columnHeaders(metrics: SearchTableMetrics) -> some View {
        HStack(spacing: SearchTableMetrics.columnSpacing) {
            Color.clear
                .frame(width: SearchTableMetrics.indicatorWidth, height: 1)
            Color.clear
                .frame(width: SearchTableMetrics.iconWidth, height: 1)

            Text("Name")
                .frame(width: metrics.nameWidth, alignment: .leading)

            Text("Path")
                .frame(width: metrics.pathWidth, alignment: .leading)

            Text("Size")
                .frame(width: SearchTableMetrics.sizeWidth, alignment: .trailing)

            Text("Modified")
                .frame(width: SearchTableMetrics.modifiedWidth, alignment: .trailing)
        }
        .font(.system(size: 8.5, weight: .medium))
        .foregroundColor(.white.opacity(0.30))
        .kerning(0.6)
        .padding(.horizontal, SearchTableMetrics.horizontalPadding)
        .frame(height: 18, alignment: .center)
        .frame(width: metrics.contentWidth, alignment: .leading)
        .animation(tableResizeAnimation, value: metrics.contentWidth)
        .animation(tableResizeAnimation, value: metrics.nameWidth)
        .animation(tableResizeAnimation, value: metrics.pathWidth)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }

    // MARK: Search Logic

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []; hasSearched = false; isLoading = false; selectedId = nil
            return
        }
        isLoading = true; hasSearched = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(260))   // debounce
            guard !Task.isCancelled else { return }
            let latency = Int.random(in: 160...300)
            try? await Task.sleep(for: .milliseconds(latency))
            guard !Task.isCancelled else { return }
            results   = queryFiles(q)
            isLoading = false
        }
    }

    private func clearSearch() {
        searchTask?.cancel()
        query = ""; results = []; hasSearched = false; isLoading = false; selectedId = nil
        activeArea = .search
        PreviewCoordinator.shared.dismissPreview()
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard activeArea == .results, selectedFile != nil else { return false }

        switch event.keyCode {
        case 49:
            if let selectedFile {
                PreviewCoordinator.shared.togglePreview(for: selectedFile)
                return true
            }
        case 53:
            if PreviewCoordinator.shared.isVisible {
                PreviewCoordinator.shared.dismissPreview()
                return true
            }
        default:
            break
        }

        return false
    }

    private func selectResult(_ id: String) {
        activeArea = .results
        isSearchFieldFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
        selectedId = (selectedId == id) ? nil : id
    }
}

private struct SearchPanelKeyMonitor: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onKeyDown: onKeyDown)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onKeyDown = onKeyDown
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class Coordinator {
        var onKeyDown: (NSEvent) -> Bool
        private var monitor: Any?

        init(onKeyDown: @escaping (NSEvent) -> Bool) {
            self.onKeyDown = onKeyDown
        }

        func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.onKeyDown(event) ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

// MARK: - FileRowView

struct FileRowView: View {
    let file: FileItem
    let isSelected: Bool
    fileprivate let metrics: SearchTableMetrics
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: SearchTableMetrics.columnSpacing) {
                Circle()
                    .fill(file.kind.color)
                    .frame(width: SearchTableMetrics.indicatorWidth, height: 6)

                Text(file.emoji)
                    .font(.system(size: 12))
                    .frame(width: SearchTableMetrics.iconWidth, alignment: .center)

                Text(file.displayName)
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: metrics.nameWidth, alignment: .leading)

                Text(file.path)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.30))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: metrics.pathWidth, alignment: .leading)

                Text(file.size)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.40))
                    .frame(width: SearchTableMetrics.sizeWidth, alignment: .trailing)

                Text(file.modified)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(.white.opacity(0.28))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: SearchTableMetrics.modifiedWidth, alignment: .trailing)
            }
            .padding(.horizontal, SearchTableMetrics.horizontalPadding)
            .padding(.vertical, 7)
            .padding(.top, 3)
            .padding(.bottom, 3)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isSelected  ? Color.white.opacity(0.11) :
                        isHovered   ? Color.white.opacity(0.06) : .clear
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.white.opacity(0.18) : .clear, lineWidth: 1)
                    )
            )

            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)
        }
        .frame(width: metrics.contentWidth, alignment: .leading)
        .animation(tableResizeAnimation, value: metrics.contentWidth)
        .animation(tableResizeAnimation, value: metrics.nameWidth)
        .animation(tableResizeAnimation, value: metrics.pathWidth)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovered = $0 }
    }
}

#Preview {
    SearchPanelView()
        .background(Color(red: 0.08, green: 0.08, blue: 0.15))
        .frame(width: 680, height: 560)
}
