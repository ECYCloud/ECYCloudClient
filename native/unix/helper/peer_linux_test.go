//go:build linux

package main

import (
	"os/exec"
	"testing"
)

func TestKernelCredentialFailsClosed(t *testing.T) {
	previousUID, previousGID := kernelUID, kernelGID
	t.Cleanup(func() { kernelUID, kernelGID = previousUID, previousGID })
	for _, ids := range [][2]int{{0, 0}, {-1, -1}, {1234, 0}, {0, 1234}} {
		kernelUID, kernelGID = ids[0], ids[1]
		if err := applyKernelCredential(exec.Command("unused")); err == nil {
			t.Fatalf("不可信账户 %v 不应回退到 root", ids)
		}
	}
	kernelUID, kernelGID = 1234, 1234
	cmd := exec.Command("unused")
	if err := applyKernelCredential(cmd); err != nil {
		t.Fatal(err)
	}
	if cmd.SysProcAttr.Credential.Uid != 1234 || cmd.SysProcAttr.Credential.Gid != 1234 || len(cmd.SysProcAttr.AmbientCaps) != 2 {
		t.Fatal("内核必须使用受限用户和两项网络权限")
	}
}
