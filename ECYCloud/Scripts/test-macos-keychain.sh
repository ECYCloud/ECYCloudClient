#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo '用法：bash test-macos-keychain.sh <已签名的 ECYCloud.app 路径> <本机签名证书标识>' >&2
    exit 2
fi

app_path="$1"
signing_identity="$2"
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
: "${TMPDIR:?请先指定隔离测试目录 TMPDIR}"
test_root="$(mktemp -d "${TMPDIR%/}/ecycloud-keychain-test.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT
export TMPDIR="$test_root/tmp"
mkdir -p "$TMPDIR" "$test_root/modules" "$test_root/KeychainProbe.app/Contents/MacOS"
probe_app="$test_root/KeychainProbe.app"

codesign --verify --deep --strict "$app_path"
codesign --display --entitlements "$test_root/entitlements.plist" --xml "$app_path"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")"
plutil -create xml1 "$probe_app/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string "$bundle_id" "$probe_app/Contents/Info.plist"
plutil -insert CFBundleExecutable -string KeychainProbe "$probe_app/Contents/Info.plist"
plutil -insert CFBundlePackageType -string APPL "$probe_app/Contents/Info.plist"
plutil -insert CFBundleVersion -string 1 "$probe_app/Contents/Info.plist"
if [[ -f "$app_path/Contents/embedded.provisionprofile" ]]; then
    cp "$app_path/Contents/embedded.provisionprofile" "$probe_app/Contents/embedded.provisionprofile"
fi

cat > "$test_root/KeychainProbe.swift" <<'SWIFT'
import Foundation
import Security

@main
struct KeychainProbe {
    @MainActor static func main() {
        let service = "com.ecycloud.client.keychain-regression.\(UUID().uuidString)"
        let vault = KeychainVault(service: service)
        var passed = false
        var itemCreated = false
        do {
            guard try vault.load() == nil else { throw ClientError.invalidResponse }
            let endpoints = try PanelEndpoints(site: "https://site.example.test", config: "https://config.example.test")
            let first = StoredSession(token: "synthetic-token-one", expiresAt: Date(timeIntervalSince1970: 2000000000),
                                      email: "fixture@example.test", userID: 1, endpoints: endpoints)
            try vault.save(first)
            itemCreated = true
            guard let loaded = try vault.load(), loaded.token == first.token, loaded.email == first.email,
                  loaded.userID == first.userID, loaded.endpoints == endpoints,
                  loaded.expiresAt == first.expiresAt else { throw ClientError.invalidResponse }
            guard try KeychainVault(service: "\(service).other").load() == nil else { throw ClientError.invalidResponse }
            let second = StoredSession(token: "synthetic-token-two", expiresAt: first.expiresAt,
                                       email: first.email, userID: first.userID, endpoints: endpoints)
            try vault.save(second)
            guard try vault.load()?.token == second.token else { throw ClientError.invalidResponse }
            try vault.clear()
            guard try vault.load() == nil else { throw ClientError.invalidResponse }
            let remembered = RememberedLogin(email: first.email, password: "synthetic-remembered-password", site: endpoints.site)
            try vault.saveRemembered(remembered)
            guard try vault.loadRemembered()?.password == remembered.password,
                  try vault.load() == nil else { throw ClientError.invalidResponse }
            try vault.clearRemembered()
            guard try vault.loadRemembered() == nil else { throw ClientError.invalidResponse }
            itemCreated = false
            print("系统钥匙串会话与记住密码的新增、读取、更新、隔离、删除：通过")
            passed = true
        } catch let ClientError.keychain(status) {
            print("系统钥匙串测试失败，OSStatus=\(status)")
        } catch {
            print("系统钥匙串数据校验失败")
        }
        if itemCreated {
            do { try vault.clear(); try vault.clearRemembered() }
            catch {
                passed = false
                print("测试项目清理失败，service=\(service)")
            }
        }
        exit(passed ? 0 : 1)
    }
}
SWIFT

xcrun swiftc -swift-version 6 -warnings-as-errors -module-cache-path "$test_root/modules" \
    "$project_dir"/Packages/ECYCloudKit/Sources/ECYCloudKit/*.swift \
    "$test_root/KeychainProbe.swift" -lxml2 -o "$probe_app/Contents/MacOS/KeychainProbe"
codesign --force --sign "$signing_identity" --entitlements "$test_root/entitlements.plist" \
    --timestamp=none --options runtime "$probe_app"
codesign --verify --deep --strict "$probe_app"
"$probe_app/Contents/MacOS/KeychainProbe"
