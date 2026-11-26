//go:build android && cmfa

package mihomo

import "github.com/metacubex/mihomo/dns"

func updateSystemDNS(servers []string) {
	dns.UpdateSystemDNS(servers)
}
