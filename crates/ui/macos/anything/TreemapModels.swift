import Combine
import Foundation
import SwiftUI
import GeneratedStore

enum TreemapNodeKind {
    case file
    case directory
}

struct TreemapNodeItem: Identifiable, Equatable {
    let path: String
    let name: String
    let kind: TreemapNodeKind
    let sizeBytes: Int64
    let hasChildren: Bool
    var children: [TreemapNodeItem]?
    var isExpanded: Bool = false
    var isLoadingChildren: Bool = false

    var id: String { path }
    var isDirectory: Bool { kind == .directory }
    var displaySize: String { Self.sizeFormatter.string(fromByteCount: sizeBytes) }

    init(proto node: Store_V1_TreemapNode) {
        path = node.path
        name = node.name.isEmpty ? "/" : node.name
        kind = node.type == .directory ? .directory : .file
        sizeBytes = node.size
        hasChildren = node.hasChildren_p
        children = node.children.isEmpty ? nil : node.children.map(TreemapNodeItem.init(proto:))
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()
}

@MainActor
final class TreemapTreeStore: ObservableObject {
    @Published private(set) var root: TreemapNodeItem?
    @Published private(set) var isLoadingRoot = false
    @Published private(set) var errorMessage: String?

    private let service: StoreTreemapService
    private var cachedChildrenByPath: [String: [TreemapNodeItem]] = [:]

    init(service: StoreTreemapService = StoreTreemapService()) {
        self.service = service
    }

    func loadRootIfNeeded() async {
        guard root == nil, !isLoadingRoot else { return }
        await reloadRoot()
    }

    func reloadRoot() async {
        isLoadingRoot = true
        errorMessage = nil

        do {
            let rootNode = try await service.fetch(rootPath: "/", depth: 1)
            var item = TreemapNodeItem(proto: rootNode)
            item.isExpanded = true
            root = item
            cachedChildrenByPath = [item.path: item.children ?? []]
        } catch {
            root = nil
            errorMessage = error.localizedDescription
        }

        isLoadingRoot = false
    }

    func toggleDirectory(at path: String) {
        guard let node = node(at: path), node.isDirectory, node.hasChildren, !node.isLoadingChildren else {
            return
        }

        if node.isExpanded {
            updateNode(at: path) { target in
                target.isExpanded = false
            }
            return
        }

        if let cachedChildren = cachedChildrenByPath[path] {
            updateNode(at: path) { target in
                target.children = cachedChildren
                target.isExpanded = true
                target.isLoadingChildren = false
            }
            return
        }

        updateNode(at: path) { target in
            target.isExpanded = true
            target.isLoadingChildren = true
        }

        Task {
            await loadChildren(for: path)
        }
    }

    private func loadChildren(for path: String) async {
        do {
            let subtree = try await service.fetch(rootPath: path, depth: 1)
            let children = subtree.children.map(TreemapNodeItem.init(proto:))
            cachedChildrenByPath[path] = children

            updateNode(at: path) { target in
                target.children = children
                target.isLoadingChildren = false
                target.isExpanded = true
            }
        } catch {
            updateNode(at: path) { target in
                target.isLoadingChildren = false
                target.isExpanded = false
            }
            errorMessage = error.localizedDescription
        }
    }

    private func node(at path: String) -> TreemapNodeItem? {
        guard let root else { return nil }
        return findNode(in: root, path: path)
    }

    private func findNode(in node: TreemapNodeItem, path: String) -> TreemapNodeItem? {
        if node.path == path {
            return node
        }

        guard let children = node.children else {
            return nil
        }

        for child in children {
            if let match = findNode(in: child, path: path) {
                return match
            }
        }

        return nil
    }

    private func updateNode(at path: String, mutate: (inout TreemapNodeItem) -> Void) {
        guard var root else { return }
        guard mutateNode(in: &root, path: path, mutate: mutate) else { return }
        self.root = root
    }

    private func mutateNode(
        in node: inout TreemapNodeItem,
        path: String,
        mutate: (inout TreemapNodeItem) -> Void
    ) -> Bool {
        if node.path == path {
            mutate(&node)
            return true
        }

        guard var children = node.children else {
            return false
        }

        for index in children.indices {
            if mutateNode(in: &children[index], path: path, mutate: mutate) {
                node.children = children
                return true
            }
        }

        return false
    }
}
