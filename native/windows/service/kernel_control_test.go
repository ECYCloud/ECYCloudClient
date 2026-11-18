package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

const testControlSecret = "test-control-secret"

func testControl(t *testing.T, handler http.HandlerFunc) kernelControl {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	control, err := parseKernelControl(fmt.Sprintf(
		`{"external-controller":%q,"secret":%q}`, server.Listener.Addr().String(), testControlSecret,
	))
	if err != nil {
		t.Fatal(err)
	}
	return control
}

func TestParseKernelControlOnlyAcceptsLoopback(t *testing.T) {
	for _, address := range []string{"0.0.0.0:9090", "192.0.2.1:9090", "localhost:9090", "example.test:9090", ":9090", "127.0.0.1"} {
		if _, err := parseKernelControl(fmt.Sprintf(`{"external-controller":%q}`, address)); err == nil {
			t.Fatalf("接受了非回环控制面地址 %q", address)
		}
	}
	if _, err := parseKernelControl(`{"External-Controller":"127.0.0.1:9090"}`); err == nil {
		t.Fatal("键名大小写不同的控制面地址不是内核实际使用的地址")
	}
	control, err := parseKernelControl(`{"external-controller":"127.0.0.1:9090","secret":"s"}`)
	if err != nil || control.address != "127.0.0.1:9090" || control.secret != "s" {
		t.Fatalf("回环控制面解析结果不对: %+v %v", control, err)
	}
}

func TestDisableTunSendsAuthorizedPatchToLoopback(t *testing.T) {
	var method, path, authorization, body, remote string
	control := testControl(t, func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		method, path, authorization, body, remote = r.Method, r.URL.RequestURI(), r.Header.Get("Authorization"), string(raw), r.Host
		w.WriteHeader(http.StatusNoContent)
	})
	if err := control.disableTun(); err != nil {
		t.Fatal(err)
	}
	if method != http.MethodPatch || path != "/configs" || body != `{"tun":{"enable":false}}` {
		t.Fatalf("请求不对: %s %s %s", method, path, body)
	}
	if authorization != "Bearer "+testControlSecret {
		t.Fatalf("Authorization 不对: %q", authorization)
	}
	if host, _, err := net.SplitHostPort(remote); err != nil || host != "127.0.0.1" {
		t.Fatalf("请求没有发往 127.0.0.1: %q", remote)
	}
}

func TestDisableTunFailuresReturnQuicklyWithoutSecret(t *testing.T) {
	closed := httptest.NewServer(http.NotFoundHandler())
	unreachable := kernelControl{address: closed.Listener.Addr().String(), secret: testControlSecret}
	closed.Close()

	cases := map[string]kernelControl{
		"控制口不通": unreachable,
		"超时": testControl(t, func(http.ResponseWriter, *http.Request) {
			time.Sleep(2 * kernelTunCloseTimeout)
		}),
		"非 204": testControl(t, func(w http.ResponseWriter, _ *http.Request) {
			http.Error(w, testControlSecret, http.StatusInternalServerError)
		}),
	}
	for name, control := range cases {
		started := time.Now()
		err := control.disableTun()
		if err == nil {
			t.Fatalf("%s：应当报错", name)
		}
		if elapsed := time.Since(started); elapsed > kernelTunCloseTimeout+time.Second {
			t.Fatalf("%s：%s 才返回，会拖住停内核", name, elapsed)
		}
		if strings.Contains(err.Error(), testControlSecret) {
			t.Fatalf("%s：错误信息带出了 secret: %v", name, err)
		}
	}
}

func TestDisableTunDoesNotFollowRedirect(t *testing.T) {
	followed := false
	elsewhere := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		followed = true
	}))
	defer elsewhere.Close()
	control := testControl(t, func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, elsewhere.URL, http.StatusTemporaryRedirect)
	})
	if err := control.disableTun(); err == nil {
		t.Fatal("重定向应当按失败处理")
	}
	if followed {
		t.Fatal("带 secret 的请求跟随了重定向")
	}
}

func TestControlListeningMatchesOnlyOwnAddress(t *testing.T) {
	const address = "127.0.0.1:4567"
	if !controlListening(`time="2026-10-30T12:00:00.000000000+08:00" level=info msg="RESTful API listening at: 127.0.0.1:4567"`, address) {
		t.Fatal("没认出本次内核的监听日志")
	}
	for _, line := range []string{
		`time="2026-10-30T12:00:00.000000000+08:00" level=info msg="RESTful API listening at: 127.0.0.1:45670"`,
		`time="2026-10-30T12:00:00.000000000+08:00" level=info msg="[TCP] 127.0.0.1:50000 --> RESTful API listening at: 127.0.0.1:4567 match Match using DIRECT"`,
		`time="2026-10-30T12:00:00.000000000+08:00" level=error msg="External controller listen error: listen tcp 127.0.0.1:4567: bind: address already in use"`,
		`RESTful API listening at: 127.0.0.1:4567`,
	} {
		if controlListening(line, address) {
			t.Fatalf("误认了监听日志: %s", line)
		}
	}
	if controlListening(`level=info msg="RESTful API listening at: "`, "") {
		t.Fatal("没有控制面地址时不能算已监听")
	}
}
