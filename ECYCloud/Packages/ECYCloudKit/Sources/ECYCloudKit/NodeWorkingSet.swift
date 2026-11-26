import CryptoKit
import Foundation

// 对应 node_working_set.dart
enum NodeWorkingSet {
    // 交给内核的节点副本上限，面板配置超过这个数就只装在用的节点，其余留在界面，用到时再装入。
    // macOS 与 Flutter 桌面同值：特权侧单条请求上限 4 MiB。其余平台的内核跑在网络扩展里，系统只给约 50 MB 内存，
    // 实测内核装入节点时每 1000 个副本瞬时多占约 25 MiB
    #if os(macOS)
    static let copyBudget = 5000
    #else
    static let copyBudget = 500
    #endif
    // 最近选用过的节点固定装入，免得每次装配都被换出去；数量随上限走，占不满它
    static let recentLimit = copyBudget / 25
    static let probeBatch = 64

    static let nodesProvider = "ecy-panel-nodes"
    // 名字须符合内核侧对节点文件的校验（ecy-panel- 加 64 位十六进制）
    static let probeProvider = "ecy-panel-" + SHA256.hash(data: Data("ecy-probe".utf8)).map { String(format: "%02x", $0) }.joined()
    private static let placeholder = ["name": "ecy-panel-empty", "type": "reject"]

    // 面板声明 X-ECY-Node-Members 后，各组节点文件只带成员名单，节点内容只在 ecy-panel-nodes 里有一份
    static func members(_ provider: [String: Any]) -> [String] {
        if let names = provider["members"] as? [String] { return names }
        return (provider["payload"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.filter { $0 != placeholder["name"] }
    }

    // 各节点文件的成员名；字典没有固定顺序，按文件名排，同一份配置每次选出同一批节点，已装入的不会被无故换出
    private static func lists(_ config: [String: Any]) -> [[String]] {
        guard let providers = config["proxy-providers"] as? [String: [String: Any]], providers[nodesProvider] != nil else { return [] }
        return providers.keys.filter { $0.hasPrefix("ecy-panel-") }.sorted().map { members(providers[$0]!) }
    }

    static func exceedsBudget(_ config: [String: Any], budget: Int = copyBudget) -> Bool {
        lists(config).reduce(0) { $0 + $1.count } > budget
    }

    // 返回要装入内核的节点名；副本数没超过上限时返回 nil，表示全部装入
    static func select(_ config: [String: Any], pinned: [String] = [], budget: Int = copyBudget) -> Set<String>? {
        let lists = lists(config)
        guard lists.reduce(0, { $0 + $1.count }) > budget else { return nil }
        var copies: [String: Int] = [:]
        for list in lists { for name in list { copies[name, default: 0] += 1 } }
        var loaded = Set<String>(), used = 0
        func add(_ name: String) {
            if let count = copies[name], loaded.insert(name).inserted { used += count }
        }
        pinned.forEach(add)
        required(config).forEach(add)
        // 每个有成员的节点文件至少留一个：分组清空会回落成 REJECT，命中该组的流量全被拒
        for list in lists where !list.isEmpty && !list.contains(where: loaded.contains) { add(list[0]) }
        var index = 0
        while used < budget {
            var progressed = false
            for list in lists where index < list.count {
                progressed = true
                add(list[index])
                if used >= budget { break }
            }
            if !progressed { break }
            index += 1
        }
        return loaded
    }

    // 把带序号的新成员插进列表（docs/architecture.md「节点目录分页」的并入规则）：排在第一个序号更大的成员之前，
    // 没有就排在最后一个带序号成员之后；不带序号的成员（模板里写死的节点、固定项）位置不动
    static func inserting<Element>(_ added: [(rank: Int, value: Element)], into list: [Element], rank: (Element) -> Int?) -> [Element] {
        var result: [Element] = [], next = 0, tail = -1
        let added = added.sorted { $0.rank < $1.rank }
        result.reserveCapacity(list.count + added.count)
        for item in list {
            if let position = rank(item) {
                while next < added.count, added[next].rank < position { result.append(added[next].value); next += 1 }
                result.append(item)
                tail = result.count
            } else {
                result.append(item)
            }
        }
        result.insert(contentsOf: added[next...].map(\.value), at: tail < 0 ? result.count : tail)
        return result
    }

    // 分组的初始选中项，以及规则直接指向的节点（面板为每个这样的节点建一个 ecy-panel-target- 分组，
    // filter 是 ^节点名$ 的转义形式）：不装入的话前者落到别的成员上，后者整组清空
    private static func required(_ config: [String: Any]) -> [String] {
        (config["proxy-groups"] as? [[String: Any]] ?? []).flatMap { group -> [String] in
            var names = [group["default-selected"] as? String].compactMap { $0 }
            if (group["name"] as? String)?.hasPrefix("ecy-panel-target-") == true, let filter = group["filter"] as? String,
               filter.count > 2, filter.hasPrefix("^"), filter.hasSuffix("$") {
                names.append(String(filter.dropFirst().dropLast()).replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression))
            }
            return names
        }
    }

    // 节点文件只保留 loaded 里的节点（nil 为全部保留）并把成员名单还原成完整节点，再附上探测节点文件
    static func restrict(_ config: [String: Any], loaded: Set<String>?, probe: [String] = []) -> [String: Any] {
        guard var providers = config["proxy-providers"] as? [String: [String: Any]],
              let source = providers[nodesProvider]?["payload"] as? [[String: Any]] else { return config }
        var nodes: [String: [String: Any]] = [:]
        for node in source { if let name = node["name"] as? String, nodes[name] == nil { nodes[name] = node } }
        for (name, var provider) in providers where name.hasPrefix("ecy-panel-") {
            let kept: [[String: Any]]
            if let names = provider.removeValue(forKey: "members") as? [String] {
                kept = names.filter { loaded?.contains($0) != false }.compactMap { nodes[$0] }
            } else if let loaded, let payload = provider["payload"] as? [[String: Any]] {
                kept = payload.filter { ($0["name"] as? String).map(loaded.contains) == true }
            } else { continue }
            provider["payload"] = kept.isEmpty ? [placeholder] : kept
            providers[name] = provider
        }
        let probed = probe.filter { loaded?.contains($0) == false }.compactMap { nodes[$0] }
        providers[probeProvider] = ["type": "file", "path": probeProvider + ".json", "payload": probed.isEmpty ? [placeholder] : probed]
        var result = config
        result["proxy-providers"] = providers
        return result
    }
}
