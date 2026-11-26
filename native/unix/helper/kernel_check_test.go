//go:build darwin || linux

package main

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func runKernelCheck(ctx context.Context, name string, args ...string) (string, error) {
	out, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	return kernelCheckResult(ctx, out, err)
}

func TestKernelCheckReportsOnlyKernelErrorsAsInvalid(t *testing.T) {
	reason, err := runKernelCheck(context.Background(), "/bin/sh", "-c",
		`echo 'time="t" level=info msg="Start initial configuration in progress"'
echo 'time="t" level=error msg="rules[0] [MATCH,missing] error: proxy [missing] not found"'
echo 'configuration file config.check.json test failed'
exit 1`)
	if err != nil || reason != "rules[0] [MATCH,missing] error: proxy [missing] not found" {
		t.Fatalf("内核自己报出的错误必须按配置不合法返回: %q %v", reason, err)
	}
	if reason, err := runKernelCheck(context.Background(), "/bin/sh", "-c", "exit 0"); reason != "" || err != nil {
		t.Fatalf("校验通过时不能带原因或错误: %q %v", reason, err)
	}

	timeout, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	for name, run := range map[string]func() (string, error){
		"超时": func() (string, error) {
			return runKernelCheck(timeout, "/bin/sh", "-c", `echo 'time="t" level=error msg="geodata download failed"'; exec sleep 5`)
		},
		"被信号结束": func() (string, error) {
			return runKernelCheck(context.Background(), "/bin/sh", "-c", `echo 'time="t" level=error msg="partial"'; kill -9 $$`)
		},
		"起不来": func() (string, error) {
			return runKernelCheck(context.Background(), "/nonexistent/mihomo", "-t")
		},
		"没报错就退出": func() (string, error) {
			return runKernelCheck(context.Background(), "/bin/sh", "-c", `echo 'time="t" level=info msg="loading"'; exit 2`)
		},
	} {
		reason, err := run()
		if reason != "" || err == nil || !strings.Contains(err.Error(), "配置校验未能完成") {
			t.Fatalf("%s：校验没跑成不能当成配置不合法: %q %v", name, reason, err)
		}
	}
}

func TestKernelCheckRejectedConfigStaysValidationResult(t *testing.T) {
	activeSession = strings.Repeat("a", 64)
	defer func() { activeSession = "" }()
	s := newServer()
	value, err := s.dispatch(request{Command: "kernel.check", Config: `{"external-controller":"0.0.0.0:9090"}`}, os.Getpid(), "account-a")
	result, ok := value.(map[string]any)
	if err != nil || !ok || result["valid"] != false || result["error"] != "控制面只能绑定本机回环地址" {
		t.Fatalf("被特权侧拒收的配置必须照常按校验不通过应答: %v %v", value, err)
	}
}
