package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const kernelTunCloseTimeout = time.Second

type kernelControl struct {
	address string
	secret  string
}

func loopbackHost(host string) bool {
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// 控制面地址与密钥按原键名精确读取（内核解析顶层键区分大小写），且只认回环地址
func parseKernelControl(config string) (kernelControl, error) {
	var top map[string]json.RawMessage
	var controller, secret string
	if json.Unmarshal([]byte(config), &top) != nil || json.Unmarshal(top["external-controller"], &controller) != nil {
		return kernelControl{}, fmt.Errorf("配置缺少控制面地址，无法热载")
	}
	if raw, ok := top["secret"]; ok && json.Unmarshal(raw, &secret) != nil {
		return kernelControl{}, fmt.Errorf("控制面密钥格式不合法")
	}
	host, port, err := net.SplitHostPort(controller)
	if err != nil || !loopbackHost(host) {
		return kernelControl{}, fmt.Errorf("控制面只能绑定本机回环地址")
	}
	return kernelControl{address: net.JoinHostPort(host, port), secret: secret}, nil
}

func (c kernelControl) send(method, path, body string, timeout time.Duration) (int, string, error) {
	request, err := http.NewRequest(method, "http://"+c.address+path, strings.NewReader(body))
	if err != nil {
		return 0, "", err
	}
	request.Header.Set("Content-Type", "application/json")
	if c.secret != "" {
		request.Header.Set("Authorization", "Bearer "+c.secret)
	}
	transport := &http.Transport{Proxy: nil}
	defer transport.CloseIdleConnections()
	client := &http.Client{
		Timeout:   timeout,
		Transport: transport,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	response, err := client.Do(request)
	if err != nil {
		return 0, "", err
	}
	defer response.Body.Close()
	reply, _ := io.ReadAll(io.LimitReader(response.Body, 512))
	return response.StatusCode, strings.TrimSpace(string(reply)), nil
}

func (c kernelControl) disableTun() error {
	status, _, err := c.send(http.MethodPatch, "/configs", `{"tun":{"enable":false}}`, kernelTunCloseTimeout)
	if err != nil {
		return err
	}
	if status != http.StatusNoContent && status != http.StatusOK {
		return fmt.Errorf("HTTP %d", status)
	}
	return nil
}

// 升级 mihomo 时回归这行日志原文：对不上就永远不会在停内核前关 TUN
func controlListening(line, address string) bool {
	_, message, ok := splitKernelLogLine(line)
	return ok && address != "" && message == "RESTful API listening at: "+address
}

// 内核日志是 logrus 的 key=value 文本：time="..." level=error msg="..."
func splitKernelLogLine(line string) (level string, message string, ok bool) {
	level = logfmtValue(line, "level=")
	if level == "" {
		return "", "", false
	}
	return level, logfmtValue(line, "msg="), true
}

func logfmtValue(line string, key string) string {
	index := strings.Index(line, key)
	if index < 0 {
		return ""
	}
	rest := line[index+len(key):]
	if !strings.HasPrefix(rest, `"`) {
		if end := strings.IndexByte(rest, ' '); end >= 0 {
			return rest[:end]
		}
		return rest
	}
	if value, err := strconv.Unquote(rest[:quotedEnd(rest)]); err == nil {
		return value
	}
	return ""
}

func quotedEnd(rest string) int {
	for i := 1; i < len(rest); i++ {
		switch rest[i] {
		case '\\':
			i++
		case '"':
			return i + 1
		}
	}
	return len(rest)
}
