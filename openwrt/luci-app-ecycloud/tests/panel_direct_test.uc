'use strict';

import { testState } from 'fs';
import { CRED_FILE, STATE_DIR, panelDirectHosts, panelDirectNets, settings } from 'ecycloud.common';
import { call } from 'ecycloud.panel';
import { apply, revert } from 'ecycloud.network';
import { assemble } from 'ecycloud.profile';

let assertions = 0;
function check(ok, message) { assertions++; if (!ok) die(message); };
let now = 1791126000;
global.time = () => now;
global.system = command => { push(testState.commands, command); return 0; };
testState.config = { run_dir: '/etc/ecycloud/run', site_url: 'https://panel.test:8443', sub_url: 'https://sub.test',
	enabled: '1', mode: 'tproxy', router_proxy: '1', ipv6: '1', dns_hijack: '0', device: 'br-lan' };
testState.files[CRED_FILE] = sprintf('%J', { email: 'fixture@test', token: 'synthetic-token',
	device_id: 'fixture', expires_at: '2030-01-01T00:00:00Z' });
const siteLookup = "resolveip -t 3 -- 'panel.test' 2>/dev/null";
const subLookup = "resolveip -t 3 -- 'sub.test' 2>/dev/null";
testState.responses[siteLookup] = { text: '198.18.0.1\n198.19.255.254\n2001:db8::10\n192.0.2.10\n192.0.2.10\ninvalid\n', status: 0 };
testState.responses[subLookup] = { text: '192.0.2.20\n2001:db8::20\n', status: 0 };

let requests = [];
let transportStatus = 200;
let transportExit = 0;
let failFirst = false;
testState.onRequest = () => {
	for (let path, text in testState.files)
		if (match(path, /\/req-[a-f0-9]+\.conf$/))
			push(requests, text);
	testState.httpStatus = failFirst && length(requests) == 1 ? 0 : transportStatus;
	testState.commandStatus = failFirst && length(requests) == 1 ? 7 : transportExit;
	testState.response = { ret: testState.httpStatus == 200 ? 1 : 0, data: {} };
};

check(call('/user/profile').ok && length(requests) == 1, '正常面板请求必须只发一次');
check(index(requests[0], 'proxy = ""') >= 0 && index(requests[0], 'noproxy = "*"') >= 0,
	'首轮面板请求必须明确禁用环境代理');
check(index(requests[0], 'url = "https://panel.test:8443/api/client/v1/user/profile"') >= 0 &&
	index(requests[0], 'resolve = "panel.test:8443:192.0.2.10"') >= 0,
	'直连必须绑定真实 IPv4 并保留 URL 域名与端口');
check(index(requests[0], 'insecure') < 0 && index(requests[0], 'Authorization: Bearer synthetic-token') >= 0,
	'直连不得关闭 TLS 校验或丢失原有鉴权头');
check(length(panelDirectHosts(false)['https://panel.test:8443'].addresses) == 2,
	'地址缓存必须去重并过滤 Fake-IP 和非法地址');
const nets = panelDirectNets();
check(length(nets) == 4 && '192.0.2.10/32' in nets && '2001:db8::20/128' in nets,
	'站点与配置域名的 IPv4 和 IPv6 必须一起生成排除网段');
const addressFile = `${STATE_DIR}/panel-addresses.json`;
const originalCache = testState.files[addressFile];
const altered = json(originalCache);
altered.hosts['https://panel.test:8443'] = { host: 'other.test', port: 9999,
	addresses: ['198.18.0.1', '192.0.2.30/24', 'invalid', '192.0.2.10'] };
testState.files[addressFile] = sprintf('%J', altered);
requests = [];
check(call('/user/profile').ok && index(requests[0], 'resolve = "panel.test:8443:192.0.2.10"') >= 0,
	'损坏缓存不得注入目标域名、端口或 Fake-IP');
altered.hosts['https://panel.test:8443'].addresses = ['2001:db8::10'];
testState.files[addressFile] = sprintf('%J', altered);
requests = [];
check(call('/user/profile').ok && index(requests[0], 'resolve = "panel.test:8443:[2001:db8::10]"') >= 0,
	'仅有 IPv6 时必须使用 curl 支持的地址格式');
testState.files[addressFile] = originalCache;
const lookups = length(filter(testState.commands, command => index(command, 'resolveip ') == 0));
requests = [];
check(call('/user/profile').ok && length(filter(testState.commands, command => index(command, 'resolveip ') == 0)) == lookups,
	'五分钟内必须复用地址缓存');

check(apply(settings()).ok, 'TPROXY 接管必须成功');
const nft = testState.files['/usr/share/nftables.d/ruleset-post/ecycloud.nft'];
for (let net in nets)
	check(index(nft, net) >= 0, `TPROXY 必须绕过面板地址 ${net}`);
check(index(nft, 'chain output') >= 0 && index(nft, 'ip daddr @reserved4 accept') >= 0 &&
	index(nft, 'ip6 daddr @reserved6 accept') >= 0, '路由器自身代理必须先放行面板地址');
check(revert(), 'TPROXY 必须可以正常恢复');

testState.config.mode = 'tun';
const remote = { proxies: [{ name: 'fixture-node', type: 'ss', server: 'node.test',
	port: 10001, cipher: 'aes-128-gcm', password: 'fixture' }],
	'proxy-groups': [{ name: 'Fixture', type: 'select', proxies: ['fixture-node'] }],
	rules: ['MATCH,Fixture'], 'rule-providers': {} };
const profile = assemble(remote, settings(), { port: 19090, secret: 'synthetic-secret', speed: 'synthetic-speed' });
check(profile.ok, `TUN 配置装配必须成功：${profile.error}`);
for (let net in nets)
	check(net in profile.config.tun['route-exclude-address'], `TUN 必须绕过面板地址 ${net}`);
check(profile.config.rules[0] == remote.rules[0], '面板直连不得改写业务分流规则');

now += 301;
testState.responses[siteLookup] = { text: '198.18.1.2\n198.19.1.2\n', status: 0 };
testState.responses[subLookup] = { text: '', status: 1 };
requests = [];
check(call('/user/profile').ok && index(requests[0], 'resolve = "panel.test:8443:192.0.2.10"') >= 0,
	'DNS 超时或只返回 Fake-IP 时必须保留上次真实地址');
check(length(panelDirectNets()) == 4, '解析失败不得清空已知排除地址');

testState.files['/proc/41/cmdline'] = '/usr/libexec/mihomo\0-d\0/etc/ecycloud/run\0';
requests = [];
failFirst = true;
check(call('/user/profile').ok && length(requests) == 2, '直连连接失败后必须允许读取请求回退本地代理');
check(index(requests[1], 'proxy = "http://127.0.0.1:10203"') >= 0 && index(requests[1], 'noproxy = ""') >= 0 &&
	index(requests[1], 'resolve = ') < 0, '代理回退必须覆盖环境绕过名单且不携带直连地址绑定');
requests = [];
failFirst = false;
check(call('/user/profile').ok && length(requests) == 1 && index(requests[0], 'proxy = ""') >= 0,
	'代理回退成功后下一次仍必须先直连');

requests = [];
transportStatus = 500;
check(!call('/user/profile').ok && length(requests) == 1, 'HTTP 错误不得切代理重发');
requests = [];
transportStatus = 0;
transportExit = 28;
check(!call('/user/checkin', { method: 'POST', body: {} }).ok && length(requests) == 1,
	'写请求超时不得切代理重放');
requests = [];
failFirst = true;
transportStatus = 200;
transportExit = 0;
check(call('/user/checkin', { method: 'POST', body: {} }).ok && length(requests) == 2,
	'写请求尚未建立连接时必须保留代理回退');
delete testState.files['/proc/41/cmdline'];
requests = [];
check(!call('/user/profile').ok && length(requests) == 1, '内核未运行时不得尝试本地代理');
failFirst = false;

testState.config.site_url = 'https://[2001:db8::77]:8443';
requests = [];
check(call('/user/profile').ok && index(requests[0], 'resolve = ') < 0 && '2001:db8::77/128' in panelDirectNets(),
	'IPv6 字面量必须直接连接并生成主机排除路由');
check(!('192.0.2.10/32' in panelDirectNets()), '面板地址变更后不得复用旧来源地址');

for (let path in testState.files)
	check(!match(path, /\/(req|resp)-[a-f0-9]+\./), '请求结束必须清理全部临时请求文件');
check(testState.files[addressFile] != null, '地址缓存必须使用既有状态目录');
print(`OpenWrt 面板直连回归通过：${assertions} 项断言。\n`);
