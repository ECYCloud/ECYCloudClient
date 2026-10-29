#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
go_bin="${GO_BIN:-go}"
output="${1:-$project_dir/../build/AppleKernel.xcframework}"
if [[ -e "$output" ]]; then echo "输出已存在，请指定新的输出目录：$output" >&2; exit 2; fi
work_dir="$(mktemp -d /private/tmp/ecycloud-kernel-build.XXXXXX)"
trap 'chmod -R u+w -- "$work_dir" 2>/dev/null || true; rm -rf -- "$work_dir"' EXIT
export TMPDIR="$work_dir/tmp" GOTMPDIR="$work_dir/tmp" GOTOOLCHAIN=local GOPROXY=https://proxy.golang.org
export GOPATH="${GOPATH:-$work_dir/go-work}" GOCACHE="${GOCACHE:-$work_dir/go-cache}"
mkdir -p "$TMPDIR"
kernel_version="$("$go_bin" -C "$project_dir" list -mod=readonly -m -f '{{.Version}}' github.com/metacubex/mihomo)"
[[ "$kernel_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'mihomo 必须锁定正式版本 tag' >&2; exit 2; }
args=()
for sdk in iphoneos iphonesimulator appletvos appletvsimulator xros xrsimulator; do
    case "$sdk" in
        iphoneos) target=ios17.0; archs=arm64 ;;
        iphonesimulator) target=ios17.0-simulator; archs='arm64 x86_64' ;;
        appletvos) target=tvos17.0; archs=arm64 ;;
        appletvsimulator) target=tvos17.0-simulator; archs='arm64 x86_64' ;;
        xros) target=xros1.0; archs=arm64 ;;
        xrsimulator) target=xros1.0-simulator; archs='arm64 x86_64' ;;
    esac
    mkdir -p "$work_dir/$sdk/Headers"
    cp "$project_dir/Kernel/include/ECYKernel.h" "$project_dir/Kernel/include/module.modulemap" "$work_dir/$sdk/Headers/"
    libs=()
    for arch in $archs; do
        goarch="$arch"; if [[ $arch == x86_64 ]]; then goarch=amd64; fi
        cat > "$work_dir/clang-$sdk-$arch" <<SH
#!/bin/bash
exec xcrun --sdk "$sdk" clang -target "$arch-apple-$target" "\$@"
SH
        chmod +x "$work_dir/clang-$sdk-$arch"
        env GOOS=ios GOARCH="$goarch" CGO_ENABLED=1 CGO_CFLAGS="-target $arch-apple-$target" CGO_LDFLAGS="-target $arch-apple-$target" CC="$work_dir/clang-$sdk-$arch" \
            "$go_bin" -C "$project_dir" build -mod=readonly -trimpath -ldflags="-s -w -X github.com/metacubex/mihomo/constant.Version=$kernel_version" -buildmode=c-archive -o "$work_dir/$sdk/$arch.a" ./Kernel/bridge
        libs+=("$work_dir/$sdk/$arch.a")
    done
    xcrun lipo -create "${libs[@]}" -output "$work_dir/$sdk/libECYKernel.a"
    args+=(-library "$work_dir/$sdk/libECYKernel.a" -headers "$work_dir/$sdk/Headers")
done
xcodebuild -create-xcframework "${args[@]}" -output "$output"
bash "$project_dir/../scripts/fetch-geodata.sh" "$(dirname "$output")"
