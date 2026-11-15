package mihomo

import (
	"encoding/json"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/profile/cachefile"
)

// 导出函数里的 panic 必须转成错误返回并停掉内核，不能带崩 :kernel 进程后随服务重建反复崩溃
func TestPanicInExportedCallBecomesError(t *testing.T) {
	stopped := false
	err := func() (err error) {
		defer recoverAsError(&err, func() { stopped = true })
		panic("malformed config")
	}()
	if err == nil || !stopped {
		t.Fatalf("panic 未转成错误或未清理: err=%v stopped=%v", err, stopped)
	}
}

// 控制面端口被同机其它应用抢先占住时内核只记日志照常运行；Start 必须失败，
// 否则 Dart 随后带 secret 的请求会发给占位者
func TestStartRejectsControllerPortTakenByAnotherProcess(t *testing.T) {
	Setup(t.TempDir())
	t.Cleanup(func() {
		Stop()
		if err := cachefile.Cache().Close(); err != nil {
			t.Error(err)
		}
	})
	config := func(controller string) string {
		raw, err := json.Marshal(map[string]any{
			"mode":                "rule",
			"find-process-mode":   "off",
			"rules":               []string{"MATCH,DIRECT"},
			"external-controller": controller,
			"secret":              "synthetic-controller-secret",
		})
		if err != nil {
			t.Fatal(err)
		}
		return string(raw)
	}

	taken, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer taken.Close()
	_, port, _ := net.SplitHostPort(taken.Addr().String())
	if err := Start(config(taken.Addr().String()), 0); err == nil || !strings.Contains(err.Error(), port) {
		t.Fatalf("控制面端口被占用时仍报告启动成功：%v", err)
	}
	if running {
		t.Fatal("控制面未就绪的内核没有被停掉")
	}

	free, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := free.Addr().String()
	free.Close()
	if err := Start(config(address), 0); err != nil {
		t.Fatalf("空闲端口上启动失败：%v", err)
	}
	client := http.Client{Timeout: 3 * time.Second}
	response, err := client.Get("http://" + address + "/version")
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("控制面应由内核监听并要求 secret，实际 HTTP %d", response.StatusCode)
	}
}
