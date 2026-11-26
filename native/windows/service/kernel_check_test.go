//go:build windows

package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

const kernelCheckTestMode = "ECYCLOUD_TEST_KERNEL_CHECK"

func kernelCheckChild(ctx context.Context, mode string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestKernelCheckReportsOnlyKernelErrorsAsInvalid$")
	cmd.Env = append(os.Environ(), kernelCheckTestMode+"="+mode)
	return cmd
}

func TestKernelCheckReportsOnlyKernelErrorsAsInvalid(t *testing.T) {
	switch os.Getenv(kernelCheckTestMode) {
	case "invalid":
		fmt.Println(`time="t" level=info msg="Start initial configuration in progress"`)
		fmt.Println(`time="t" level=error msg="rules[0] [MATCH,missing] error: proxy [missing] not found"`)
		fmt.Println("configuration file config.check.json test failed")
		os.Exit(1)
	case "valid":
		os.Exit(0)
	case "hang":
		fmt.Println(`time="t" level=error msg="geodata download failed"`)
		time.Sleep(time.Minute)
		os.Exit(0)
	case "loading":
		fmt.Println(`time="t" level=info msg="loading"`)
		time.Sleep(time.Minute)
		os.Exit(0)
	case "crash":
		fmt.Println(`time="t" level=info msg="loading"`)
		os.Exit(-1073741819)
	}

	out, err := kernelCheckChild(context.Background(), "invalid").CombinedOutput()
	if reason, err := kernelCheckResult(context.Background(), out, err); err != nil || reason != "rules[0] [MATCH,missing] error: proxy [missing] not found" {
		t.Fatalf("内核自己报出的错误必须按配置不合法返回: %q %v", reason, err)
	}
	out, err = kernelCheckChild(context.Background(), "valid").CombinedOutput()
	if reason, err := kernelCheckResult(context.Background(), out, err); reason != "" || err != nil {
		t.Fatalf("校验通过时不能带原因或错误: %q %v", reason, err)
	}

	for name, run := range map[string]func() (string, error){
		"超时": func() (string, error) {
			ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
			defer cancel()
			out, err := kernelCheckChild(ctx, "hang").CombinedOutput()
			return kernelCheckResult(ctx, out, err)
		},
		"被其它程序结束": func() (string, error) {
			var out bytes.Buffer
			cmd := kernelCheckChild(context.Background(), "loading")
			cmd.Stdout, cmd.Stderr = &out, &out
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			time.Sleep(500 * time.Millisecond)
			cmd.Process.Kill()
			err := cmd.Wait()
			return kernelCheckResult(context.Background(), out.Bytes(), err)
		},
		"崩溃": func() (string, error) {
			out, err := kernelCheckChild(context.Background(), "crash").CombinedOutput()
			return kernelCheckResult(context.Background(), out, err)
		},
		"起不来": func() (string, error) {
			out, err := exec.Command(`C:\nonexistent\mihomo.exe`, "-t").CombinedOutput()
			return kernelCheckResult(context.Background(), out, err)
		},
	} {
		reason, err := run()
		if reason != "" || err == nil || !strings.Contains(err.Error(), "配置校验未能完成") {
			t.Fatalf("%s：校验没跑成不能当成配置不合法: %q %v", name, reason, err)
		}
	}
}

func TestKernelCheckRejectedConfigStaysValidationResult(t *testing.T) {
	t.Setenv("ProgramData", t.TempDir())
	activeSession = strings.Repeat("a", 64)
	defer func() { activeSession = "" }()
	s := newServer()
	value, err := s.dispatch(request{Command: "kernel.check", Config: `{"external-controller":"0.0.0.0:9090"}`}, os.Getpid(), "account-a")
	result, ok := value.(map[string]any)
	if err != nil || !ok || result["valid"] != false || result["error"] != "控制面只能绑定本机回环地址" {
		t.Fatalf("被特权侧拒收的配置必须照常按校验不通过应答: %v %v", value, err)
	}
}
