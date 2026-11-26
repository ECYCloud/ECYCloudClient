import CryptoKit
import Foundation
import Testing
@testable import ECYCloudKit

// 对应 app/test/node_working_set_test.dart
@Suite("内核只装在用的节点") struct NodeWorkingSetTests {
    private func node(_ id: Int) -> [String: Any] {
        ["name": "node-\(id)", "type": "ss", "server": "192.0.2.\(id % 250 + 1)", "port": 8000 + id, "cipher": "aes-128-gcm", "password": "test"]
    }
    private func shared(_ key: String) -> String {
        "ecy-panel-" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    // 面板的实际形态：总节点文件、按匹配条件共用且只带成员名单的节点文件、空分组的占位、指向单个节点的规则分组
    private func catalog(_ count: Int) -> [String: Any] {
        let tail = shared("tail"), empty = shared("empty")
        return [
            "proxies": [Any](),
            "proxy-providers": [
                "ecy-panel-nodes": ["type": "file", "path": "ecy-panel-nodes.json", "payload": (1...count).map(node)],
                tail: ["type": "file", "path": tail + ".json", "members": (count / 2 + 1...count).map { "node-\($0)" }],
                empty: ["type": "file", "path": empty + ".json", "payload": [["name": "ecy-panel-empty", "type": "reject"]]]
            ],
            "proxy-groups": [
                ["name": "all", "type": "select", "proxies": ["DIRECT"], "use": ["ecy-panel-nodes"], "default-selected": "node-\(count - 1)"],
                ["name": "tail", "type": "url-test", "proxies": [String](), "use": [tail]],
                ["name": "empty", "type": "select", "proxies": ["DIRECT"], "use": [empty]],
                ["name": "ecy-panel-target-x", "type": "select", "hidden": true, "use": ["ecy-panel-nodes"], "filter": "^node\\-\(count - 3)$"]
            ],
            "rules": ["DOMAIN,pinned.test,ecy-panel-target-x", "MATCH,all"]
        ]
    }
    private func names(_ config: [String: Any], _ provider: String) -> [String] {
        ((config["proxy-providers"] as! [String: [String: Any]])[provider]!["payload"] as! [[String: Any]]).map { $0["name"] as! String }
    }

    @Test func everythingLoadsWithinBudgetAndMemberListsBecomeNodes() {
        let config = catalog(40)
        #expect(NodeWorkingSet.select(config, budget: 60) == nil && !NodeWorkingSet.exceedsBudget(config, budget: 60))
        let kept = NodeWorkingSet.restrict(config, loaded: nil)
        #expect(names(kept, "ecy-panel-nodes").count == 40)
        #expect(names(kept, shared("tail")) == (21...40).map { "node-\($0)" })
        #expect((kept["proxy-providers"] as! [String: [String: Any]])[shared("tail")]?["members"] == nil)
        #expect(names(kept, NodeWorkingSet.probeProvider) == ["ecy-panel-empty"])
    }

    @Test func onlyNodesInUseLoadBeyondBudget() throws {
        let config = catalog(1000)
        #expect(NodeWorkingSet.exceedsBudget(config, budget: 100))
        let loaded = try #require(NodeWorkingSet.select(config, pinned: ["node-777", "不是节点"], budget: 100))
        let kept = NodeWorkingSet.restrict(config, loaded: loaded)
        let copies = names(kept, "ecy-panel-nodes").count + names(kept, shared("tail")).count
        #expect((99...101).contains(copies))
        #expect(Set(names(kept, "ecy-panel-nodes")) == loaded)
        #expect(names(kept, shared("tail")).allSatisfy(loaded.contains))
        #expect(names(kept, shared("empty")) == ["ecy-panel-empty"])
        // 用户选中的、分组默认选中的、规则直接指向的节点一定装入
        #expect(loaded.isSuperset(of: ["node-777", "node-999", "node-997"]))
    }

    @Test func everyProviderKeepsANodeInPanelOrder() throws {
        let config = catalog(1000)
        let kept = NodeWorkingSet.restrict(config, loaded: try #require(NodeWorkingSet.select(config, budget: 8)))
        #expect(names(kept, shared("tail")).first == "node-501")
        let ids = names(kept, "ecy-panel-nodes").map { Int($0.dropFirst(5))! }
        #expect(ids == ids.sorted())
    }

    @Test func selectionIsStableAcrossRuns() {
        let config = catalog(3000)
        #expect(NodeWorkingSet.select(config, pinned: ["node-9"], budget: 500) == NodeWorkingSet.select(config, pinned: ["node-9"], budget: 500))
    }

    @Test func legacyProfilesAreLeftUntouched() {
        let config: [String: Any] = ["proxies": [node(1)], "proxy-groups": [Any]()]
        #expect(NodeWorkingSet.select(config, budget: 0) == nil)
        #expect(NodeWorkingSet.restrict(config, loaded: nil)["proxy-providers"] == nil)
    }

    @Test func probeProviderCarriesOnlyNodesMissingFromTheKernel() throws {
        let config = catalog(1000)
        let loaded = try #require(NodeWorkingSet.select(config, budget: 100))
        let waiting = try #require((1...1000).map { "node-\($0)" }.first { !loaded.contains($0) })
        let kept = NodeWorkingSet.restrict(config, loaded: loaded, probe: [waiting, loaded.first!, "不是节点"])
        #expect(names(kept, NodeWorkingSet.probeProvider) == [waiting])
        // 与 app/lib/domain/config/node_working_set.dart 的 probeProvider 同值，名字须符合 helper 与内核桥接对节点文件的校验
        #expect(NodeWorkingSet.probeProvider == "ecy-panel-" + SHA256.hash(data: Data("ecy-probe".utf8)).map { String(format: "%02x", $0) }.joined())
        #expect(NodeWorkingSet.probeProvider.range(of: #"^ecy-panel-[a-f0-9]{64}$"#, options: .regularExpression) != nil)
    }

    @Test func assemblyLoadsTheWorkingSetAndLetsTheSpeedGroupReachProbedNodes() throws {
        let source = catalog(4000)
        let remote = try JSONSerialization.data(withJSONObject: source)
        let options = ProfileOptions(mixedPort: 30000, controllerPort: 30002, secret: String(repeating: "s", count: 32))
        let value = try ProfileAssembler.assemble(remote, options: options, selections: ["all": "node-3210"], pinned: ["node-2222"], probe: ["node-3900", "node-1"])
        let result = try JSONSerialization.jsonObject(with: value.data) as! [String: Any]
        let validation = try JSONSerialization.jsonObject(with: value.validationData) as! [String: Any]
        let copies = names(result, "ecy-panel-nodes").count + names(result, shared("tail")).count
        #expect((NodeWorkingSet.copyBudget - 1...NodeWorkingSet.copyBudget + 1).contains(copies))
        #expect(Set(names(result, "ecy-panel-nodes")).isSuperset(of: ["node-3210", "node-2222", "node-3999", "node-3997"]))
        #expect(names(result, NodeWorkingSet.probeProvider) == ["node-3900"] && !names(result, "ecy-panel-nodes").contains("node-3900"))
        #expect(names(validation, "ecy-panel-nodes") == names(result, "ecy-panel-nodes"))
        let groups = try #require(result["proxy-groups"] as? [[String: Any]])
        #expect(groups.first { $0["name"] as? String == "all" }?["default-selected"] as? String == "node-3210")
        #expect(groups.last?["use"] as? [String] == ["ecy-panel-nodes", NodeWorkingSet.probeProvider])
        // 移动端内核按文件重读节点：节点文件保持 file，文件还没写出时内核用 payload
        let packet = try JSONSerialization.jsonObject(with: ProfileAssembler.assemble(remote, options: .packetFlow).data) as! [String: Any]
        #expect((packet["proxy-providers"] as! [String: [String: Any]]).values.allSatisfy { $0["type"] as? String == "file" })
    }
}
