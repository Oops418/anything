import Combine
import Foundation
import SwiftUI
import GeneratedStore

enum TreemapNodeKind: Equatable, Sendable {
    case file
    case directory

    nonisolated static func == (lhs: TreemapNodeKind, rhs: TreemapNodeKind) -> Bool {
        switch (lhs, rhs) {
        case (.file, .file), (.directory, .directory):
            return true
        default:
            return false
        }
    }
}

struct TreemapNodeItem: Identifiable, Equatable, Sendable {
    let path: String
    let name: String
    let kind: TreemapNodeKind
    let sizeBytes: Int64
    let hasChildren: Bool
    var children: [TreemapNodeItem]?
    var isExpanded: Bool = false
    var isLoadingChildren: Bool = false

    nonisolated var id: String { path }
    nonisolated var isDirectory: Bool { kind == .directory }
    nonisolated var displaySize: String { sizeBytes.formatted(.byteCount(style: .file)) }

    nonisolated init(proto node: Store_V1_TreemapNode) {
        path = node.path
        name = node.name.isEmpty ? "/" : node.name
        kind = node.type == .directory ? .directory : .file
        sizeBytes = node.size
        hasChildren = node.hasChildren_p
        children = node.children.isEmpty ? nil : node.children.map { TreemapNodeItem(proto: $0) }
    }

    nonisolated static func == (lhs: TreemapNodeItem, rhs: TreemapNodeItem) -> Bool {
        lhs.path == rhs.path &&
        lhs.name == rhs.name &&
        lhs.kind == rhs.kind &&
        lhs.sizeBytes == rhs.sizeBytes &&
        lhs.hasChildren == rhs.hasChildren &&
        lhs.children == rhs.children &&
        lhs.isExpanded == rhs.isExpanded &&
        lhs.isLoadingChildren == rhs.isLoadingChildren
    }
}

@MainActor
final class TreemapTreeStore: ObservableObject {
    @Published private(set) var root: TreemapNodeItem?
    @Published private(set) var isLoadingRoot = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedPath: String?

    private let service: StoreTreemapService
    private var cachedChildrenByPath: [String: [TreemapNodeItem]] = [:]

    init(service: StoreTreemapService = StoreTreemapService()) {
        self.service = service
    }

    func loadRootIfNeeded() async {
        guard root == nil, !isLoadingRoot else { return }
        await reloadRoot()
    }

    var selectedNode: TreemapNodeItem? {
        guard let selectedPath else { return nil }
        return node(at: selectedPath)
    }

    func reloadRoot() async {
        isLoadingRoot = true
        errorMessage = nil

        do {
            let rootNode = try await service.fetch(rootPath: "/", depth: 1)
            var item = TreemapNodeItem(proto: rootNode)
            item.isExpanded = true
            root = item
            selectedPath = nil
            cachedChildrenByPath = [item.path: item.children ?? []]
        } catch {
            root = nil
            selectedPath = nil
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

    func selectNode(at path: String) {
        guard node(at: path) != nil else { return }
        selectedPath = path
    }

    private func loadChildren(for path: String) async {
        do {
            let subtree = try await service.fetch(rootPath: path, depth: 1)
            let children = subtree.children.map { TreemapNodeItem(proto: $0) }
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
