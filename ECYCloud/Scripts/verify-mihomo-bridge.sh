#!/bin/bash
set -euo pipefail
if [[ $# -gt 1 || ($# -eq 1 && "$1" != --apple-link) ]]; then
    echo '用法：verify-mihomo-bridge.sh [--apple-link]' >&2
    exit 2
fi
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
go_bin="${GO_BIN:-go}"
if ! command -v "$go_bin" >/dev/null 2>&1; then
    echo '需要 Go 1.27.1 或更新版本；可通过 GO_BIN 指定已有工具链。' >&2
    exit 1
fi
work_dir="$(mktemp -d /private/tmp/ecycloud-mihomo-verify.XXXXXX)"
cleanup() {
    chmod -R u+w "$work_dir" 2>/dev/null || true
    rm -rf "$work_dir"
}
trap cleanup EXIT
mkdir -p "$work_dir/tmp" "$work_dir/modules" "$work_dir/cache" "$work_dir/config" "$work_dir/security"
export TMPDIR="$work_dir/tmp"
export CLANG_MODULE_CACHE_PATH="$work_dir/modules"
export GOCACHE="${GOCACHE:-$work_dir/go-cache}"
export GOPATH="${GOPATH:-$work_dir/go-work}"
export GOTMPDIR="$work_dir/tmp"
export GOPROXY=https://proxy.golang.org
export GOTOOLCHAIN=local
swift_args=(--package-path "$project_dir/Packages/ECYCloudKit" --scratch-path "$work_dir/swift" --cache-path "$work_dir/cache" --config-path "$work_dir/config" --security-path "$work_dir/security" --disable-sandbox --build-system swiftbuild)
swift build "${swift_args[@]}"
bin_dir="$(swift build "${swift_args[@]}" --show-bin-path)"
swiftc -parse-as-library -I "$bin_dir" "$bin_dir/ECYCloudKit.o" "$project_dir/Tests/MihomoBridge/AssembleFixture.swift" -lxml2 -o "$work_dir/assemble"
"$work_dir/assemble" "$work_dir/config.json"
ECY_SYNTHETIC_CONFIG="$work_dir/config.json" "$go_bin" -C "$project_dir" test -mod=readonly -race -count=3 -timeout 60s -v ./Kernel/... ./Tests/MihomoBridge
if [[ ${1:-} == --apple-link ]]; then
    cat > "$work_dir/link.c" <<'C'
#include <stdlib.h>
extern void ECYStop(unsigned long long);
int main(void) { ECYStop(0); return 0; }
C
    for platform in ios tvos visionos; do
        case "$platform" in
            ios) sdk=iphoneos; target=arm64-apple-ios17.0 ;;
            tvos) sdk=appletvos; target=arm64-apple-tvos17.0 ;;
            visionos) sdk=xros; target=arm64-apple-xros1.0 ;;
        esac
        cat > "$work_dir/cc-$platform" <<SH
#!/bin/bash
exec xcrun --sdk "$sdk" clang -target "$target" "\$@"
SH
        chmod +x "$work_dir/cc-$platform"
        env GOOS=ios GOARCH=arm64 CGO_ENABLED=1 CC="$work_dir/cc-$platform" \
            "$go_bin" -C "$project_dir" build -mod=readonly -buildmode=c-archive -o "$work_dir/mihomo-$platform.a" ./Kernel/bridge
        xcrun --sdk "$sdk" clang -target "$target" "$work_dir/link.c" "$work_dir/mihomo-$platform.a" \
            -framework Foundation -framework Security -framework CoreFoundation -framework SystemConfiguration -framework Network -lresolv \
            -o "$work_dir/linked-$platform"
        xcrun vtool -show-build "$work_dir/linked-$platform"
    done
fi
