package kernel

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/component/updater"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const MaximumControlBytes = 65536

type controlRequest struct {
	Action       string `json:"action"`
	Page         int    `json:"page"`
	Group        string `json:"group"`
	Node         string `json:"node"`
	ConnectionID string `json:"connectionID"`
	Scope        string `json:"scope"`
	Query        string `json:"query"`
	Level        string `json:"level"`
	Mode         string `json:"mode"`
}
type liveConnection struct {
	ID                string     `json:"id"`
	Network           string     `json:"network"`
	Host              string     `json:"host"`
	Source            string     `json:"source"`
	Destination       string     `json:"destination"`
	IP                string     `json:"ip"`
	Port              string     `json:"port"`
	RemoteDestination string     `json:"remoteDestination"`
	Upload            int64      `json:"upload"`
	Download          int64      `json:"download"`
	Start             time.Time  `json:"start"`
	Chains            []string   `json:"chains"`
	Rule              string     `json:"rule"`
	RulePayload       string     `json:"rulePayload"`
	Process           string     `json:"process"`
	ProcessPath       string     `json:"processPath"`
	Inbound           string     `json:"inbound"`
	ClosedAt          *time.Time `json:"closedAt,omitempty"`
}
type liveGroup struct {
	ID      string   `json:"id"`
	Members []string `json:"members"`
	Type    string   `json:"type"`
}
type liveSnapshot struct {
	Upload        int64             `json:"upload"`
	Download      int64             `json:"download"`
	UploadTotal   int64             `json:"uploadTotal"`
	DownloadTotal int64             `json:"downloadTotal"`
	Connections   []liveConnection  `json:"connections"`
	Total         int               `json:"total"`
	Page          int               `json:"page"`
	Selections    map[string]string `json:"selections"`
	Groups        []liveGroup       `json:"groups"`
	Delays        map[string]uint16 `json:"delays"`
	Memory        uint64            `json:"memory"`
	Active        int               `json:"active"`
	Closed        int               `json:"closed"`
	Mode          string            `json:"mode"`
	Rank          liveRank          `json:"rank"`
}

// 与 app/lib/data/store/traffic_rank_store.dart 同口径：只计走代理的连接增量，按策略组与目标主机累加。
// 两次快照之间的增量交给客户端落盘，取走即清空。
type liveRank struct {
	Groups map[string]int64 `json:"groups"`
	Hosts  map[string]int64 `json:"hosts"`
}

const maximumRankKeys = 256

type connectionHistory struct {
	active  map[string]liveConnection
	closed  []liveConnection
	hosts   map[string]string
	sampled time.Time
	// 首页上传／下载与 Flutter 一致，只统计走代理的流量
	proxyUp, proxyDown, rateUp, rateDown int64
	rank                                 liveRank
}

func (r *liveRank) add(target map[string]int64, key string, bytes int64) {
	if key == "" {
		return
	}
	if _, present := target[key]; !present && len(target) >= maximumRankKeys {
		return
	}
	target[key] += bytes
}

func (h *connectionHistory) drainRank() liveRank {
	rank := h.rank
	if rank.Groups == nil {
		rank = liveRank{Groups: map[string]int64{}, Hosts: map[string]int64{}}
	}
	h.rank = liveRank{Groups: map[string]int64{}, Hosts: map[string]int64{}}
	return rank
}

func (h *connectionHistory) sample() {
	active := map[string]liveConnection{}
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		info := c.Info()
		m := info.Metadata
		chain := append([]string{}, info.Chain...)
		process := m.Process
		if process == "" {
			process = filepath.Base(filepath.ToSlash(m.ProcessPath))
			if process == "." || process == "/" {
				process = ""
			}
		}
		connection := liveConnection{ID: c.ID(), Network: m.NetWork.String(), Host: m.Host,
			Source: m.SourceAddress(), Destination: m.RemoteAddress(), Port: strconv.FormatUint(uint64(m.DstPort), 10),
			RemoteDestination: m.RemoteDst, Upload: info.UploadTotal.Load(), Download: info.DownloadTotal.Load(),
			Start: info.Start, Chains: chain, Rule: info.Rule, RulePayload: info.RulePayload, Process: process,
			ProcessPath: m.ProcessPath, Inbound: m.Type.String()}
		if m.DstIP.IsValid() {
			connection.IP = m.DstIP.String()
		}
		active[c.ID()] = connection
		if _, present := h.hosts[c.ID()]; !present {
			host := m.Host
			if host == "" && m.DstIP.IsValid() {
				host = m.DstIP.String()
			}
			if h.hosts == nil {
				h.hosts = map[string]string{}
			}
			h.hosts[c.ID()] = host
		}
		return true
	})
	h.accumulate(active)
	now := time.Now().UTC()
	for id, connection := range h.active {
		if _, present := active[id]; !present {
			connection.ClosedAt = &now
			h.closed = append(h.closed, connection)
		}
	}
	if len(h.closed) > 1000 {
		h.closed = append([]liveConnection(nil), h.closed[len(h.closed)-1000:]...)
	}
	for id := range h.hosts {
		if _, present := active[id]; !present {
			delete(h.hosts, id)
		}
	}
	h.active = active
}

// 对应 connection_controller.dart 的 _accumulateProxyTraffic：链路首项是落地出站，按内核类型排除不出网的出站。
func (h *connectionHistory) accumulate(active map[string]liveConnection) {
	proxies := tunnel.Proxies()
	lookup := func(name string) C.Proxy {
		if proxy := proxies[name]; proxy != nil {
			return proxy
		}
		for _, provider := range tunnel.Providers() {
			for _, member := range provider.Proxies() {
				if member.Name() == name {
					return member
				}
			}
		}
		return nil
	}
	servers := map[string]bool{}
	for _, provider := range tunnel.Providers() {
		for _, member := range provider.Proxies() {
			if host, _, err := net.SplitHostPort(member.Addr()); err == nil && host != "" {
				servers[strings.ToLower(host)] = true
			}
		}
	}
	for _, proxy := range proxies {
		if host, _, err := net.SplitHostPort(proxy.Addr()); err == nil && host != "" {
			servers[strings.ToLower(host)] = true
		}
	}
	if h.rank.Groups == nil {
		h.rank = liveRank{Groups: map[string]int64{}, Hosts: map[string]int64{}}
	}
	var up, down int64
	for id, connection := range active {
		if len(connection.Chains) == 0 {
			continue
		}
		leaf := lookup(connection.Chains[0])
		if leaf == nil {
			continue
		}
		if _, group := leaf.Adapter().(outboundgroup.ProxyGroup); group {
			continue
		}
		switch strings.ToLower(leaf.Type().String()) {
		case "direct", "reject", "rejectdrop", "compatible", "pass", "dns":
			continue
		}
		previous := h.active[id]
		du, dd := max(0, connection.Upload-previous.Upload), max(0, connection.Download-previous.Download)
		up += du
		down += dd
		if h.sampled.IsZero() || du+dd == 0 {
			continue
		}
		for _, hop := range connection.Chains {
			if proxy := lookup(hop); proxy != nil {
				if _, group := proxy.Adapter().(outboundgroup.ProxyGroup); group {
					h.rank.add(h.rank.Groups, hop, du+dd)
				}
			}
		}
		if host := h.hosts[id]; !servers[strings.ToLower(host)] {
			h.rank.add(h.rank.Hosts, host, du+dd)
		}
	}
	now := time.Now()
	if !h.sampled.IsZero() {
		if seconds := now.Sub(h.sampled).Seconds(); seconds > 0 {
			h.rateUp, h.rateDown = int64(float64(up)/seconds), int64(float64(down)/seconds)
		}
	}
	h.proxyUp += up
	h.proxyDown += down
	h.sampled = now
}

type logEntry struct {
	ID      int64     `json:"id"`
	Time    time.Time `json:"time"`
	Level   string    `json:"level"`
	Message string    `json:"message"`
}
type logBuffer struct {
	mu       sync.Mutex
	entries  []logEntry
	sequence int64
	secrets  []string
	stop     func()
	store    *logStore
}

// 内核连接日志形如 `[TCP] 198.18.0.1:61593(进程) --> 目标`，只带源地址；与 logs_page.dart 同样按源地址回查入站类型
var logSource = regexp.MustCompile(`^\[(?:TCP|UDP)\] (\[[^\]]+\]:\d+|[^\s(]+:\d+)`)
var logURL = regexp.MustCompile(`(?i)[a-z][a-z0-9+.-]*://[^\s<>"']+`)
var logCredential = regexp.MustCompile(`(?i)(password|passwd|token|secret|authorization|api[_-]?key)[=: ]+(?:(?:Bearer|Basic)\s+)?[^\s,;]+`)

func redactLog(text string, secrets []string) string {
	for _, secret := range secrets {
		if secret != "" {
			text = strings.ReplaceAll(text, secret, "[已隐藏]")
		}
	}
	text = logURL.ReplaceAllStringFunc(text, func(raw string) string {
		u, err := url.Parse(raw)
		if err != nil {
			return "[地址已隐藏]"
		}
		u.User = nil
		u.Path = ""
		u.RawPath = ""
		u.RawQuery = ""
		u.Fragment = ""
		return u.String()
	})
	text = logCredential.ReplaceAllString(text, "$1=[已隐藏]")
	runes := []rune(text)
	if len(runes) > 512 {
		text = string(runes[:512])
	}
	return text
}
func newLogBuffer(config []byte) *logBuffer {
	b := &logBuffer{}
	var object any
	_ = json.Unmarshal(config, &object)
	var walk func(any)
	walk = func(value any) {
		switch value := value.(type) {
		case map[string]any:
			for key, item := range value {
				lower := strings.ToLower(key)
				if strings.Contains(lower, "password") || strings.Contains(lower, "passwd") || strings.Contains(lower, "token") || strings.Contains(lower, "secret") || lower == "uuid" || lower == "private-key" || lower == "authorization" {
					if text, ok := item.(string); ok && text != "" {
						b.secrets = append(b.secrets, text)
					}
				}
				walk(item)
			}
		case []any:
			for _, item := range value {
				walk(item)
			}
		}
	}
	walk(object)
	sub := log.Subscribe()
	done := make(chan struct{})
	go func() {
		defer close(done)
		for event := range sub {
			entry := logEntry{Time: time.Now().UTC(), Level: event.Type(), Message: redactLog(event.Payload, b.secrets)}
			b.mu.Lock()
			b.sequence++
			entry.ID = b.sequence
			if len(b.entries) == 2000 {
				copy(b.entries, b.entries[1:])
				b.entries = b.entries[:1999]
			}
			b.entries = append(b.entries, entry)
			b.store.append(entry)
			b.mu.Unlock()
		}
	}()
	b.stop = func() { log.UnSubscribe(sub); <-done; b.store.close() }
	return b
}
func Control(id uint64, data []byte) ([]byte, error) {
	if len(data) == 0 || len(data) > 4096 {
		return nil, ErrConfiguration
	}
	var request controlRequest
	if json.Unmarshal(data, &request) != nil {
		return nil, ErrConfiguration
	}
	lifecycle.Lock()
	defer lifecycle.Unlock()
	if current == nil || current.id != id {
		return nil, ErrStopped
	}
	var value any = map[string]bool{"ok": true}
	switch request.Action {
	case "version":
		value = map[string]string{"version": C.Version}
	case "logging":
		if !validLogLevel(request.Level) {
			return nil, ErrConfiguration
		}
		current.logs.mu.Lock()
		if request.Group != "" {
			if !logOwnerPattern.MatchString(request.Group) || (current.logs.store != nil && filepath.Base(current.logs.store.directory) != request.Group) {
				current.logs.mu.Unlock()
				return nil, ErrConfiguration
			}
			if current.logs.store == nil {
				current.logs.store = newLogStore(request.Group, request.Level, current.directory)
			}
		}
		if current.logs.store != nil {
			current.logs.store.level = request.Level
		}
		current.logs.mu.Unlock()
	case "rules":
		if request.Scope == "content" {
			path, ok := current.rules[request.Group]
			if !ok || request.Page < 1 || request.Page > 512 {
				return nil, ErrConfiguration
			}
			root, err := os.OpenRoot(current.directory)
			if err != nil {
				return nil, err
			}
			defer root.Close()
			file, err := root.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
			if err != nil {
				return nil, err
			}
			defer file.Close()
			info, err := file.Stat()
			if err != nil || !info.Mode().IsRegular() || info.Size() > MaximumConfigBytes {
				return nil, ErrConfiguration
			}
			version := fmt.Sprintf("%d:%d", info.ModTime().UnixNano(), info.Size())
			if request.Page > 1 && request.Query != version {
				return nil, ErrConfiguration
			}
			data := make([]byte, 32768)
			n, err := file.ReadAt(data, int64(request.Page-1)*32768)
			if err != nil && err != io.EOF {
				return nil, err
			}
			after, err := file.Stat()
			if err != nil || !after.ModTime().Equal(info.ModTime()) || after.Size() != info.Size() {
				return nil, ErrConfiguration
			}
			value = map[string]any{"data": data[:n], "done": int64(request.Page)*32768 >= info.Size(), "version": version}
		} else {
			providers := map[string]any{}
			for name, provider := range tunnel.RuleProviders() {
				if current.rules[name] == "" {
					continue
				}
				providers[name] = map[string]any{"name": name, "ruleCount": provider.Count(), "behavior": provider.Behavior().String(), "path": current.rules[name]}
			}
			value = map[string]any{"providers": providers}
		}
	case "geodata":
		if request.Scope != "" && request.Scope != "active" && request.Scope != "status" {
			return nil, ErrConfiguration
		}
		active := current
		active.geoMu.Lock()
		if request.Scope != "status" && !active.geoRunning {
			active.geoRunning = true
			active.geoFailed = false
			active.probeWorkers.Add(1)
			go func() {
				defer active.probeWorkers.Done()
				err := active.context.Err()
				if err == nil {
					err = updater.UpdateGeoDatabases()
				}
				active.geoMu.Lock()
				active.geoRunning = false
				active.geoFailed = err != nil
				active.geoMu.Unlock()
			}()
		}
		value = map[string]bool{"running": active.geoRunning, "failed": active.geoFailed}
		active.geoMu.Unlock()
	case "snapshot":
		if request.Page < 1 || request.Page > 100000 || len(request.Query) > 1024 ||
			(request.Scope != "" && request.Scope != "all" && request.Scope != "active" && request.Scope != "closed") {
			return nil, ErrConfiguration
		}
		current.history.sample()
		history := &current.history
		snapshot := liveSnapshot{Upload: history.rateUp, Download: history.rateDown, UploadTotal: history.proxyUp, DownloadTotal: history.proxyDown, Connections: []liveConnection{}, Page: request.Page, Selections: map[string]string{}, Groups: []liveGroup{}, Delays: map[string]uint16{}, Memory: statistic.DefaultManager.Memory(), Mode: tunnel.Mode().String(), Rank: history.drainRank()}
		rows := []liveConnection{}
		query := strings.ToLower(strings.TrimSpace(request.Query))
		appendRow := func(c liveConnection) {
			if !strings.Contains(strings.ToLower(strings.Join([]string{c.Destination, c.IP, c.Process, c.Rule, c.Network, c.Inbound, strings.Join(c.Chains, " ")}, " ")), query) {
				return
			}
			if c.ClosedAt == nil {
				snapshot.Active++
			} else {
				snapshot.Closed++
			}
			if (request.Scope == "closed" && c.ClosedAt == nil) || ((request.Scope == "active" || request.Scope == "") && c.ClosedAt != nil) {
				return
			}
			rows = append(rows, c)
		}
		for _, c := range current.history.active {
			appendRow(c)
		}
		sort.Slice(rows, func(i, j int) bool {
			if rows[i].Start.Equal(rows[j].Start) {
				return rows[i].ID < rows[j].ID
			}
			return rows[i].Start.After(rows[j].Start)
		})
		// 与 connections_page.dart 一致：活跃在前，已关闭按关闭时间由新到旧
		for i := len(current.history.closed) - 1; i >= 0; i-- {
			appendRow(current.history.closed[i])
		}
		snapshot.Total = len(rows)
		start := min((request.Page-1)*25, len(rows))
		snapshot.Connections = append(snapshot.Connections, rows[start:min(start+25, len(rows))]...)
		recordDelay := func(name string, proxy C.Proxy) {
			history := proxy.DelayHistory()
			if len(history) > 0 && history[len(history)-1].Delay > 0 {
				snapshot.Delays[name] = history[len(history)-1].Delay
			}
		}
		for _, provider := range tunnel.Providers() {
			for _, proxy := range provider.Proxies() {
				recordDelay(proxy.Name(), proxy)
			}
		}
		for name, proxy := range tunnel.Proxies() {
			recordDelay(name, proxy)
			data, err := proxy.MarshalJSON()
			if err != nil {
				continue
			}
			var group struct {
				All    []string `json:"all"`
				Now    string   `json:"now"`
				Type   string   `json:"type"`
				Hidden bool     `json:"hidden"`
			}
			if json.Unmarshal(data, &group) != nil || group.All == nil || group.Hidden {
				continue
			}
			kind := strings.ToLower(group.Type)
			if kind == "selector" {
				kind = "select"
			}
			snapshot.Groups = append(snapshot.Groups, liveGroup{ID: name, Members: group.All, Type: kind})
			if group.Now != "" {
				snapshot.Selections[name] = group.Now
			}
		}
		sort.Slice(snapshot.Groups, func(i, j int) bool { return snapshot.Groups[i].ID < snapshot.Groups[j].ID })
		value = snapshot
	case "mode":
		mode, valid := tunnel.ModeMapping[request.Mode]
		if !valid {
			return nil, ErrConfiguration
		}
		tunnel.SetMode(mode)
	case "probe":
		if err := current.startProbe(request.Node, request.Scope); err != nil {
			return nil, err
		}
		value = current.probes[request.Scope+"/"+request.Node]
	case "probes":
		probe := current.probes[request.Scope+"/"+request.Node]
		if probe == nil {
			return nil, ErrConfiguration
		}
		value = probe
	case "select":
		if err := selectLocked(request.Group, request.Node); err != nil {
			return nil, err
		}
	case "close":
		if request.ConnectionID == "" {
			return nil, ErrConfiguration
		}
		if c := statistic.DefaultManager.Get(request.ConnectionID); c != nil {
			_ = c.Close()
		}
	case "closeAll":
		statistic.DefaultManager.Range(func(c statistic.Tracker) bool { _ = c.Close(); return true })
	case "logs":
		if request.Page < 1 || request.Page > 100 || len(request.Query) > 1024 ||
			(request.Level != "" && request.Level != "debug" && request.Level != "info" && request.Level != "warning" && request.Level != "error") {
			return nil, ErrConfiguration
		}
		type annotatedLog struct {
			logEntry
			Inbound string `json:"inbound,omitempty"`
		}
		inbound := map[string]string{}
		for _, c := range current.history.closed {
			if c.Inbound != "" {
				inbound[c.Source] = c.Inbound
			}
		}
		for _, c := range current.history.active {
			if c.Inbound != "" {
				inbound[c.Source] = c.Inbound
			}
		}
		current.logs.mu.Lock()
		entries := []annotatedLog{}
		filtered := []logEntry{}
		for _, entry := range current.logs.entries {
			if (request.Level == "" || entry.Level == request.Level) && strings.Contains(strings.ToLower(entry.Message), strings.ToLower(strings.TrimSpace(request.Query))) {
				filtered = append(filtered, entry)
			}
		}
		start := len(filtered) - (request.Page-1)*20 - 1
		for i := start; i >= 0 && i > start-20; i-- {
			entry := annotatedLog{logEntry: filtered[i]}
			if match := logSource.FindStringSubmatch(entry.Message); match != nil {
				entry.Inbound = inbound[match[1]]
			}
			entries = append(entries, entry)
		}
		value = struct {
			Entries []annotatedLog `json:"entries"`
			Total   int            `json:"total"`
		}{entries, len(filtered)}
		current.logs.mu.Unlock()
	default:
		return nil, ErrConfiguration
	}
	encoded, err := json.Marshal(value)
	if err != nil || len(encoded) > MaximumControlBytes {
		return nil, ErrConfiguration
	}
	return encoded, nil
}

type liveProbe struct {
	Running bool   `json:"running"`
	Failed  bool   `json:"failed"`
	Delay   uint16 `json:"delay"`
	Speed   int64  `json:"speed"`
}

func (engine *instance) startProbe(name, kind string) error {
	if name == "" || len(name) > 1024 || (kind != "delay" && kind != "speed" && kind != "reselect") {
		return ErrConfiguration
	}
	proxy := tunnel.Proxies()[name]
	if proxy == nil {
		for _, provider := range tunnel.Providers() {
			for _, member := range provider.Proxies() {
				if member.Name() == name {
					proxy = member
					break
				}
			}
			if proxy != nil {
				break
			}
		}
	}
	if proxy == nil {
		return ErrConfiguration
	}
	group, isGroup := proxy.Adapter().(outboundgroup.ProxyGroup)
	if kind == "reselect" && (!isGroup || proxy.Type() == C.Selector) {
		return ErrConfiguration
	}
	if kind == "speed" && !officialNode.MatchString(name) {
		return ErrConfiguration
	}
	key := kind + "/" + name
	probe := engine.probes[key]
	if probe != nil && probe.Running {
		return nil
	}
	limit := 8
	if kind == "speed" {
		limit = 1
	}
	for key, existing := range engine.probes {
		if strings.HasPrefix(key, kind+"/") && existing.Running {
			limit--
		}
	}
	if limit <= 0 {
		return ErrBusy
	}
	if probe == nil {
		probe = &liveProbe{}
		engine.probes[key] = probe
	}
	probe.Running = true
	probe.Failed = false
	result := *probe
	engine.probeWorkers.Add(1)
	go func() {
		var err error
		if kind != "speed" {
			ctx, cancel := context.WithTimeout(engine.context, 5*time.Second)
			if kind == "reselect" {
				if selectable, ok := proxy.Adapter().(outboundgroup.SelectAble); ok {
					selectable.ForceSet("")
				}
				_, err = group.URLTest(ctx, "https://cp.cloudflare.com/generate_204", nil)
			} else {
				result.Delay, err = proxy.URLTest(ctx, "https://cp.cloudflare.com/generate_204", nil)
			}
			cancel()
		} else {
			result.Speed, err = measureSpeed(engine.context, proxy)
		}
		// Stop 等待网络操作退出后才能卸载内核；发布结果不持有该等待。
		engine.probeWorkers.Done()
		lifecycle.Lock()
		defer lifecycle.Unlock()
		if current != engine {
			return
		}
		result.Running = false
		result.Failed = err != nil
		*probe = result
	}()
	return nil
}

var officialNode = regexp.MustCompile(`^node-[1-9][0-9]*$`)

func measureSpeed(parent context.Context, proxy C.Proxy) (int64, error) {
	ctx, cancel := context.WithTimeout(parent, 10*time.Second)
	defer cancel()
	transport := &http.Transport{
		DisableKeepAlives: true, DisableCompression: true, ForceAttemptHTTP2: false,
		TLSHandshakeTimeout: 2 * time.Second, ResponseHeaderTimeout: 2 * time.Second, MaxResponseHeaderBytes: 65536,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(address)
			if err != nil || host != "speed.cloudflare.com" || port != "443" {
				return nil, ErrConfiguration
			}
			dialCtx, stop := context.WithTimeout(ctx, 2*time.Second)
			defer stop()
			return proxy.DialContext(dialCtx, &C.Metadata{NetWork: C.TCP, Type: C.INNER, Host: host, DstPort: 443})
		},
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://speed.cloudflare.com/__down?bytes=100000000", nil)
	if err != nil {
		return 0, ErrConfiguration
	}
	request.Header.Set("Referer", "https://speed.cloudflare.com/")
	request.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
	response, err := client.Do(request)
	if err != nil {
		return 0, ErrConfiguration
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return 0, ErrConfiguration
	}
	reader := io.LimitReader(response.Body, 100000001)
	buffer := make([]byte, 256*1024)
	var received, window, peak int64
	var started, checkpoint time.Time
	for {
		n, err := reader.Read(buffer)
		now := time.Now()
		if n > 0 {
			if started.IsZero() {
				started = now
				checkpoint = now
			}
			received += int64(n)
			window += int64(n)
			if received > 100000000 {
				return 0, ErrConfiguration
			}
		}
		if !checkpoint.IsZero() && now.Sub(checkpoint) >= time.Second {
			peak = max(peak, window*1000/(now.Sub(checkpoint).Milliseconds()+1))
			window = 0
			checkpoint = now
		}
		if err != nil {
			break
		}
	}
	if parent.Err() != nil || received < 32768 {
		return 0, ErrConfiguration
	}
	if peak == 0 && time.Since(started) > 0 {
		peak = int64(float64(received) / time.Since(started).Seconds())
	}
	if peak <= 0 {
		return 0, ErrConfiguration
	}
	return peak, nil
}
