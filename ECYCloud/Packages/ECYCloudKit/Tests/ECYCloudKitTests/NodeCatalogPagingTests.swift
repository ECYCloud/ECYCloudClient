import Foundation
import Testing
@testable import ECYCloudKit

// 合成面板：240 个节点，rank 即下标。配置只带各节点文件的前几个，其余经 /config/nodes 取
private actor PagedPanel: HTTPTransport {
    static let even = "ecy-panel-" + String(repeating: "a", count: 64)
    static let templated = "ecy-panel-" + String(repeating: "b", count: 64)
    static let empty = "ecy-panel-" + String(repeating: "c", count: 64)
    static let profile = #"""
    {"id":7,"email":"member@example.test","user_name":"测试账户","class":2,"class_expire":"2099-01-01 00:00:00","expire_in":"2099-01-01 00:00:00",
     "upload":100,"download":300,"transfer_enable":1000,"last_day_t":150,"node_speedlimit":100,"node_connector":3,"online_client_count":1,"money":12.5,
     "traffic_reset":"每月重置","plan":null,"config_revision":"revision-1","api_origin":"https://config.example.test","site_origin":"https://site.example.test"}
    """#

    var stamp = "stamp-1"
    var paged = true
    var failNodes = false
    var failAll = false
    private let total: Int
    private let included: Int

    // included 是配置里带的节点数：最后一个只因为属于偶数节点文件才带上，不在全部节点的前缀里
    init(total: Int = 240, included: Int = 4) { self.total = total; self.included = included }
    private(set) var requests: [(path: String, body: Data, headers: [String: String])] = []

    func setStamp(_ value: String) { stamp = value }
    func setPaged(_ value: Bool) { paged = value }
    func setFailNodes(_ value: Bool) { failNodes = value }
    func setFailAll(_ value: Bool) { failAll = value }
    func bodies(_ path: String) -> [Data] { requests.filter { $0.path == path }.map(\.body) }
    func count(_ path: String) -> Int { requests.count { $0.path == path } }
    func header(_ path: String, _ name: String) -> String? { requests.last { $0.path == path }?.headers[name] }

    static func name(_ rank: Int) -> String { "node-\(rank + 1)" }
    static func label(_ rank: Int) -> String { String(format: "节点 %02d", rank + 1) }
    static func proxy(_ rank: Int) -> [String: Any] { ["name": name(rank), "type": "trojan", "server": "node\(rank + 1).example.test", "port": 443, "password": "synthetic", "udp": true] }
    static func keys(_ rank: Int) -> [String] { rank % 2 == 1 ? ["ecy-panel-nodes", even] : ["ecy-panel-nodes"] }
    private static func entry(_ rank: Int) -> [String: Any] {
        ["name": name(rank), "rank": rank, "label": label(rank), "providers": keys(rank), "proxy": proxy(rank)]
    }

    private func config() -> [String: Any] {
        let all = Array(0..<(paged ? included : total))
        let evens = all.filter { $0 % 2 == 1 }
        let template: [String: Any] = ["name": "模板节点", "type": "ss", "server": "static.example.test", "port": 443, "cipher": "aes-128-gcm", "password": "synthetic"]
        var body: [String: Any] = [
            "revision": "revision-1", "node_labels": Dictionary(uniqueKeysWithValues: all.map { (Self.name($0), Self.label($0)) }),
            "offline_authorization": ["issued_at": Int(Date().timeIntervalSince1970), "valid_until": Int(Date().timeIntervalSince1970) + 86400],
            "config": [
                "proxies": [[String: Any]](),
                "proxy-providers": [
                    "ecy-panel-nodes": ["type": "file", "path": "ecy-panel-nodes.json", "payload": all.map(Self.proxy) + [template]],
                    Self.even: ["type": "file", "path": Self.even + ".json", "members": evens.map(Self.name)],
                    Self.templated: ["type": "file", "path": Self.templated + ".json", "members": ["模板节点"] + evens.map(Self.name)],
                    Self.empty: ["type": "file", "path": Self.empty + ".json", "payload": [["name": "ecy-panel-empty", "type": "reject"]]]
                ],
                "proxy-groups": [
                    ["name": "主节点", "type": "select", "use": ["ecy-panel-nodes"], "default-selected": "node-1"],
                    ["name": "偶数", "type": "url-test", "use": [Self.even]],
                    ["name": "带模板", "type": "select", "use": [Self.templated]],
                    ["name": "空组", "type": "select", "proxies": ["DIRECT"], "use": [Self.empty]],
                    ["name": "GLOBAL", "type": "select", "proxies": ["DIRECT", "主节点"], "use": ["ecy-panel-nodes"]]
                ],
                "rules": ["MATCH,主节点"]
            ] as [String: Any]
        ]
        if paged {
            body["catalog"] = ["stamp": stamp, "providers": [
                "ecy-panel-nodes": ["key": "ecy-panel-nodes", "total": total, "head": included - 1],
                Self.even: ["key": Self.even, "total": total / 2, "head": evens.count],
                Self.templated: ["key": Self.even, "total": total / 2, "head": evens.count],
                Self.empty: ["key": Self.empty, "total": 0, "head": 0]
            ], "ranks": Dictionary(uniqueKeysWithValues: all.map { (Self.name($0), $0) })] as [String: Any]
        } else {
            body["catalog"] = NSNull()
        }
        return body
    }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        let path = request.url!.path.replacingOccurrences(of: "/api/client/v1", with: "")
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        requests.append((path, request.httpBody ?? Data(), request.allHTTPHeaderFields ?? [:]))
        if failAll { throw ClientError.networkFailure(URLError.timedOut.rawValue) }
        func reply(_ value: Any) throws -> HTTPResult {
            HTTPResult(data: try JSONSerialization.data(withJSONObject: ["ret": 1, "data": value]), status: 200)
        }
        switch path {
        case "/auth/login":
            return try reply(["token": "synthetic-token", "expires_at": "2099-01-01T00:00:00+00:00",
                              "user": JSONSerialization.jsonObject(with: Data(Self.profile.utf8))])
        case "/user/account-status":
            return try reply(["enable": 1, "email": "member@example.test", "support_email": "support@example.test"])
        case "/user/profile": return try reply(JSONSerialization.jsonObject(with: Data(Self.profile.utf8)))
        case "/config/clash": return try reply(config())
        case "/config/nodes":
            if failNodes { throw ClientError.networkFailure(URLError.timedOut.rawValue) }
            var ranks: [Int], more = false
            if let names = body["names"] as? [String] {
                ranks = (0..<total).filter { names.contains(Self.name($0)) }
            } else {
                let key = body["provider"] as! String, offset = body["offset"] as! Int, limit = body["limit"] as! Int
                let search = (body["search"] as? String ?? "").lowercased()
                let members = (0..<total).filter { Self.keys($0).contains(key) && (search.isEmpty || Self.label($0).lowercased().contains(search)) }
                ranks = Array(members.dropFirst(offset).prefix(limit))
                more = members.count > offset + limit
            }
            return try reply(["stamp": stamp, "more": more, "nodes": ranks.map(Self.entry)])
        default:
            Issue.record("收到未预期的请求：\(path)")
            throw ClientError.network
        }
    }
}

@MainActor private final class PagingVault: CredentialVault {
    var logoutPending = false
    var endpoints: PanelEndpoints?
    var value: StoredSession?
    func load() throws -> StoredSession? { value }
    func save(_ session: StoredSession) throws { value = session }
    func clear() throws { value = nil }
    func loadRemembered() throws -> RememberedLogin? { nil }
    func saveRemembered(_ login: RememberedLogin) throws {}
    func clearRemembered() throws {}
}

@Suite("节点目录分页", .timeLimit(.minutes(1)), .isolatedUserData) @MainActor
struct NodeCatalogPagingTests {
    private static let endpoints = try! PanelEndpoints(site: "https://site.example.test", config: "https://config.example.test")
    private static let device = DeviceInfo(id: "synthetic-device", name: "测试设备", model: "iPhone", os: "iOS 17.0", platform: "iOS", version: "0.1.12")
    private static let snapshot = Data(#"{"upload":0,"download":0,"uploadTotal":0,"downloadTotal":0,"connections":[],"total":0,"page":1,"selections":{},"groups":[{"id":"主节点","members":["node-1","node-2","node-3","node-4"],"type":"select"},{"id":"偶数","members":["node-2","node-4"],"type":"url-test"}],"memory":0,"active":0,"closed":0,"mode":"rule"}"#.utf8)

    private func session(_ panel: PagedPanel, driver: RecordingTunnelDriver = RecordingTunnelDriver(), vault: PagingVault = PagingVault(),
                         probes: NodeProbeState? = nil, cache: PanelResponseCache? = nil, login: Bool = true) async -> ClientSession {
        let value = ClientSession(endpoints: Self.endpoints, api: PanelAPI(device: Self.device, transport: panel), vault: vault,
                                  connection: ConnectionController(driver: driver), nodeProbes: probes ?? NodeProbeState(defaults: nil), cache: cache)
        await value.restore()
        if login {
            await value.login(email: "member@example.test", password: "synthetic-password")
            driver.statusChanged?(.connected)
        }
        return value
    }

    private func body(_ data: Data?) -> [String: Any] {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    private func group(_ value: ClientSession, _ id: String) throws -> NodeSelectionGroup {
        try #require(value.catalog?.groups.first { $0.id == id })
    }

    private func providers(_ lease: TunnelLease) throws -> [String: [String]] {
        let config = try JSONSerialization.jsonObject(with: lease.configuration) as! [String: Any]
        return (config["proxy-providers"] as! [String: [String: Any]]).mapValues { ($0["payload"] as? [[String: Any]] ?? []).map { $0["name"] as! String } }
    }

    @Test func insertingKeepsUnrankedMembersInPlace() {
        let ranks = ["a": 5, "b": 90]
        func merged(_ added: [(Int, String)], into list: [String]) -> [String] { NodeWorkingSet.inserting(added, into: list) { ranks[$0] } }
        #expect(merged([(50, "x")], into: ["左", "a", "b", "右"]) == ["左", "a", "x", "b", "右"])
        #expect(merged([(100, "z"), (1, "y")], into: ["左", "a", "b", "右"]) == ["左", "y", "a", "b", "z", "右"])
        #expect(merged([(7, "y"), (6, "x")], into: ["左", "右"]) == ["左", "右", "x", "y"])
        #expect(merged([], into: ["a"]) == ["a"])
    }

    @Test func pagedCatalogDeclaresBudgetAndKnowsWhatTheConfigLacks() async throws {
        let panel = PagedPanel(), value = await session(panel)
        #expect(await panel.header("/config/clash", "X-ECY-Node-Catalog") == String(NodeWorkingSet.copyBudget))
        #expect(await panel.count("/config/nodes") == 0)
        let catalog = try #require(value.catalog)
        #expect(catalog.partial && catalog.paging?.stamp == "stamp-1" && catalog.rank("node-4") == 3 && catalog.rank("模板节点") == nil)
        let main = try group(value, "主节点"), even = try group(value, "偶数"), templated = try group(value, "带模板"), empty = try group(value, "空组")
        #expect(main.members == ["node-1", "node-2", "node-3", "node-4", "模板节点"] && value.memberCount(of: main) == 241)
        #expect(value.memberCount(of: even) == 120 && value.memberCount(of: templated) == 121 && value.memberCount(of: empty) == 1)
        #expect(value.hasMoreNodes(main) && value.hasUnlistedNodes(even) && !value.hasMoreNodes(empty) && !value.hasUnlistedNodes(empty))
    }

    @Test func unpagedResponseKeepsLocalBehaviourAndNeverAsksForNodes() async throws {
        let panel = PagedPanel()
        await panel.setPaged(false)
        let driver = RecordingTunnelDriver(); driver.updatesNodes = true
        let value = await session(panel, driver: driver)
        let main = try group(value, "主节点")
        #expect(value.catalog?.paging == nil && value.catalog?.partial == false && main.members.count == 241)
        #expect(!value.hasMoreNodes(main) && !value.hasUnlistedNodes(main) && value.memberCount(of: main) == 241 && value.members(of: main) == main.members)
        try await value.loadMoreNodes(main)
        #expect(try await value.searchNodes(main, query: "节点", offset: 0) == nil)
        try await value.selectActiveNode(group: "主节点", node: "node-30")
        #expect(await panel.count("/config/nodes") == 0 && driver.nodeUpdates.isEmpty && driver.commands.map(\.action) == [.select])
    }

    @Test func pagesAndSearchFillTheBrowseCacheWithoutTouchingTheCatalog() async throws {
        let panel = PagedPanel(), value = await session(panel)
        let main = try group(value, "主节点"), even = try group(value, "偶数")
        try await value.loadMoreNodes(main)
        #expect(NSDictionary(dictionary: body(await panel.bodies("/config/nodes").last))
            == ["provider": "ecy-panel-nodes", "offset": 3, "limit": 100, "search": ""] as NSDictionary)
        // node-4 已在配置里，不进浏览缓存；其余按序号排进已知成员之间，模板节点位置不动
        #expect(value.browsed.nodes.count == 99 && value.browsed.nodes["node-4"] == nil && value.catalog?.node("node-5") == nil)
        #expect(value.members(of: main) == (1...103).map { "node-\($0)" } + ["模板节点"])
        #expect(value.members(of: even) == stride(from: 2, through: 102, by: 2).map { "node-\($0)" } && value.memberCount(of: main) == 241)
        #expect(value.displayName("node-6") == "节点 06" && value.node("node-6")?.protocolName == "Trojan" && value.node("node-6")?.udp == "UDP")
        #expect(value.hasMoreNodes(main) && value.loadingPages.isEmpty)
        try await value.loadMoreNodes(main)
        #expect(body(await panel.bodies("/config/nodes").last)["offset"] as? Int == 103 && value.hasMoreNodes(main))
        try await value.loadMoreNodes(main)
        // 面板说没有更多之后不再翻
        #expect(body(await panel.bodies("/config/nodes").last)["offset"] as? Int == 203 && !value.hasMoreNodes(main) && value.hasUnlistedNodes(main))
        #expect(value.members(of: main) == (1...240).map { "node-\($0)" } + ["模板节点"])
        try await value.loadMoreNodes(main)
        #expect(await panel.count("/config/nodes") == 3)
    }

    @Test func searchAsksThePanelAndPagesByOffset() async throws {
        let panel = PagedPanel(), value = await session(panel), even = try group(value, "偶数")
        #expect(try await value.searchNodes(even, query: "节点 23", offset: 0) == nil)
        #expect(NSDictionary(dictionary: body(await panel.bodies("/config/nodes").last))
            == ["provider": PagedPanel.even, "offset": 0, "limit": 100, "search": "节点 23"] as NSDictionary)
        #expect(value.members(of: even) == ["node-2", "node-4", "node-230", "node-232", "node-234", "node-236", "node-238"])
        #expect(try await value.searchNodes(even, query: "节点", offset: 0) == 100)
        #expect(try await value.searchNodes(even, query: "节点", offset: 100) == nil && value.members(of: even).count == 120)
    }

    @Test func browseCacheDropsTheOldestBeyondItsLimit() {
        var browse = NodeBrowse()
        func node(_ index: Int) -> CatalogNode {
            CatalogNode(node: CloudNode(id: "node-\(index)", name: "", protocolName: "", network: "", tls: "", udp: ""), rank: index, providers: [], proxy: Data())
        }
        browse.insert((1...NodeBrowse.limit).map(node))
        browse.insert([node(1), node(NodeBrowse.limit + 1), node(NodeBrowse.limit + 2)])
        #expect(browse.nodes.count == NodeBrowse.limit && browse.nodes["node-1"] == nil && browse.nodes["node-2"] == nil && browse.nodes["node-3"] != nil)
        browse.remove(["node-3", "node-\(NodeBrowse.limit + 2)"])
        #expect(browse.nodes.count == NodeBrowse.limit - 2 && browse.nodes["node-3"] == nil)
    }

    @Test func changedStampDiscardsTheResultAndRefreshesTheCatalog() async throws {
        let panel = PagedPanel(), value = await session(panel)
        let main = try group(value, "主节点")
        try await value.loadMoreNodes(main)
        #expect(!value.browsed.nodes.isEmpty)
        await panel.setStamp("stamp-2")
        await #expect(throws: CancellationError.self) { try await value.loadMoreNodes(main) }
        #expect(value.browsed.nodes.isEmpty)
        for _ in 0..<100 where value.catalog?.paging?.stamp != "stamp-2" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await panel.count("/config/clash") == 2 && value.catalog?.paging?.stamp == "stamp-2" && value.hasMoreNodes(main))
    }

    @Test func selectedNodesMissingFromTheConfigAreFetchedByNameAndCached() async throws {
        let suite = "paging-\(UUID().uuidString)", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let seed = NodeProbeState(defaults: defaults)
        seed.configure(site: Self.endpoints.site, userID: 7)
        seed.saveSelections(["主节点": "node-30", "带模板": "node-999", "偶数": "node-2"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let panel = PagedPanel(), vault = PagingVault()
        let value = await session(panel, vault: vault, probes: NodeProbeState(defaults: defaults), cache: PanelResponseCache(directory: directory))
        // 只按名取配置里没有的官方节点；面板不认识的名字取不回来，按「选中的节点不存在」丢掉
        #expect(Set(body(await panel.bodies("/config/nodes").first)["names"] as? [String] ?? []) == ["node-30", "node-999"])
        #expect(value.nodeSelections == ["主节点": "node-30"])
        let catalog = try #require(value.catalog)
        #expect(catalog.node("node-30")?.name == "节点 30" && catalog.rank("node-30") == 29)
        #expect(try group(value, "主节点").members == ["node-1", "node-2", "node-3", "node-4", "node-30", "模板节点"])
        #expect(try group(value, "偶数").members == ["node-2", "node-4", "node-30"])
        #expect(try group(value, "带模板").members == ["模板节点", "node-2", "node-4", "node-30"])
        // 并入后的配置才是落盘缓存：面板不可达时重开仍带着选过的节点
        await value.refresh()
        let offline = PagedPanel()
        await offline.setFailAll(true)
        let restored = await session(offline, vault: vault, probes: NodeProbeState(defaults: defaults), cache: PanelResponseCache(directory: directory), login: false)
        #expect(restored.catalog?.node("node-30") != nil && restored.catalog?.paging?.stamp == "stamp-1")
    }

    // 按名取回的请求本身失败时，这次取配置按失败处理：沿用上一份目录与缓存，不能存一份缺了用户选中节点的配置
    @Test func pinnedFetchFailureKeepsThePreviousCatalogAndCache() async throws {
        let suite = "paging-\(UUID().uuidString)", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let seed = NodeProbeState(defaults: defaults)
        seed.configure(site: Self.endpoints.site, userID: 7)
        seed.saveSelections(["主节点": "node-30"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let panel = PagedPanel(), vault = PagingVault()
        await panel.setFailNodes(true)
        let value = await session(panel, vault: vault, probes: NodeProbeState(defaults: defaults), cache: PanelResponseCache(directory: directory))
        #expect(value.catalog == nil && value.nodesError != nil && value.nodeSelections == ["主节点": "node-30"])
        await panel.setFailNodes(false)
        await value.loadNodes()
        #expect(value.catalog?.node("node-30") != nil && value.nodesError == nil)
        await value.refresh()

        // 面板换了目录之后按名取回失败：目录、选择与落盘缓存都还是上一份
        await panel.setStamp("stamp-2")
        await panel.setFailNodes(true)
        await value.loadNodes()
        #expect(value.catalog?.paging?.stamp == "stamp-1" && value.catalog?.node("node-30") != nil && value.nodesError != nil)
        #expect(value.nodeSelections == ["主节点": "node-30"])
        let offline = PagedPanel()
        await offline.setFailAll(true)
        let restored = await session(offline, vault: vault, probes: NodeProbeState(defaults: defaults), cache: PanelResponseCache(directory: directory), login: false)
        #expect(restored.catalog?.paging?.stamp == "stamp-1" && restored.catalog?.node("node-30") != nil)
        // 面板恢复后取到新目录，选中的节点照样补齐
        await panel.setFailNodes(false)
        await value.loadNodes()
        #expect(value.catalog?.paging?.stamp == "stamp-2" && value.catalog?.node("node-30") != nil && value.nodesError == nil)
    }

    @Test func selectingABrowsedNodeMergesItBeforeTheKernelReloads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let panel = PagedPanel(), driver = RecordingTunnelDriver(), vault = PagingVault(); driver.updatesNodes = true
        let value = await session(panel, driver: driver, vault: vault, cache: PanelResponseCache(directory: directory))
        try await value.loadMoreNodes(try group(value, "主节点"))
        let fetched = await panel.count("/config/nodes")
        driver.controlResponses = [Self.snapshot]
        try await value.selectActiveNode(group: "主节点", node: "node-6")
        // 浏览缓存里有内容，不必再问面板；并入后才重读节点文件、再选中，内核不重启
        #expect(await panel.count("/config/nodes") == fetched && driver.commands.map(\.action) == [.snapshot, .select] && driver.starts.isEmpty)
        #expect(value.catalog?.node("node-6") != nil && value.browsed.nodes["node-6"] == nil && value.browsed.nodes["node-5"] != nil)
        #expect(value.nodeSelections["主节点"] == "node-6" && value.recentNodes == ["node-6"])
        let loaded = try providers(try #require(driver.nodeUpdates.last))
        #expect(loaded["ecy-panel-nodes"] == ["node-1", "node-2", "node-3", "node-4", "node-6", "模板节点"])
        #expect(loaded[PagedPanel.even] == ["node-2", "node-4", "node-6"] && loaded[PagedPanel.templated] == ["模板节点", "node-2", "node-4", "node-6"])
        #expect(loaded[PagedPanel.empty] == ["ecy-panel-empty"])
        await value.refresh()
        let offline = PagedPanel()
        await offline.setFailAll(true)
        let restored = await session(offline, vault: vault, cache: PanelResponseCache(directory: directory), login: false)
        #expect(restored.catalog?.node("node-6")?.name == "节点 06" && restored.catalog?.rank("node-6") == 5)

        // 只知道名字的节点先按名取
        driver.controlResponses = [Self.snapshot]
        try await value.selectActiveNode(group: "主节点", node: "node-200")
        #expect(body(await panel.bodies("/config/nodes").last)["names"] as? [String] == ["node-200"] && value.catalog?.node("node-200") != nil)
        // 面板取不到时不动内核，也不记选择
        await panel.setFailNodes(true)
        driver.controlResponses = [Self.snapshot]; driver.commands = []
        let updates = driver.nodeUpdates.count
        await #expect(throws: ClientError.self) { try await value.selectActiveNode(group: "主节点", node: "node-199") }
        #expect(driver.commands.isEmpty && driver.nodeUpdates.count == updates && value.nodeSelections["主节点"] == "node-200")
    }

    // 面板按上限下发，已知节点的副本数本来就顶着上限：再并入的待测节点只进探测节点文件，分组用的节点文件不动
    @Test func testingABrowsedNodeMergesItAndUsesTheProbeFile() async throws {
        let included = NodeWorkingSet.copyBudget / 2 + 2
        let panel = PagedPanel(total: NodeWorkingSet.copyBudget * 2, included: included), driver = RecordingTunnelDriver(); driver.updatesNodes = true
        let value = await session(panel, driver: driver)
        try await value.loadMoreNodes(try group(value, "主节点"))
        let target = "node-\(included + 7)"
        #expect(value.browsed.nodes[target] != nil)
        driver.controlResponses = [Self.snapshot, Data(#"{"running":false,"failed":false,"delay":42,"speed":0}"#.utf8)]
        #expect(try await value.measureNode(target, kind: .delay).delay == 42)
        #expect(driver.commands.map(\.action) == [.snapshot, .probe] && value.catalog?.node(target) != nil && value.recentNodes.isEmpty)
        let files = try providers(try #require(driver.nodeUpdates.last))
        #expect(files[NodeWorkingSet.probeProvider] == [target] && files["ecy-panel-nodes"]?.contains(target) == false)
        // 选中才固定装入
        driver.controlResponses = [Self.snapshot]
        try await value.selectActiveNode(group: "主节点", node: target)
        let selected = try providers(try #require(driver.nodeUpdates.last))
        #expect(selected["ecy-panel-nodes"]?.contains(target) == true && selected[NodeWorkingSet.probeProvider] == ["ecy-panel-empty"] && driver.starts.isEmpty)
    }

    @Test func groupTestCoversListedMembersOnly() async throws {
        let panel = PagedPanel(), driver = RecordingTunnelDriver(); driver.updatesNodes = true
        let value = await session(panel, driver: driver)
        let even = try group(value, "偶数")
        try await value.loadMoreNodes(even)
        let listed = stride(from: 2, through: 204, by: 2).map { "node-\($0)" }
        #expect(value.members(of: even) == listed && value.hasMoreNodes(even))
        let fetched = await panel.count("/config/nodes")
        let done = Data(#"{"running":false,"failed":false,"delay":9,"speed":0}"#.utf8)
        driver.controlResponses = [Self.snapshot] + Array(repeating: done, count: listed.count + 1)
        _ = try await value.measureGroup(even, selections: [:], kind: .delay)
        // 不为测试去翻完整个分组，也不再问面板；浏览缓存里的 100 个先并入再测
        #expect(await panel.count("/config/nodes") == fetched && value.hasMoreNodes(even) && value.browsed.nodes.isEmpty)
        #expect(Set(driver.commands.filter { $0.action == .probe && $0.scope == "delay" }.map(\.node)) == Set(listed))
        #expect(Set(try providers(try #require(driver.nodeUpdates.last))[PagedPanel.even] ?? []) == Set(listed))
    }

    // 待测节点没能装进内核时没有测量结果：徽标给出失败，而不是点了测试毫无反应
    @Test func probeLoadFailureMarksTheNodesFailed() async throws {
        let panel = PagedPanel(), driver = RecordingTunnelDriver(); driver.updatesNodes = true
        let value = await session(panel, driver: driver)
        try await value.loadMoreNodes(try group(value, "主节点"))
        driver.updatesNodes = false
        driver.controlResponses = [Self.snapshot]
        await #expect(throws: TunnelError.control) { try await value.measureNode("node-7", kind: .delay) }
        #expect(value.nodeProbes.result("node-7", kind: .delay)?.failed == true && value.nodeProbes.testing.isEmpty)
    }

    @Test func mergeFollowsRanksKeysAndPlaceholders() async throws {
        let panel = PagedPanel(), value = await session(panel)
        let catalog = try #require(value.catalog)
        func fetched(_ rank: Int, keys: [String]) throws -> CatalogNode {
            let proxy = PagedPanel.proxy(rank)
            return CatalogNode(node: try #require(NodeCatalog.cloudNode(proxy, label: PagedPanel.label(rank))), rank: rank, providers: keys,
                               proxy: try JSONSerialization.data(withJSONObject: proxy))
        }
        let merged = try catalog.merging([try fetched(20, keys: ["ecy-panel-nodes", PagedPanel.empty]), try fetched(1, keys: ["ecy-panel-nodes", PagedPanel.even]),
                                          try fetched(10, keys: ["ecy-panel-nodes"]), try fetched(20, keys: ["ecy-panel-nodes"])])
        let root = try JSONSerialization.jsonObject(with: merged.response) as! [String: Any], body = root["data"] as! [String: Any]
        let files = (body["config"] as! [String: Any])["proxy-providers"] as! [String: [String: Any]]
        // 已在配置里的 node-2 不重复并入；占位节点在并入真实节点后去掉；按名单下发的节点文件仍是名单
        #expect((files["ecy-panel-nodes"]!["payload"] as! [[String: Any]]).map { $0["name"] as! String } == ["node-1", "node-2", "node-3", "node-4", "node-11", "node-21", "模板节点"])
        #expect((files[PagedPanel.empty]!["payload"] as! [[String: Any]]).map { $0["name"] as! String } == ["node-21"])
        #expect(files[PagedPanel.even]!["members"] as? [String] == ["node-2", "node-4"] && files[PagedPanel.even]!["payload"] == nil)
        #expect((body["node_labels"] as! [String: String])["node-21"] == "节点 21" && ((body["catalog"] as! [String: Any])["ranks"] as! [String: Int])["node-11"] == 10)
        #expect(root["ret"] as? Int == 1 && merged.catalog.revision == catalog.revision && merged.catalog.node("node-21")?.name == "节点 21")
        try merged.catalog.validate()
        #expect(merged.catalog.groups.first { $0.id == "空组" }?.members == ["DIRECT", "node-21"])
    }

    // 全局模式的分组同样按目录列出、可翻页：面板在节点文件形态下总会补上 GLOBAL 分组
    @Test func globalModeListsTheCatalogAndPagesLikeOtherGroups() async throws {
        let panel = PagedPanel(), value = await session(panel)
        let catalog = try #require(value.catalog)
        let live = [NodeSelectionGroup(id: "GLOBAL", members: ["DIRECT", "主节点", "node-1"], type: "select")]
        let global = try #require(catalog.groups(for: .global, runtime: live).first)
        #expect(global.members == ["DIRECT", "主节点", "node-1", "node-2", "node-3", "node-4", "模板节点"] && value.memberCount(of: global) == 243)
        // 目录刚换新、内核还没重读时，内核报告的成员比目录多：总数仍按目录算
        let stale = NodeSelectionGroup(id: "GLOBAL", members: ["DIRECT", "主节点"] + (1...90).map { "node-\($0 + 500)" }, type: "select")
        let shown = try #require(catalog.groups(for: .global, runtime: [stale]).first)
        #expect(value.memberCount(of: shown) == 243 && shown.members == global.members)
        try await value.loadMoreNodes(global)
        #expect(value.members(of: global).contains("node-8") && value.hasMoreNodes(global))
    }

    @Test func malformedCatalogOrNodesAreRejected() async throws {
        func catalog(_ listing: String) throws -> NodeCatalog {
            try NodeCatalog(response: Data(#"{"ret":1,"data":{"revision":"r","config":{"proxies":[],"proxy-providers":{"ecy-panel-nodes":{"type":"file","path":"ecy-panel-nodes.json","payload":[{"name":"node-1","type":"ss"}]}},"proxy-groups":[{"name":"主节点","type":"select","use":["ecy-panel-nodes"]}],"rules":["MATCH,主节点"]},"node_labels":{},"catalog":\#(listing)}}"#.utf8))
        }
        #expect(try catalog("null").paging == nil)
        #expect(try catalog(#"{"stamp":"s","providers":{"ecy-panel-nodes":{"key":"ecy-panel-nodes","total":9,"head":1}},"ranks":[]}"#).paging?.pages["主节点"]?.first?.known == 0)
        for listing in [#"{"stamp":"","providers":{},"ranks":{}}"#, #"{"stamp":"s","providers":[],"ranks":{}}"#, #"{"stamp":"s","providers":{},"ranks":["x"]}"#,
                        #"{"stamp":"s","providers":{"ecy-panel-nodes":{"key":"","total":9,"head":1}},"ranks":{}}"#,
                        #"{"stamp":"s","providers":{"ecy-panel-nodes":{"key":"k","total":-1,"head":1}},"ranks":{}}"#] {
            #expect(throws: ClientError.invalidResponse) { try catalog(listing) }
        }
    }
}
