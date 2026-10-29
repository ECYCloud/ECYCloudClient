import Foundation
import ECYCloudKit
@main struct Generate {
 static func main() throws {
 let data = Data(#"""
{"proxies":[{"name":"synthetic-node","type":"ss","server":"192.0.2.1","port":443,"cipher":"aes-128-gcm","password":"synthetic-password","extra_test_key":"preserve"}],
     "proxy-groups":[{"name":"synthetic-group","type":"select","proxies":["synthetic-node","DIRECT"]}],"rules":["MATCH,synthetic-group"],
     "dns":{"enable":true,"enhanced-mode":"fake-ip","nameserver":["https://dns.example.test/dns-query"],"listen":"0.0.0.0:1053","ipv6":true},
     "ntp":{"enable":false,"write-to-system":true},"port":7890,"socks-port":7891,"redir-port":7892,"tproxy-port":7893,
     "secret":"remote-secret","external-controller":"0.0.0.0:9090","external-controller-unix":"/tmp/unsafe",
     "external-ui-url":"https://example.test/archive.zip","external-doh-server":"/dns-query","authentication":["unexpected:secret"],
     "listeners":[{"name":"unexpected","type":"mixed","port":7777}],"tunnels":[{"target":"192.0.2.2:80"}],
     "hosts":{"example.test":"192.0.2.3"}}
"""#.utf8)
 let result = try ProfileAssembler.assemble(data, options: ProfileOptions(mixedPort: 30000, controllerPort: 30002, secret: String(repeating: "s", count: 32)))
 try result.validationData.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
 let packet = try ProfileAssembler.assemble(data, options: .packetFlow)
 try packet.data.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + ".packet"))
 }
}
