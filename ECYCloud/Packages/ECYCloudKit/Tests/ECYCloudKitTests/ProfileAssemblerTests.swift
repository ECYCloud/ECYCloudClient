import Foundation
import Testing
@testable import ECYCloudKit

@Suite("内核配置装配")
struct ProfileAssemblerTests {
    private let remote = Data(#"""
    {"proxies":[{"name":"synthetic-node","type":"ss","server":"192.0.2.1","port":443,"cipher":"aes-128-gcm","password":"synthetic-password","extra_test_key":"preserve"}],
     "proxy-groups":[{"name":"synthetic-group","type":"select","proxies":["synthetic-node","DIRECT"]}],"rules":["MATCH,synthetic-group"],
     "dns":{"enable":true,"enhanced-mode":"fake-ip","nameserver":["https://dns.example.test/dns-query"],"listen":"0.0.0.0:1053","ipv6":true},
     "ntp":{"enable":false,"write-to-system":true},"port":7890,"socks-port":7891,"redir-port":7892,"tproxy-port":7893,
     "secret":"remote-secret","external-controller":"0.0.0.0:9090","external-controller-unix":"/tmp/unsafe",
     "external-ui-url":"https://example.test/archive.zip","external-doh-server":"/dns-query","authentication":["unexpected:secret"],
     "listeners":[{"name":"unexpected","type":"mixed","port":7777}],"tunnels":[{"target":"192.0.2.2:80"}],
     "hosts":{"example.test":"192.0.2.3"}}
    """#.utf8)
    private var options: ProfileOptions { .init(mixedPort: 30000, controllerPort: 30002, secret: String(repeating: "s", count: 32)) }
    private func json(_ data: Data) throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]) }

    @Test func packetFlowHasNoNetworkListenersOrPersistentSelections() throws {
        let assembled = try ProfileAssembler.assemble(remote, options: .packetFlow)
        let result = try json(assembled.data)
        for key in ["mixed-port", "port", "socks-port", "redir-port", "tproxy-port"] { #expect(result[key] as? Int == 0) }
        for key in ["external-controller", "secret"] { #expect(result[key] as? String == "") }
        #expect((result["listeners"] as? [Any])?.isEmpty == true)
        #expect((result["tunnels"] as? [Any])?.isEmpty == true)
        #expect((result["tun"] as? [String: Any])?["enable"] as? Bool == false)
        #expect((result["tun"] as? [String: Any])?["auto-route"] as? Bool == false)
        #expect((result["tun"] as? [String: Any])?["dns-hijack"] as? [String] == [])
        #expect(result["log-level"] as? String == "silent")
        #expect((result["profile"] as? [String: Bool]) == ["store-selected": false, "store-fake-ip": false])
        #expect((result["proxy-groups"] as? [[String: Any]])?.contains { $0["name"] as? String == "ecy-speed" } == false)
    }

    @Test func closesUnownedPortsAndPreservesPanelRulesAndDNS() throws {
        let value = try ProfileAssembler.assemble(remote, options: options)
        #expect(!String(decoding: value.data, as: UTF8.self).contains(#"\/"#))
        #expect(!String(decoding: value.validationData, as: UTF8.self).contains(#"\/"#))
        let result = try json(value.data), original = try json(remote)
        for key in ["port", "socks-port", "redir-port", "tproxy-port"] { #expect(result[key] as? Int == 0) }
        for key in ["external-controller-unix", "external-controller-tls", "external-controller-pipe", "external-ui", "external-ui-url", "external-doh-server"] { #expect(result[key] as? String == "") }
        #expect(result["external-controller"] as? String == "127.0.0.1:30002")
        #expect(result["secret"] as? String == options.secret)
        #expect((result["authentication"] as? [String])?.isEmpty == true)
        #expect((result["tunnels"] as? [Any])?.isEmpty == true)
        #expect(NSDictionary(dictionary: result["hosts"] as! [String: Any]) == NSDictionary(dictionary: original["hosts"] as! [String: Any]))
        #expect(result["rules"] as? [String] == original["rules"] as? [String])
        let dns = try #require(result["dns"] as? [String: Any])
        #expect(dns["nameserver"] as? [String] == ["https://dns.example.test/dns-query"])
        #expect(dns["listen"] as? String == "" && dns["ipv6"] as? Bool == false)
        #expect((result["ntp"] as? [String: Any])?["write-to-system"] as? Bool == false)
        #expect(value.usesFakeIP && value.remoteProviderCount == 0)
        let listeners = try #require(result["listeners"] as? [[String: Any]])
        #expect(listeners.count == 1 && listeners[0]["listen"] as? String == "127.0.0.1")
        let users = try #require(listeners[0]["users"] as? [[String: String]])
        #expect(users.count == 1 && users[0]["username"] == "ecy-speed" && users[0]["password"]?.count == 64)
    }

    @Test func preservesProviderDataAndKeepsValidationFromWritingFakeIPCache() throws {
        var source = try json(remote)
        let nodes = source["proxies"]!
        source["proxies"] = [Any]()
        source["proxy-providers"] = ["ecy-panel-nodes": ["type": "file", "path": "ecy-panel-nodes.json", "payload": nodes]]
        source["proxy-groups"] = [["name": "synthetic-group", "type": "select", "use": ["ecy-panel-nodes"]]]
        let value = try ProfileAssembler.assemble(JSONSerialization.data(withJSONObject: source), options: options, selections: ["synthetic-group": "synthetic-node"])
        let result = try json(value.data), validation = try json(value.validationData)
        let providers = try #require(result["proxy-providers"] as? [String: [String: Any]])
        #expect(providers["ecy-panel-nodes"]?["type"] as? String == "file")
        #expect((validation["proxy-providers"] as? [String: [String: Any]])?["ecy-panel-nodes"]?["type"] as? String == "inline")
        #expect((result["profile"] as? [String: Bool])?["store-selected"] == false)
        #expect((result["profile"] as? [String: Bool])?["store-fake-ip"] == true)
        #expect((validation["profile"] as? [String: Bool])?["store-fake-ip"] == false)
        #expect((result["proxy-groups"] as? [[String: Any]])?.first?["default-selected"] as? String == "synthetic-node")
    }

    @Test func unknownSelectionDoesNotInventSelectedNode() throws {
        let value = try ProfileAssembler.assemble(remote, options: options, selections: ["synthetic-group": "missing"])
        let result = try json(value.data)
        #expect((result["proxy-groups"] as? [[String: Any]])?.first?["default-selected"] == nil)
        #expect((result["profile"] as? [String: Bool])?["store-selected"] == true)
    }

    @Test(arguments: ["../config.json", "/tmp/rules", "rules/../config.json", "config.json.backup", "cache.db", "./GeoSite.dat", ".validate-a/rules", "a\\b", "a/", "a//b", "a/con.txt", "a/b.", "a/b ", "a:b"])
    func rejectsProviderTraversalAndReservedFiles(path: String) throws {
        #expect(!ProfileAssembler.safeProviderPath(path))
        var source = try json(remote)
        source["rule-providers"] = ["test": ["type": "http", "path": path, "url": "https://example.test/rules", "behavior": "domain", "format": "mrs"]]
        #expect(throws: ProfileValidationError.self) { try ProfileAssembler.assemble(JSONSerialization.data(withJSONObject: source), options: options) }
    }

    @Test func rejectsMissingCrossReferencesAndUnsafeControllerOptions() throws {
        var source = try json(remote)
        source["rules"] = ["RULE-SET,missing,missing-target", "MATCH,missing-target"]
        #expect(throws: ProfileValidationError.self) { try ProfileAssembler.assemble(JSONSerialization.data(withJSONObject: source), options: options) }
        var unsafe = options
        unsafe.controllerPort = 30001
        #expect(throws: ClientError.configuration) { try ProfileAssembler.assemble(remote, options: unsafe) }
        unsafe = options; unsafe.secret = "short"
        #expect(throws: ClientError.configuration) { try ProfileAssembler.assemble(remote, options: unsafe) }
    }

    @Test func selectableGroupsUseProviderMembersAndPreserveIdentifiers() throws {
        var source = try json(remote)
        let payload = source["proxies"]!
        source["proxies"] = [Any]()
        source["proxy-providers"] = ["ecy-panel-nodes": ["type": "file", "path": "ecy-panel-nodes.json", "payload": payload]]
        source["proxy-groups"] = [["name": "synthetic-group", "type": "select", "proxies": ["DIRECT"], "use": ["ecy-panel-nodes"]]]
        let envelope: [String: Any] = ["revision": "synthetic", "config": source, "node_labels": ["synthetic-node": "合成显示名"], "group_labels": ["synthetic-group": "合成分组"]]
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let catalog = try decoder.decode(NodeCatalog.self, from: JSONSerialization.data(withJSONObject: envelope))
        #expect(catalog.selectionGroups.count == 1)
        #expect(catalog.selectionGroups[0].members == ["DIRECT", "synthetic-node"])
        #expect(catalog.nodes[0].id == "synthetic-node" && catalog.nodes[0].name == "合成显示名")
        #expect(catalog.mainGroupID == "synthetic-group" && catalog.displayName("synthetic-group") == "合成分组")
        let result = try json(catalog.assemble(options: .packetFlow, selections: ["synthetic-group": "synthetic-node"]).data)
        #expect((result["proxy-groups"] as? [[String: Any]])?.first?["default-selected"] as? String == "synthetic-node")
        #expect((result["proxy-providers"] as? [String: [String: Any]])?["ecy-panel-nodes"]?["type"] as? String == "inline")
    }

    @Test func nodeCatalogRetainsConfigurationKeysForAssembly() throws {
        let envelope: [String: Any] = ["revision": "synthetic", "config": try json(remote), "node_labels": [String: String]()]
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let catalog = try decoder.decode(NodeCatalog.self, from: JSONSerialization.data(withJSONObject: envelope))
        let result = try json(catalog.assemble(options: options).data)
        #expect((result["proxies"] as? [[String: Any]])?.first?["extra_test_key"] as? String == "preserve")
        #expect((result["proxies"] as? [[String: Any]])?.first?["password"] as? String == "synthetic-password")
    }

    @Test func nodeTagsMatchFlutterLabels() throws {
        let nodes: [[String: Any]] = [
            ["name": "node-1", "type": "vless", "network": "ws", "reality-opts": ["public-key": "synthetic"], "packet-encoding": "xudp"],
            ["name": "node-2", "type": "ss", "udp": true],
            ["name": "node-3", "type": "hysteria2", "reality-opts": [String: Any]()],
            ["name": "node-4", "type": "future-protocol", "tls": true]
        ]
        let envelope: [String: Any] = ["revision": "synthetic", "config": ["proxies": nodes], "node_labels": [String: String]()]
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let catalog = try decoder.decode(NodeCatalog.self, from: JSONSerialization.data(withJSONObject: envelope))
        #expect(catalog.nodes.map { [$0.protocolName, $0.network, $0.tls, $0.udp] } == [
            ["VLESS", "WS", "REALITY", "XUDP"], ["Shadowsocks", "", "", "UDP"], ["Hysteria2", "", "TLS", ""], ["future-protocol", "", "TLS", ""]
        ])
    }

    @Test func catalogShowsAutomaticGroupsWithoutInventingRuntimeSelections() throws {
        var source = try json(remote)
        source["proxy-groups"] = [
            ["name": "manual", "type": "select", "proxies": ["automatic", "DIRECT"]],
            ["name": "automatic", "type": "url-test", "proxies": ["synthetic-node"]],
            ["name": "hidden", "type": "select", "hidden": true, "proxies": ["synthetic-node"]]
        ]
        let envelope: [String: Any] = ["revision": "synthetic", "config": source, "node_labels": [String: String]()]
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let catalog = try decoder.decode(NodeCatalog.self, from: JSONSerialization.data(withJSONObject: envelope))
        #expect(catalog.groups.map(\.id) == ["manual", "automatic"])
        #expect(catalog.selectionGroups.map(\.id) == ["manual"])
        #expect(catalog.groups(for: .direct).isEmpty)
        #expect(catalog.groups(for: .global).isEmpty)
        let runtime = [NodeSelectionGroup(id: "GLOBAL", members: ["DIRECT", "manual"], type: "select")]
        #expect(catalog.groups(for: .global, runtime: runtime).first?.members == ["DIRECT", "manual"])
    }
}
