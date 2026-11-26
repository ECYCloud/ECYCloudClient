import Foundation

// 浏览缓存：翻页与搜索取到、还没并入面板配置的节点。只在内存里，超出上限丢最早的
public struct NodeBrowse: Sendable {
    static let limit = 2000
    public private(set) var nodes: [String: CatalogNode] = [:]
    private var order: [String] = []

    mutating func insert(_ added: [CatalogNode]) {
        for node in added where nodes.updateValue(node, forKey: node.node.id) == nil { order.append(node.node.id) }
        guard order.count > Self.limit else { return }
        for id in order.prefix(order.count - Self.limit) { nodes[id] = nil }
        order.removeFirst(order.count - Self.limit)
    }

    mutating func remove(_ ids: Set<String>) {
        guard ids.contains(where: { nodes[$0] != nil }) else { return }
        for id in ids { nodes[id] = nil }
        order.removeAll(where: ids.contains)
    }
}

// 面板只下发了一部分节点时的浏览、搜索与并入，规则见 docs/architecture.md「节点目录分页」
extension ClientSession {
    public func node(_ id: String) -> CloudNode? { catalog?.node(id) ?? browsed.nodes[id]?.node }

    public func displayName(_ id: String) -> String {
        catalog?.node(id)?.name ?? browsed.nodes[id]?.node.name ?? catalog?.displayName(id) ?? id
    }

    // 分组当前列出的成员：已知成员与浏览缓存里属于该组的节点按序号合在一起
    public func members(of group: NodeSelectionGroup) -> [String] {
        guard let catalog, let pages = catalog.paging?.pages[group.id], !browsed.nodes.isEmpty else { return group.members }
        let keys = Set(pages.map(\.key))
        let extra = browsed.nodes.values.filter { catalog.node($0.node.id) == nil && !keys.isDisjoint(with: $0.providers) }
        return extra.isEmpty ? group.members
            : NodeWorkingSet.inserting(extra.map { ($0.rank, $0.node.id) }, into: group.members) { catalog.rank($0) }
    }

    public func memberCount(of group: NodeSelectionGroup) -> Int { catalog?.total(of: group) ?? group.members.count }

    // 面板上还有没带下来的成员：搜索要问面板
    public func hasUnlistedNodes(_ group: NodeSelectionGroup) -> Bool {
        catalog?.paging?.pages[group.id]?.contains { $0.known < $0.total } == true
    }

    private func nextPage(_ group: NodeSelectionGroup) -> (key: String, offset: Int)? {
        catalog?.paging?.pages[group.id]?.lazy.map { ($0.key, self.pageOffsets[$0.key] ?? $0.head, $0.total) }
            .first { $0.1 < $0.2 }.map { ($0.0, $0.1) }
    }

    public func hasMoreNodes(_ group: NodeSelectionGroup) -> Bool { nextPage(group) != nil }

    public func loadMoreNodes(_ group: NodeSelectionGroup) async throws {
        guard let page = nextPage(group), loadingPages.insert(page.key).inserted else { return }
        defer { loadingPages.remove(page.key) }
        let result = try await fetchNodes { try await $0.catalogNodes($1, token: $2, key: page.key, offset: page.offset) }
        pageOffsets[page.key] = result.more ? page.offset + PanelAPI.catalogPageSize : .max
        browse(result.nodes)
    }

    // 返回下一页的偏移，没有更多时为 nil
    public func searchNodes(_ group: NodeSelectionGroup, query: String, offset: Int) async throws -> Int? {
        guard let key = catalog?.paging?.pages[group.id]?.first?.key else { return nil }
        let result = try await fetchNodes { try await $0.catalogNodes($1, token: $2, key: key, offset: offset, search: query) }
        browse(result.nodes)
        return result.more ? offset + PanelAPI.catalogPageSize : nil
    }

    func resetBrowsing() {
        browsed = NodeBrowse()
        pageOffsets = [:]
        loadingPages = []
    }

    private func browse(_ nodes: [CatalogNode]) {
        browsed.insert(nodes.filter { catalog?.node($0.node.id) == nil })
    }

    // 面板的目录换了版（节点或模板已变）：丢弃这次结果与浏览缓存，走正常的配置刷新
    private func fetchNodes(_ request: (PanelAPI, PanelEndpoints, String) async throws -> PanelAPI.CatalogPage) async throws -> PanelAPI.CatalogPage {
        guard let stamp = catalog?.paging?.stamp else { throw CancellationError() }
        let result = try await authenticated(silently: true) { try await request(api, endpoints, $0.token) }
        guard catalog?.paging?.stamp == stamp else { throw CancellationError() }
        guard result.stamp == stamp else {
            resetBrowsing()
            Task { await loadNodes() }
            throw CancellationError()
        }
        return result
    }

    // 选中、测延迟、测速用到的节点只在浏览缓存里（或只知道名字）时，先并入面板配置并落盘缓存。
    // 逐次排队：两次并入交错，后完成的会盖掉先完成的
    func absorb(_ names: [String]) async throws {
        guard let current = catalog, current.paging != nil,
              names.contains(where: { NodeCatalog.isNodeID($0) && current.node($0) == nil }) else { return }
        let previous = nodeAbsorb
        let task = Task { [weak self] in
            _ = try? await previous?.value
            guard let self, let catalog, catalog.paging != nil else { throw CancellationError() }
            var seen = Set<String>()
            let wanted = names.filter { NodeCatalog.isNodeID($0) && catalog.node($0) == nil && seen.insert($0).inserted }
            var nodes = wanted.compactMap { browsed.nodes[$0] }
            let unknown = wanted.filter { browsed.nodes[$0] == nil }
            for start in stride(from: 0, to: unknown.count, by: PanelAPI.catalogNamesLimit) {
                let batch = Array(unknown[start..<min(start + PanelAPI.catalogNamesLimit, unknown.count)])
                nodes += try await fetchNodes { try await $0.catalogNodes($1, token: $2, names: batch) }.nodes
            }
            guard !nodes.isEmpty else { return }
            let merged = try await Self.merge(nodes, into: catalog)
            guard self.catalog?.revision == catalog.revision, self.catalog?.paging?.stamp == catalog.paging?.stamp, phase == .signedIn else { throw CancellationError() }
            replaceCatalog(merged)
            browsed.remove(Set(nodes.map(\.node.id)))
        }
        nodeAbsorb = task
        try await task.value
    }

    private nonisolated static func merge(_ nodes: [CatalogNode], into catalog: NodeCatalog) async throws -> (catalog: NodeCatalog, response: Data) {
        let merged = try catalog.merging(nodes)
        try merged.catalog.validate()
        return merged
    }
}
