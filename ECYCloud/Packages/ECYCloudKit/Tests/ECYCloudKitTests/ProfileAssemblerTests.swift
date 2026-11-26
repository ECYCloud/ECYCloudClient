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

    #if os(macOS)
    // macOS 由 helper 的内核建 TUN，要显式接管系统 DNS；包隧道的 DNS 由系统扩展下发
    @Test func macTunTakesOverSystemDNSOnlyOutsidePacketFlow() throws {
        let helper = try json(ProfileAssembler.assemble(remote, options: options).data)
        let packet = try json(ProfileAssembler.assemble(remote, options: .packetFlow).data)
        #expect((helper["tun"] as? [String: Any])?["dns-mode"] as? String == "hijack")
        #expect((packet["tun"] as? [String: Any])?["dns-mode"] == nil)
    }
    #endif

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

    // 组网类出站会让内核加入外部 P2P 网络、开监听口或充当出口节点
    @Test(arguments: ["easytier", "ZeroTier", " tailscale "])
    func rejectsMeshNetworkOutbounds(type: String) throws {
        var source = try json(remote)
        source["proxies"] = (source["proxies"] as! [[String: Any]]) + [["name": "mesh", "type": type]]
        #expect(throws: ProfileValidationError.self) { try ProfileAssembler.assemble(JSONSerialization.data(withJSONObject: source), options: options) }
        var provided = try json(remote)
        provided["proxy-providers"] = ["ecy-panel-nodes": ["type": "file", "path": "ecy-panel-nodes.json",
                                                           "payload": [["name": "synthetic-node", "type": "ss"], ["name": "hidden", "type": type]]]]
        #expect(throws: ProfileValidationError.self) { try ProfileAssembler.assemble(JSONSerialization.data(withJSONObject: provided), options: options) }
    }

    @Test(arguments: ["../config.json", "/tmp/rules", "rules/../config.json", "config.json.backup", "cache.db", "./GeoSite.dat", ".validate-a/rules", "a\\b", "a/", "a//b", "a/con.txt", "a/b.", "a/b ", "a:b"])
    func rejectsProviderTraversalAndReservedFiles(path: String) throws {
        #expect(!ProfileAssembler.safeProviderPath(path))
        var source = try json(remote)
        source["rule-providers"] = ["test": ["type": "http", "path": path, "url": "https://example.test/rules", "behavior": "domain", "format": "mrs"]]
        #expect(throws: ProfileValidationError.self) { try ProfileAssembler.assemble(JSONSerialization.data(withJSONObject: source), options: options) }
    }

    // 只检查不改写：明文 http 整份拒绝，https 与没有地址的本地 provider 照常通过；内核取 url 不分大小写
    @Test func rejectsPlaintextDownloadSourcesAndKeepsPanelValues() throws {
        func issues(_ source: [String: Any]) throws -> [String] {
            do { _ = try ProfileAssembler.assemble(JSONSerialization.data(withJSONObject: source), options: options); return [] }
            catch let error as ProfileValidationError { return error.issues }
        }
        var source = try json(remote)
        source["geox-url"] = ["mmdb": "https://example.test/geoip.metadb", "geosite": "HTTPS://example.test/GeoSite.dat", "asn": ""]
        source["rule-providers"] = ["remote": ["type": "http", "path": "rules/remote.mrs", "url": "https://example.test/remote.mrs", "behavior": "domain", "format": "mrs"],
                                    "local": ["type": "file", "path": "rules/local.yaml", "behavior": "classical"]]
        let accepted = try json(ProfileAssembler.assemble(JSONSerialization.data(withJSONObject: source), options: options).data)
        #expect((accepted["geox-url"] as? [String: String])?["geosite"] == "HTTPS://example.test/GeoSite.dat")
        #expect((accepted["rule-providers"] as? [String: [String: Any]])?["remote"]?["url"] as? String == "https://example.test/remote.mrs")
        for (key, value) in [("geox-url", ["geoip": "http://example.test/geoip.dat"] as [String: Any]),
                             ("rule-providers", ["remote": ["type": "http", "path": "rules/remote.mrs", "url": " HTTP://example.test/remote.mrs", "behavior": "domain"]]),
                             ("rule-providers", ["remote": ["type": "http", "path": "rules/remote.mrs", "url": "https://example.test/remote.mrs", "URL": "http://example.test/remote.mrs", "behavior": "domain"]]),
                             ("proxy-providers", ["sub": ["type": "http", "path": "sub.yaml", "url": "http://example.test/sub.yaml"]])] {
            var unsafe = try json(remote)
            unsafe[key] = value
            let found = try issues(unsafe)
            #expect(found == [key == "geox-url" ? L10n.t("geox-url「{0}」必须使用 https", ["geoip"]) : L10n.t("规则或节点提供器的下载地址必须使用 https")], "\(key): \(found)")
        }
    }

    // 修复前只认小写 path：PATH、Path 写法能绕过保留文件名检查，覆盖运行目录里的客户端文件；变体合法时照常放行
    @Test func providerPathAndURLKeysAreCheckedCaseInsensitively() throws {
        func issues(_ provider: [String: Any]) throws -> [String] {
            var source = try json(remote)
            source["rule-providers"] = ["test": provider]
            do { _ = try ProfileAssembler.assemble(JSONSerialization.data(withJSONObject: source), options: options); return [] }
            catch let error as ProfileValidationError { return error.issues }
        }
        let unsafe = L10n.t("规则或节点保存路径必须位于运行目录内，且不能覆盖客户端文件")
        for provider: [String: Any] in [["type": "http", "behavior": "domain", "url": "https://example.test/a.yaml", "PATH": "./config.json"],
                                        ["type": "http", "behavior": "domain", "url": "https://example.test/a.yaml", "path": "rules/a.yaml", "Path": "CACHE.DB"],
                                        ["type": "http", "behavior": "domain", "URL": "https://example.test/a.yaml", "pAtH": "../outside.yaml"]] {
            #expect(try issues(provider).contains(unsafe), "\(provider)")
        }
        #expect(try issues(["type": "http", "behavior": "domain", "URL": "https://example.test/a.yaml", "PATH": "Rules/Legit.YAML"]).isEmpty)
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

    @Test func overseasRegionRoutesChinaRulesThroughMatchTarget() throws {
        func rules(_ source: [String], proxyChina: Bool) throws -> [String]? {
            var config = try json(remote)
            config["rules"] = source
            config["rule-providers"] = ["direct": ["type": "file", "path": "rules/direct.yaml", "behavior": "domain"]]
            var value = options
            value.proxyChina = proxyChina
            return try json(ProfileAssembler.assemble(JSONSerialization.data(withJSONObject: config), options: value).data)["rules"] as? [String]
        }
        let source = ["GEOSITE,CN,DIRECT", "GEOIP,cn,DIRECT,no-resolve", "GEOIP, CN, DIRECT", "GEOIP,private,DIRECT", "RULE-SET,direct,DIRECT", "MATCH,synthetic-group"]
        #expect(try rules(source, proxyChina: true) == ["GEOSITE,CN,synthetic-group", "GEOIP,cn,synthetic-group,no-resolve", "GEOIP,CN,synthetic-group",
                                                         "GEOIP,private,DIRECT", "RULE-SET,direct,DIRECT", "MATCH,synthetic-group"])
        #expect(try rules(source, proxyChina: false) == source)
        for unchanged in [["GEOSITE,CN,DIRECT", "FINAL,synthetic-group"], ["GEOSITE,CN,DIRECT", "MATCH, direct"]] {
            #expect(try rules(unchanged, proxyChina: true) == unchanged)
        }
    }

    @Test func selectableGroupsUseProviderMembersAndPreserveIdentifiers() throws {
        var source = try json(remote)
        let payload = source["proxies"]!
        source["proxies"] = [Any]()
        source["proxy-providers"] = ["ecy-panel-nodes": ["type": "file", "path": "ecy-panel-nodes.json", "payload": payload]]
        source["proxy-groups"] = [["name": "synthetic-group", "type": "select", "proxies": ["DIRECT"], "use": ["ecy-panel-nodes"]]]
        let envelope: [String: Any] = ["revision": "synthetic", "config": source, "node_labels": ["synthetic-node": "合成显示名"], "group_labels": ["synthetic-group": "合成分组"]]
        let catalog = try NodeCatalog(envelope)
        #expect(catalog.selectionGroups.count == 1)
        #expect(catalog.selectionGroups[0].members == ["DIRECT", "synthetic-node"])
        #expect(catalog.nodes[0].id == "synthetic-node" && catalog.nodes[0].name == "合成显示名")
        #expect(catalog.mainGroupID == "synthetic-group" && catalog.displayName("synthetic-group") == "合成分组")
        let result = try json(catalog.assemble(options: .packetFlow, selections: ["synthetic-group": "synthetic-node"]).data)
        #expect((result["proxy-groups"] as? [[String: Any]])?.first?["default-selected"] as? String == "synthetic-node")
        #expect((result["proxy-providers"] as? [String: [String: Any]])?["ecy-panel-nodes"]?["type"] as? String == "file")
    }

    @Test func nodeCatalogRetainsConfigurationKeysForAssembly() throws {
        let envelope: [String: Any] = ["revision": "synthetic", "config": try json(remote), "node_labels": [String: String]()]
        let catalog = try NodeCatalog(envelope)
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
        let catalog = try NodeCatalog(envelope)
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
        let catalog = try NodeCatalog(envelope)
        #expect(catalog.groups.map(\.id) == ["manual", "automatic"])
        #expect(catalog.selectionGroups.map(\.id) == ["manual"])
        #expect(catalog.groups(for: .direct).isEmpty)
        #expect(catalog.groups(for: .global).isEmpty)
        let runtime = [NodeSelectionGroup(id: "GLOBAL", members: ["DIRECT", "manual"], type: "select")]
        #expect(catalog.groups(for: .global, runtime: runtime).first?.members == ["DIRECT", "manual"])
    }

    @Test func onlyNodeChangesAllowUpdatingWithoutRestart() throws {
        func lease(nodes: [String], selected: String? = nil, storeSelected: Bool = true, rule: String = "MATCH,synthetic-group") throws -> TunnelLease {
            var group: [String: Any] = ["name": "synthetic-group", "type": "select", "use": ["ecy-panel-nodes"]]
            group["default-selected"] = selected
            let config: [String: Any] = [
                "proxy-providers": ["ecy-panel-nodes": ["type": "file", "path": "ecy-panel-nodes.json",
                                                         "payload": nodes.map { ["name": $0, "type": "ss"] }]],
                "proxy-groups": [group], "rules": [rule], "profile": ["store-selected": storeSelected]
            ]
            return TunnelLease(owner: "owner", expiresAt: .distantFuture, configuration: try JSONSerialization.data(withJSONObject: config))
        }
        let running = try lease(nodes: ["a", "b"])
        #expect(try lease(nodes: ["a"], selected: "a", storeSelected: false).differsOnlyInNodes(from: running))
        #expect(try !lease(nodes: ["a"], rule: "MATCH,DIRECT").differsOnlyInNodes(from: running))
        let other = TunnelLease(owner: "other", expiresAt: .distantFuture, configuration: running.configuration)
        #expect(!other.differsOnlyInNodes(from: running))
    }
}