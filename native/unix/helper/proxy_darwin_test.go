//go:build darwin

package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestBrokenProxySnapshotIsDiscarded(t *testing.T) {
	for name, content := range map[string]string{
		"损坏":   "{broken",
		"无服务":  `{"services":[]}`,
		"版本不符": `{"services":[{"name":"Wi-Fi","proxies":[{"enabled":false}]}]}`,
	} {
		path := filepath.Join(t.TempDir(), "proxy-snapshot.json")
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := loadSnapshotFile(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("%s：应按无快照处理，得到 %v", name, err)
		}
		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("%s：损坏的快照必须删除", name)
		}
	}
}

func TestValidProxySnapshotIsKept(t *testing.T) {
	path := filepath.Join(t.TempDir(), "proxy-snapshot.json")
	if err := writeSnapshotFile(path, []byte(`{"services":[{"name":"Wi-Fi","proxies":[{"enabled":true,"server":"10.0.0.1","port":8080},{"enabled":false}]}]}`)); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path + ".tmp"); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("写入后不能残留临时文件")
	}
	snapshot, err := loadSnapshotFile(path)
	if err != nil || snapshot.Services[0].Proxies[0].Port != 8080 {
		t.Fatalf("有效快照必须原样读回: %v", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal("有效快照不能被删除")
	}
}

func TestProxySetRecordsServicesAddedAfterSnapshot(t *testing.T) {
	snapshot := proxySnapshot{Services: []serviceSnapshot{{Name: "Wi-Fi"}}}
	fresh := unrecordedServices(snapshot, []string{"Wi-Fi", "USB 10/100/1000 LAN"})
	if len(fresh) != 1 || fresh[0] != "USB 10/100/1000 LAN" {
		t.Fatalf("连接后新出现的网络服务必须先补记原值: %v", fresh)
	}
	if fresh := unrecordedServices(proxySnapshot{}, []string{"Wi-Fi"}); len(fresh) != 1 {
		t.Fatalf("没有快照时全部服务都要记录: %v", fresh)
	}
	if fresh := unrecordedServices(snapshot, []string{"Wi-Fi"}); len(fresh) != 0 {
		t.Fatalf("已记录的服务不能用被改过的值覆盖: %v", fresh)
	}
}
