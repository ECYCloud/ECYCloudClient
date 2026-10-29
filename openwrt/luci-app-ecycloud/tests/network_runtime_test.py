import argparse
import ipaddress
import json
import shlex
import struct
import subprocess
import time


parser = argparse.ArgumentParser(description='OpenWrt DNS、断网、切网、内核恢复与重启实机回归')
parser.add_argument('--router', required=True)
parser.add_argument('--alternate-gateway')
parser.add_argument('--reboot', action='store_true')
selection = parser.add_mutually_exclusive_group()
selection.add_argument('--ipv6-off-only', action='store_true')
selection.add_argument('--crash-only', action='store_true')
args = parser.parse_args()
ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3', f'root@{args.router}']
namespace = 'ecycloud-verify'
work = '/var/run/ecycloud-verify'
client_owned = False


def remote(command, timeout=60, check=True, binary=False):
    result = subprocess.run(ssh + [command], capture_output=True, text=not binary, encoding=None if binary else 'utf-8', timeout=timeout)
    if check and result.returncode:
        message = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(message.decode('utf-8', errors='replace') if binary else message or f'SSH exit {result.returncode}')
    return result.stdout if binary else result.stdout.strip()


def status():
    data = json.loads(remote("ubus call luci.ecycloud status '{}'"))
    return {key: data.get(key) for key in ('enabled', 'running', 'stage', 'error', 'connected_at', 'network_applied', 'dns_applied')}


def wait_for(predicate, label, seconds=45):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            if predicate():
                return
        except (RuntimeError, AssertionError, json.JSONDecodeError, subprocess.TimeoutExpired):
            pass
        time.sleep(1)
    raise AssertionError(label)


def rpc(method, payload=None):
    result = json.loads(remote(f'ubus call luci.ecycloud {method} {shlex.quote(json.dumps(payload or {}))}'))
    assert result.get('ok'), f'{method}: {result.get("msg", "failed")}'


def pid():
    return remote("ubus call service list '{\"name\":\"ecycloud\"}' | jsonfilter -e '@.ecycloud.instances.core.pid'")


def geo_fingerprint():
    return remote('''sha256sum /etc/ecycloud/run/geoip.metadb /etc/ecycloud/run/GeoSite.dat
ucode -e 'let fs=require("fs");for(let path in ["/etc/ecycloud/run/geoip.metadb","/etc/ecycloud/run/GeoSite.dat"])print(fs.stat(path).mtime,"\\n");' ''')


def configure(**values):
    rpc('stop')
    wait_for(lambda: remote('test ! -e /var/run/ecycloud/network.json && echo ready') == 'ready', '停止后网络未恢复')
    commands = [f'uci set ecycloud.config.{key}={shlex.quote(str(value))}' for key, value in values.items()]
    commands += ['uci commit ecycloud', '/etc/init.d/ecycloud restart']
    remote('\n'.join(commands), timeout=120)
    wait_for(lambda: status()['running'] and status()['stage'] == 'stopped', '待机内核未就绪', seconds=90)


def start():
    rpc('start')
    wait_for(lambda: status()['stage'] == 'running', '网络接管未完成')


def stop():
    record = json.loads(remote('cat /var/run/ecycloud/network.json 2>/dev/null || echo "{}"'))
    rpc('stop')
    wait_for(lambda: remote('test ! -e /var/run/ecycloud/network.json && echo ready') == 'ready', '断开后仍有网络接管记录')
    assert remote("ip rule show; ip -6 rule show; ip route show table all; ip -6 route show table all").find('table 1937') < 0
    assert 'lookup 1936' not in remote('ip rule show; ip -6 rule show')
    assert 'lookup 1937' not in remote('ip rule show; ip -6 rule show')
    assert 'table inet ecycloud' not in remote('nft list tables'), '断开后仍有透明代理防火墙表'
    if record.get('dnsmasq'):
        remote(f'test ! -e {shlex.quote(record["dnsmasq"])}')


def setup_client():
    global client_owned
    client_owned = True
    remote(f'''set -eu
test ! -e {work}
test ! -e /var/run/netns/{namespace}
mkdir -m 700 {work}
ip netns add {namespace}
ip link add ecvtest type veth peer name ecptest
ip link set ecptest netns {namespace}
ip link set ecvtest master br-lan
ip link set ecvtest up
ip address add 172.31.255.1/30 dev br-lan
ip netns exec {namespace} sh -c 'echo 0 >/proc/sys/net/ipv6/conf/ecptest/accept_ra; echo 0 >/proc/sys/net/ipv6/conf/ecptest/autoconf'
ip netns exec {namespace} ip link set lo up
ip netns exec {namespace} ip link set ecptest up
ip netns exec {namespace} ip address add 172.31.255.2/30 dev ecptest
ip netns exec {namespace} ip -6 address add {client_ipv6}/64 dev ecptest nodad
ip netns exec {namespace} ip route add default via 172.31.255.1
ip netns exec {namespace} ip -6 route add default via {router_ipv6}
''')


def remove_client():
    if not client_owned:
        return
    remote(f'''ip netns pids {namespace} 2>/dev/null | xargs -r kill 2>/dev/null || true
ip link del ecvtest 2>/dev/null || true
ip netns del {namespace} 2>/dev/null || true
ip address del 172.31.255.1/30 dev br-lan 2>/dev/null || true
''', check=False)


def fake_dns(server='203.0.113.53'):
    output = remote(f'ip netns exec {namespace} nslookup -type=A example.com {shlex.quote(server)}', timeout=25)
    addresses = [line.split()[-1] for line in output.splitlines() if line.startswith('Address:') and '198.18.' in line]
    assert addresses, f'硬编码 DNS 未返回 Fake-IP: {output}'
    return addresses[-1]


def internet_check(address):
    code = remote(f'ip netns exec {namespace} curl --connect-timeout 5 --max-time 20 -sS -o /dev/null -w "%{{http_code}}" --resolve example.com:443:{shlex.quote(address)} https://example.com/', timeout=25)
    assert code == '200', f'LAN HTTPS 请求失败: {code}'


def dns_tcp(server, hostname):
    name = b''.join(bytes([len(label)]) + label.encode() for label in hostname.split('.')) + b'\x00'
    query = struct.pack('!HHHHHH', 0xEC05, 0x0100, 1, 0, 0, 0) + name + struct.pack('!HH', 1, 1)
    payload = ''.join(f'\\0{byte:03o}' for byte in struct.pack('!H', len(query)) + query)
    reply = remote(f'''set -eu
printf '%b' {shlex.quote(payload)} >{work}/query.bin
ip netns exec {namespace} nc {shlex.quote(server)} 53 <{work}/query.bin >{work}/reply.bin &
client=$!
for n in 1 2 3; do
    [ "$(wc -c <{work}/reply.bin)" -ge 16 ] && break
    sleep 1
done
kill "$client" 2>/dev/null || true
wait "$client" 2>/dev/null || true
cat {work}/reply.bin
''', timeout=10, binary=True)
    data = reply
    assert len(data) >= 16 and struct.unpack('!H', data[2:4])[0] == 0xEC05, 'TCP DNS 未返回相同查询 ID'
    assert data[4] & 0x80 and data[5] & 15 == 0 and struct.unpack('!H', data[8:10])[0] > 0, 'TCP DNS 没有成功应答'
    assert b'\xc6\x12' in data, 'TCP DNS 未返回 Fake-IP'


def dns_capture():
    remote(f'''set -eu
tcpdump -n -i eth1 -c 64 -s 512 -U -w {work}/leak.pcap 'dst port 53 and (dst host 203.0.113.53 or dst host 2001:db8::53)' >{work}/capture.log 2>&1 &
echo $! >{work}/capture.pid
tcpdump -n -i lo -c 64 -s 512 -U -w {work}/core.pcap 'dst port 10201' >{work}/core-capture.log 2>&1 &
echo $! >{work}/core-capture.pid
tcpdump -n -i br-lan -c 64 -s 512 -U -w {work}/client.pcap 'port 53 and (host 172.31.255.2 or host {client_ipv6})' >{work}/client-capture.log 2>&1 &
echo $! >{work}/client-capture.pid
sleep 1
''')
    try:
        address = fake_dns()
        fake_dns('2001:db8::53')
        dns_tcp('203.0.113.53', 'tcp4.example.com')
        dns_tcp('2001:db8::53', 'tcp6.example.com')
        internet_check(address)
    except Exception:
        print(remote(f'tcpdump -n -r {work}/client.pcap 2>/dev/null; cat {work}/*capture.log', check=False), flush=True)
        print(remote('nft list chain inet fw4 dstnat; ip -6 route show'), flush=True)
        raise
    finally:
        remote(f'''kill -INT $(cat {work}/capture.pid) $(cat {work}/core-capture.pid) $(cat {work}/client-capture.pid) 2>/dev/null || true
sleep 1
''', check=False)
    leaked = len(pcap_packets('leak'))
    forwarded = sum(b'\x07example\x03com' in packet for packet in pcap_packets('core'))
    assert leaked == 0 and forwarded >= 3, f'DNS 路径异常：外泄={leaked}，内核查询={forwarded}'
    return address


def pcap_packets(name):
    data = remote(f'cat {work}/{name}.pcap', binary=True)
    assert len(data) >= 24 and len(data) < 65536, '抓包结果格式或大小不正确'
    endian = '<' if data[:4] == b'\xd4\xc3\xb2\xa1' else '>'
    offset = 24
    packets = []
    while offset < len(data):
        size = struct.unpack(endian + 'IIII', data[offset:offset + 16])[2]
        packets.append(data[offset + 16:offset + 16 + size])
        offset += 16 + size
    return packets


def reboot_test(auto_connect):
    old_boot = remote('cat /proc/sys/kernel/random/boot_id')
    remote(f'uci set ecycloud.config.auto_connect={auto_connect}; uci commit ecycloud')
    remote('reboot', check=False)
    wait_for(lambda: remote('cat /proc/sys/kernel/random/boot_id') != old_boot, '路由器未完成重启', seconds=120)
    expected = 'running' if auto_connect else 'stopped'
    wait_for(lambda: status()['running'] and status()['stage'] == expected, '重启后的自动连接状态不正确', seconds=120)
    assert status()['enabled'] == bool(auto_connect)
    assert json.loads(remote("ubus call luci.ecycloud status '{}'"))['session']['logged_in']
    print(f'重启回归通过：auto_connect={auto_connect}，阶段={expected}', flush=True)


def settings_snapshot():
    return json.loads(remote('''ucode -e 'let uci=require("uci").cursor();let options={};for(let key in ["mode","enabled","auto_connect","ipv6","router_proxy","dns_hijack"])options[key]=uci.get("ecycloud","config",key);print(sprintf("%J",options));' '''))


def crash_test(mode):
    original_pid = pid()
    assert original_pid.isdigit() and int(original_pid) > 1, '没有可测试的内核进程'
    since = status()['connected_at']
    output = remote(f'''set -eu
kill -KILL {original_pid}
for second in 0 1 2 3 4 5 6 7 8 9 10; do
    if [ ! -e /var/run/ecycloud/network.json ]; then
        echo "$second"
        break
    fi
    sleep 1
done
''', timeout=20)
    assert output.isdigit(), '内核异常退出后未观察到撤销网络接管'
    wait_for(lambda: pid() != original_pid and status()['running'] and status()['stage'] == 'running', '内核异常退出后没有恢复连接', seconds=60)
    dns_capture()
    assert status()['connected_at'] > since, '内核实际重启后仍显示旧连接计时'
    print(f'{mode}：强杀内核后 {output} 秒内撤销接管、自动恢复及 LAN DNS/HTTPS 通过', flush=True)


remote(f'''set -eu
test ! -e {work}
test ! -e /var/run/netns/{namespace}
test ! -e /sys/class/net/ecvtest
test ! -e /sys/class/net/ecptest
! ip -4 address show dev br-lan | grep -q '172.31.255.1/'
test -z "$(uci changes ecycloud)"
''')
snapshot = settings_snapshot()
router_ipv6 = ipaddress.IPv6Interface(remote("ip -6 -o address show dev br-lan scope global | awk '{print $4}'").splitlines()[0]).ip
client_ipv6 = ipaddress.IPv6Network((router_ipv6, 64), strict=False).network_address + 0xEC05
credentials_hash = remote('sha256sum /etc/ecycloud/credentials.json').split()[0]
geo_before = geo_fingerprint()
try:
    setup_client()
    for mode in ('tproxy', 'tun'):
        configure(mode=mode, ipv6=0 if args.ipv6_off_only else 1, dns_hijack=1, auto_connect=0)
        original_pid = pid()
        start()
        if args.ipv6_off_only:
            rules = remote('ip -6 rule show; ip -6 route show table all')
            assert 'lookup 1936' not in rules and 'lookup 1937' not in rules and 'table 1937' not in rules, 'IPv6 关闭后仍存在内核 IPv6 策略路由'
        dns_capture()
        assert pid() == original_pid, '连接操作重启了内核'
        stop()
        assert pid() == original_pid, '断开操作重启了内核'
        if args.ipv6_off_only:
            print(f'{mode}：IPv6 关闭后的路由与双协议 DNS 劫持通过', flush=True)
            continue
        start()
        if args.crash_only:
            crash_test(mode)
            stop()
            continue
        address = fake_dns()
        since = status()['connected_at']
        remote('ubus call network.interface.wan down')
        try:
            time.sleep(3)
            assert status()['stage'] == 'running' and pid() == original_pid, 'WAN 断线改变了内核或接管状态'
            assert fake_dns() == address, 'WAN 断线后局域网 DNS 映射不可用'
        finally:
            remote('ubus call network.interface.wan up')
        wait_for(lambda: json.loads(remote("ubus call network.interface.wan status '{}'"))['up'], 'WAN 重连失败', seconds=60)
        wait_for(lambda: internet_check(address) is None, 'WAN 重连后无法访问网络', seconds=45)
        assert pid() == original_pid and status()['connected_at'] == since, 'WAN 重连重置了连接或内核'
        print(f'{mode}：IPv4/IPv6 UDP/TCP DNS 劫持、LAN HTTPS、WAN 断线重连、内核复用通过', flush=True)
        if args.alternate_gateway:
            default_route = remote('ip -4 route show default').splitlines()[0]
            try:
                remote(f'ip route replace default via {shlex.quote(args.alternate_gateway)} dev br-lan')
                internet_check(address)
                assert pid() == original_pid and status()['connected_at'] == since
            finally:
                remote(f'ip route replace {default_route}')
            internet_check(address)
            print(f'{mode}：切换备用出口及恢复通过', flush=True)
        stop()
    if args.reboot:
        remove_client()
        remote(f'rm -f {work}/*; rmdir {work}')
        configure(mode='tun', ipv6=1, auto_connect=0)
        start()
        reboot_test(1)
        reboot_test(0)
    assert remote('sha256sum /etc/ecycloud/credentials.json').split()[0] == credentials_hash, '测试改变了登录凭据'
    assert geo_fingerprint() == geo_before, '重启重新下载或修改了 GEO 文件'
    print('凭据与 GEO 缓存保留检查通过', flush=True)
finally:
    remove_client()
    restore = []
    for key, value in snapshot.items():
        restore.append(f'uci delete ecycloud.config.{key}' if value is None else f'uci set ecycloud.config.{key}={shlex.quote(value)}')
    remote('uci set ecycloud.config.enabled=0; uci commit ecycloud; /etc/init.d/ecycloud stop', check=False)
    remote('\n'.join(restore + ['uci commit ecycloud', '/etc/init.d/ecycloud start']), timeout=120)
    remote(f'rm -f {work}/*; rmdir {work} 2>/dev/null || true')
    expected = 'running' if snapshot['enabled'] == '1' else 'stopped'
    wait_for(lambda: status()['running'] and status()['stage'] == expected, '原始连接状态未恢复', seconds=90)
    assert settings_snapshot() == snapshot, '原始 UCI 设置未完整恢复'
    remote(f'test ! -e {work}; test ! -e /var/run/netns/{namespace}; test ! -e /sys/class/net/ecvtest; ! ip -4 address show dev br-lan | grep -q "172.31.255.1/"')
    print('已恢复测试路由器原设置并清理测试网络', flush=True)
