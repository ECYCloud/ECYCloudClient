#!/usr/bin/env bash
# 构建 Android 侧的 libmihomo.aar。
# 官方不发布移动端产物：按 kernel.lock.json 锁定的 tag 以依赖方式 import 内核，
# 对 native/android/mihomo 这层封装做 gomobile bind，不改一行内核代码。
# 依赖：Go、JDK 17、Android SDK（含 NDK），ANDROID_HOME 与 ANDROID_NDK_HOME 需已就绪。
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(dirname "$script_dir")"
lock="$script_dir/kernel.lock.json"
mod_dir="$root_dir/native/android/mihomo"
libs_dir="$root_dir/app/android/app/libs"

tag="$(jq -er '.mihomo.tag' "$lock")"

cd "$mod_dir"

# 内核版本必须与桌面端锁的是同一个 tag，否则两端跑在不同内核上，问题无从复现
locked="$(go list -m -f '{{.Version}}' github.com/metacubex/mihomo)"
if [[ "$locked" != "$tag" ]]; then
    echo "go.mod 锁的内核是 $locked，kernel.lock.json 是 $tag，先对齐再构建" >&2
    exit 1
fi

# gomobile / gobind 用 go.mod 里锁的那个版本，不取 @latest，避免每次构建结果不同
export GOBIN="$root_dir/build/gobin"
mkdir -p "$GOBIN"
go install golang.org/x/mobile/cmd/gomobile golang.org/x/mobile/cmd/gobind
export PATH="$GOBIN:$PATH"

# 三个 ABI 与 build-android.sh 的分包目标一一对应；androidapi 对齐 build.gradle.kts 的 minSdk。
# with_gvisor 不能省：gvisor 与 mixed 两种栈的实现整体在这个标签后面
# （sing-tun 的 stack_gvisor.go / stack_mixed.go），不带就只编进 stack_gvisor_stub.go，
# 客户端下发的 stack: mixed 会在建栈时报 gVisor is not included in this build。
# cmfa 更不能省（Clash Meta for Android 的 core/build.gradle.kts 同样带它）：内核用它
# 区分「TUN 由内核自己建」与「TUN 由宿主的 VpnService 建」两种形态，而本项目是后者。
# 不带的话编进 listener/sing_tun/server_android.go，它的 buildAndroidRules 会去读
# /data/system/packages.xml 解析包名对应的 uid——非 root 机上必然 permission denied，
# sing_tun.New 随之失败，而 listener.ReCreateTun 只打一行 ERROR 并把 tun.enable 抹成
# false，ApplyConfig 不报错：系统那张网卡建好了却没人读它的 fd，界面显示已连接、
# 全部流量掉进黑洞。同一标签还会关掉 loopback 探测器（它按 iface.IsLocalIp 判定，
# Android 11+ 拿网卡表本就不可靠）。
# 与官方 Makefile 的 GOBUILD 一致，ldflags 也照它注入版本号。
mkdir -p "$libs_dir"
gomobile bind \
    -target=android/arm64,android/arm,android/amd64 \
    -androidapi 24 \
    -javapkg com.ecycloud \
    -tags with_gvisor,cmfa \
    -trimpath \
    -ldflags "-s -w -X github.com/metacubex/mihomo/constant.Version=$tag" \
    -o "$libs_dir/libmihomo.aar" \
    .

# 这里能直接取到内核源码，许可证就从源码带出，不靠「与本项目同为 GPL-3.0」的假设
install -m 0644 "$(go list -m -f '{{.Dir}}' github.com/metacubex/mihomo)/LICENSE" \
    "$libs_dir/LICENSE.mihomo.txt"

echo "libmihomo.aar（mihomo $tag）已就绪：$libs_dir/libmihomo.aar"
