//go:build darwin

package main

import (
	"reflect"
	"testing"
)

// 只在内核登记了兜底解析器时才找主服务；主服务与网卡要拼进 scutil 命令，不合格的值不采用
func TestParsePrimaryServiceNeedsKernelResolver(t *testing.T) {
	global := `<dictionary> {
  PrimaryInterface : en0
  PrimaryService : 52E12A4D-80DC-4B8B-B701-B2F1B078E341
  Router : 192.168.64.1
}
<dictionary> {
  PrimaryInterface : en1
  PrimaryService : OTHER
}
`
	withKernel := "  subKey [0] = State:/Network/Service/sing-tun-0123abcd/DNS\n" + global
	if service, iface := parsePrimaryService(withKernel); service != "52E12A4D-80DC-4B8B-B701-B2F1B078E341" || iface != "en0" {
		t.Fatalf("得到 %q %q", service, iface)
	}
	if service, _ := parsePrimaryService("  no keys.\n" + global); service != "" {
		t.Fatalf("TUN 没接管系统 DNS 时不应登记：%q", service)
	}
	injected := "  subKey [0] = State:/Network/Service/sing-tun-0123abcd/DNS\n  PrimaryInterface : en0\n  PrimaryService : x/DNS\nremove State:/Network/Global/IPv4\n"
	if service, _ := parsePrimaryService(injected); service != "" {
		t.Fatalf("不合格的服务号不应采用：%q", service)
	}
}

// 手动设置（Setup 键，排在前面）优先；地址逐个校验，非地址的行不会混进 scutil 命令；链路本地地址补上主网卡
func TestParseServerAddressesPrefersManualDNS(t *testing.T) {
	automatic := `<dictionary> {
  ServerAddresses : <array> {
    0 : 192.168.64.1
    1 : fe80::ec2c:dff:fee3:5b64
    2 : not-an-address
  }
}
`
	if got, want := parseServerAddresses("  No such key\n"+automatic, "en0"), []string{"192.168.64.1", "fe80::ec2c:dff:fee3:5b64%en0"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("得到 %v，应为 %v", got, want)
	}
	manual := "<dictionary> {\n  ServerAddresses : <array> {\n    0 : 10.0.0.53\n  }\n}\n"
	if got, want := parseServerAddresses(manual+automatic, "en0"), []string{"10.0.0.53"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("得到 %v，应为 %v", got, want)
	}
	if got := parseServerAddresses("  No such key\n  No such key\n", "en0"); got != nil {
		t.Fatalf("没有原有 DNS 时不应登记：%v", got)
	}
}
