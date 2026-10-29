set -eu
work=$(mktemp -d /tmp/ecycloud-sync.XXXXXX)
case "$work" in /tmp/ecycloud-sync.*) ;; *) exit 1;; esac
pid=''
cleanup() {
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
    rm -rf -- "$work"
}
trap cleanup EXIT HUP INT TERM
printf '%s' '{"external-controller":"127.0.0.1:20997","secret":"synthetic-test-secret","mixed-port":0,"mode":"direct","dns":{"enable":false},"tun":{"enable":false,"device":"ECYSyncTest","stack":"system","auto-route":false,"auto-redirect":false},"rules":["MATCH,DIRECT"]}' >"$work/config.json"
mihomo -d "$work" -f "$work/config.json" >"$work/log" 2>&1 &
pid=$!
ready=0
for n in 1 2 3 4 5; do
    if curl -fsS -H 'Authorization: Bearer synthetic-test-secret' http://127.0.0.1:20997/version >/dev/null; then ready=1; break; fi
    sleep 1
done
[ "$ready" = 1 ] || { tail -n 5 "$work/log"; exit 1; }
for enable in true false true false; do
    curl -fsS -X PATCH -H 'Authorization: Bearer synthetic-test-secret' -H 'Content-Type: application/json' -d "{\"tun\":{\"enable\":$enable}}" http://127.0.0.1:20997/configs >/dev/null
    sleep 1
    actual=$(curl -fsS -H 'Authorization: Bearer synthetic-test-secret' http://127.0.0.1:20997/configs | jsonfilter -e '@.tun.enable')
    [ "$actual" = "$enable" ] || { echo TUN_STATE_FAILED; exit 1; }
    kill -0 "$pid"
done
if ip link show ECYSyncTest >/dev/null 2>&1; then echo TUN_DEVICE_REMAINED; exit 1; fi
echo TUN_PATCH_OK_PID_UNCHANGED
