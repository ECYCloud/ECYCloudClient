package kernel

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/component/geodata/router"
	C "github.com/metacubex/mihomo/constant"
)

var geoSiteList = regexp.MustCompile(`^[a-z0-9_.-]+$`)

// 配置里只要留下一处 GEOSITE，内核启动校验就会装入 cn 原始表并常驻缓存（geodata.Verify 与 loadGeoSiteMatcherListSF），所以只能整份改写
func convertGeoSite(data []byte, directory string) ([]byte, map[string]string) {
	var config map[string]any
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if decoder.Decode(&config) != nil {
		return data, nil
	}
	lists := map[string]string{}
	usable := true
	note := func(name string) {
		name = strings.TrimSpace(name)
		key := strings.ToLower(name)
		if !geoSiteList.MatchString(key) {
			usable = false
			return
		}
		if _, seen := lists[key]; !seen {
			lists[key] = name
		}
	}
	var ruleLists [][]any
	if rules, ok := config["rules"].([]any); ok {
		ruleLists = append(ruleLists, rules)
	}
	if sets, ok := config["sub-rules"].(map[string]any); ok {
		for _, set := range sets {
			if rules, ok := set.([]any); ok {
				ruleLists = append(ruleLists, rules)
			}
		}
	}
	for _, rules := range ruleLists {
		for _, rule := range rules {
			text, _ := rule.(string)
			fields := strings.Split(text, ",")
			kind := strings.ToUpper(strings.TrimSpace(fields[0]))
			switch {
			case kind == "GEOSITE" && len(fields) >= 3:
				note(fields[1])
			case kind == "GEOSITE" || strings.Contains(strings.ToUpper(text), "GEOSITE") && (kind == "AND" || kind == "OR" || kind == "NOT" || kind == "SUB-RULE"):
				usable = false
			}
		}
	}
	domainLists := func(value string) (names []string, ok bool) {
		if len(value) < 8 || !strings.EqualFold(value[:8], "geosite:") {
			return nil, false
		}
		names = strings.Split(value[8:], ",")
		for _, name := range names {
			note(name)
		}
		return names, true
	}
	dns, _ := config["dns"].(map[string]any)
	sniffer, _ := config["sniffer"].(map[string]any)
	var policies []map[string]any
	var domainArrays [][]any
	for _, key := range []string{"nameserver-policy", "proxy-server-nameserver-policy"} {
		if policy, ok := dns[key].(map[string]any); ok {
			policies = append(policies, policy)
		}
	}
	if values, ok := dns["fake-ip-filter"].([]any); ok {
		domainArrays = append(domainArrays, values)
	}
	for _, key := range []string{"force-domain", "skip-domain"} {
		if values, ok := sniffer[key].([]any); ok {
			domainArrays = append(domainArrays, values)
		}
	}
	for _, policy := range policies {
		for key := range policy {
			domainLists(key)
		}
	}
	for _, values := range domainArrays {
		for _, value := range values {
			text, _ := value.(string)
			domainLists(text)
		}
	}
	if fallback, ok := dns["fallback-filter"].(map[string]any); ok {
		if values, _ := fallback["geosite"].([]any); len(values) > 0 {
			usable = false
		}
	}
	if !usable || len(lists) == 0 {
		return data, nil
	}
	if _, err := os.Stat(C.Path.GeoSite()); err != nil {
		return data, nil
	}
	loader, err := geodata.GetGeoDataLoader(geodata.LoaderName())
	if err != nil {
		return data, nil
	}
	providers, _ := config["rule-providers"].(map[string]any)
	if providers == nil {
		providers = map[string]any{}
	}
	names := map[string]string{}
	display := map[string]string{}
	for key, original := range lists {
		domains, err := loader.LoadGeoSite(key)
		if err != nil {
			return data, nil
		}
		var payload strings.Builder
		for _, domain := range domains {
			switch domain.Type {
			case router.Domain_Domain:
				payload.WriteString("+.")
			case router.Domain_Full:
			default:
				return data, nil
			}
			payload.WriteString(domain.Value)
			payload.WriteByte('\n')
		}
		name := "ecy-geosite-" + key
		for providers[name] != nil {
			name += "-"
		}
		if os.WriteFile(filepath.Join(directory, name+".txt"), []byte(payload.String()), 0600) != nil {
			return data, nil
		}
		providers[name] = map[string]any{"type": "file", "behavior": "domain", "format": "text", "path": "./" + name + ".txt"}
		names[key] = name
		display[name] = original
	}
	ruleSets := func(lists []string) string {
		for i, name := range lists {
			lists[i] = names[strings.ToLower(strings.TrimSpace(name))]
		}
		return "rule-set:" + strings.Join(lists, ",")
	}
	for _, rules := range ruleLists {
		for i, rule := range rules {
			text, _ := rule.(string)
			fields := strings.Split(text, ",")
			if strings.EqualFold(strings.TrimSpace(fields[0]), "GEOSITE") {
				rules[i] = strings.Join(append([]string{"RULE-SET", names[strings.ToLower(strings.TrimSpace(fields[1]))]}, fields[2:]...), ",")
			}
		}
	}
	for _, policy := range policies {
		for key, value := range policy {
			if lists, ok := domainLists(key); ok {
				delete(policy, key)
				policy[ruleSets(lists)] = value
			}
		}
	}
	for _, values := range domainArrays {
		for i, value := range values {
			text, _ := value.(string)
			if lists, ok := domainLists(text); ok {
				values[i] = ruleSets(lists)
			}
		}
	}
	config["rule-providers"] = providers
	var output bytes.Buffer
	encoder := json.NewEncoder(&output)
	encoder.SetEscapeHTML(false)
	if encoder.Encode(config) != nil {
		return data, nil
	}
	return bytes.TrimSuffix(output.Bytes(), []byte("\n")), display
}
