'use strict';

import { testState } from 'fs';
import { CRED_FILE, PROFILE_FILE, STATE_DIR, panelDirectHosts, panelDirectNets, readJson, sessionBinding, settings } from 'ecycloud.common';
import { call, checkin, refreshAccount } from 'ecycloud.panel';
import { apply, revert } from 'ecycloud.network';
import { assemble, cached } from 'ecycloud.profile';
import { ensureUpdateWorker, runUpdates } from 'ecycloud.service';

let assertions = 0;
function check(ok, message) { assertions++; if (!ok) die(message); };
let now = 1791126000;
global.time = () => now;
global.system = command => { push(testState.commands, command); return 0; };
testState.config = { run_dir: '/etc/ecycloud/run/fixture-session', site_url: 'https://panel.test:8443', sub_url: 'https://sub.test',
	enabled: '1', mode: 'tproxy', router_proxy: '1', ipv6: '1', dns_hijack: '0', device: 'br-lan' };
testState.files[CRED_FILE] = sprintf('%J', { email: 'fixture@test', token: 'synthetic-token', session_id: 'fixture-session', account_key: 'fixture-session',
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

const ruleset = '/usr/share/nftables.d/ruleset-post/ecycloud.nft';
check(apply(settings()).ok, 'TPROXY 接管必须成功');
const nft = testState.files[ruleset];
const lanRules = substr(nft, 0, index(nft, 'chain output'));
const routerRules = substr(nft, index(nft, 'chain output'));
for (let net in nets)
	check(index(lanRules, net) < 0 && index(routerRules, net) >= 0, `TPROXY 只能让路由器自身绕过面板地址 ${net}`);
check(index(routerRules, 'ip daddr { 192.0.2.10/32, 192.0.2.20/32 } accept') >= 0 &&
	index(routerRules, 'ip6 daddr { 2001:db8::10/128, 2001:db8::20/128 } accept') >= 0 &&
	index(routerRules, 'ip6 daddr { ') < index(routerRules, 'meta mark set 502'), '路由器自身代理必须先放行面板地址再打标');
check(revert(), 'TPROXY 必须可以正常恢复');
testState.config.router_proxy = '0';
check(apply(settings()).ok && !length(filter(nets, net => index(testState.files[ruleset], net) >= 0)),
	'不代理路由器自身时面板地址不得出现在防火墙规则中');
check(revert(), '不代理路由器自身的 TPROXY 必须可以正常恢复');
testState.config.router_proxy = '1';

testState.config.mode = 'tun';
const remote = { proxies: [{ name: 'fixture-node', type: 'ss', server: 'node.test',
	port: 10001, cipher: 'aes-128-gcm', password: 'fixture' }],
	'proxy-groups': [{ name: 'Fixture', type: 'select', proxies: ['fixture-node'] }],
	rules: ['MATCH,Fixture'], 'rule-providers': {} };
const profile = assemble(remote, settings(), { port: 19090, secret: 'synthetic-secret', speed: 'synthetic-speed' });
check(profile.ok, `TUN 配置装配必须成功：${profile.error}`);
for (let net in nets)
	check(!(net in profile.config.tun['route-exclude-address']), `TUN 不得让整个局域网绕过面板地址 ${net}`);
check(profile.config.rules[0] == remote.rules[0], '面板直连不得改写业务分流规则');
testState.commands = [];
check(apply(settings()).ok, 'TUN 接管必须成功');
for (let net in nets)
	check(`${index(net, ':') >= 0 ? 'ip -6' : 'ip'} rule add pref 1936 iif lo to ${net} lookup main` in testState.commands,
		`TUN 必须只让路由器自身发起的请求直连面板地址 ${net}`);
testState.files['/etc/ecycloud/run/fixture-session/config.json'] = sprintf('%J', { tun: { enable: true } });
testState.files['/proc/41/cmdline'] = '/usr/libexec/mihomo\0-d\0/etc/ecycloud/run/fixture-session\0';
testState.commands = [];
check(revert() && !length(filter(testState.commands, command => index(command, 'rule flush pref 1936') >= 0)),
	'内核卡死而 TUN 仍在时必须保留路由器直连面板的策略规则');
testState.commands = [];
const reapplied = apply(settings()).ok;
const flushAt = index(testState.commands, 'ip rule flush pref 1936 2>/dev/null');
check(reapplied && flushAt >= 0 && flushAt < index(testState.commands, 'ip rule add pref 1936 iif lo to 192.0.2.10/32 lookup main'),
	'TUN 仍在时重新接管必须先清掉旧的面板直连规则再添加');
delete testState.files['/proc/41/cmdline'];
delete testState.files['/etc/ecycloud/run/fixture-session/config.json'];
testState.commands = [];
check(revert() && length(filter(testState.commands, command => match(command, /^ip( -6)? rule flush pref 1936 /))) == 2,
	'TUN 停止后恢复必须撤销面板直连策略规则');
testState.responses['ip -N rule show 2>/dev/null'] = { status: 0, text: '1936:\tfrom all to 192.0.2.10 iif lo lookup 254\n' };
check(!revert(), '面板直连策略规则残留时不能报告恢复成功');
delete testState.responses['ip -N rule show 2>/dev/null'];
check(revert(), '面板直连策略规则清除后必须可以完成恢复');
global.system = command => { push(testState.commands, command); return command == 'ip rule add pref 1936 iif lo to 192.0.2.20/32 lookup main' ? 1 : 0; };
check(apply(settings()).error == '策略路由设置失败' && testState.files[`${STATE_DIR}/network.json`] == null &&
	testState.files['/usr/share/nftables.d/chain-pre/forward/ecycloud.nft'] == null, '面板直连策略规则添加失败必须回滚全部接管');
global.system = command => { push(testState.commands, command); return 0; };
testState.config.ipv6 = '0';
testState.commands = [];
check(apply(settings()).ok && length(filter(testState.commands, command => index(command, 'ip rule add pref 1936 ') == 0)) == 2 &&
	!length(filter(testState.commands, command => index(command, 'ip -6 rule add pref 1936 ') == 0)),
	'IPv6 关闭时只为 IPv4 面板地址添加策略规则');
check(revert(), 'IPv6 关闭的 TUN 必须可以正常恢复');
testState.config.ipv6 = '1';
testState.config.router_proxy = '0';
testState.commands = [];
check(apply(settings()).ok && 'ip rule flush pref 1936 2>/dev/null' in testState.commands &&
	'ip -6 rule flush pref 1936 2>/dev/null' in testState.commands &&
	!length(filter(testState.commands, command => match(command, /^ip( -6)? rule add pref 1936 /))),
	'不代理路由器自身时本机流量本就不进 TUN，只清旧的面板直连规则，不再添加');
check(revert(), '不代理路由器自身的 TUN 必须可以正常恢复');
testState.config.router_proxy = '1';

now += 301;
testState.responses[siteLookup] = { text: '198.18.1.2\n198.19.1.2\n', status: 0 };
testState.responses[subLookup] = { text: '', status: 1 };
requests = [];
check(call('/user/profile').ok && index(requests[0], 'resolve = "panel.test:8443:192.0.2.10"') >= 0,
	'DNS 超时或只返回 Fake-IP 时必须保留上次真实地址');
check(length(panelDirectNets()) == 4, '解析失败不得清空已知排除地址');

testState.files['/proc/41/cmdline'] = '/usr/libexec/mihomo\0-d\0/etc/ecycloud/run/fixture-session\0';
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

const buildFile = '/usr/share/ecycloud/build.json';
const reachFile = `${STATE_DIR}/panel-reach.json`;
const urlOf = text => match(text, /url = "(https:\/\/[^\/"]+)/)?.[1];
const failNetwork = (exit, count, opts) => {
	transportStatus = 0;
	transportExit = exit;
	for (let i = 0; i < count; i++)
		call('/user/profile', opts);
};
const answer = status => {
	transportStatus = status;
	transportExit = 0;
};
testState.files[buildFile] = sprintf('%J', { site_url: 'https://build-site.test', sub_url: 'https://build-sub.test' });
testState.config.site_url = 'https://moved.test';
testState.config.sub_url = 'https://moved-sub.test';
testState.files[PROFILE_FILE] = sprintf('%J', { account: 'fixture@test', binding: sessionBinding(), config: {},
	offline_authorization: { issued_at: 1, valid_until: 2000000000 } });
const sub = { origin: 'https://moved-sub.test' };
now = 1791200000;
requests = [];
failNetwork(7, 1);
now += 300;
failNetwork(28, 1);
now += 200;
failNetwork(60, 1);
now += 99;
failNetwork(7, 1);
check(length(requests) == 4 && !length(filter(requests, text => urlOf(text) != 'https://moved.test')) && readJson(reachFile)?.['https://moved.test']?.count == 4,
	'连接失败、超时与 TLS 失败都要计数，距第一次失败不足 10 分钟时仍用持久化地址');
now += 1;
requests = [];
answer(200);
check(call('/user/profile').ok && urlOf(requests[0]) == 'https://build-site.test' && testState.config.site_url == 'https://build-site.test' &&
	testState.config.sub_url == 'https://moved-sub.test' && readJson(reachFile)?.['https://moved.test'] == null,
	'连续 3 次网络层失败且已满 10 分钟时必须改用出包地址，成功后落盘并清零计数');
check(cached() != null, '回退到出包地址落盘后同一会话的配置缓存必须继续有效，看门狗不能停服');
requests = [];
check(call('/user/profile').ok && urlOf(requests[0]) == 'https://build-site.test', '落盘后后续请求直接使用出包地址');

failNetwork(7, 2, sub);
answer(500);
call('/user/profile', sub);
check(readJson(reachFile)?.['https://moved-sub.test'] == null, 'HTTP 5xx 说明地址可达，必须清零连续失败');
failNetwork(7, 2, sub);
answer(403);
call('/user/profile', sub);
check(readJson(reachFile)?.['https://moved-sub.test'] == null, 'HTTP 4xx 与鉴权失败都不算网络层失败');
failNetwork(35, 1, sub);
failNetwork(3, 1, sub);
check(readJson(reachFile)?.['https://moved-sub.test']?.count == 1, '非网络层的 curl 错误既不计数也不清零');

failNetwork(7, 2, sub);
now += 600;
requests = [];
failNetwork(7, 1, sub);
check(urlOf(requests[0]) == 'https://build-sub.test' && testState.config.sub_url == 'https://moved-sub.test' &&
	readJson(reachFile)?.['https://moved-sub.test'] == null, '出包地址同样失败时不能落盘，并重新开始计数');
requests = [];
answer(200);
check(call('/user/profile', sub).ok && urlOf(requests[0]) == 'https://moved-sub.test', '出包地址失败后必须改回持久化地址重试');

testState.files[buildFile] = sprintf('%J', { site_url: 'http://plain.test', sub_url: 'https://moved-sub.test' });
testState.config.site_url = 'https://moved.test';
failNetwork(7, 3);
failNetwork(7, 3, sub);
now += 600;
requests = [];
answer(200);
call('/user/profile');
call('/user/profile', sub);
check(urlOf(requests[0]) == 'https://moved.test' && urlOf(requests[1]) == 'https://moved-sub.test',
	'出包地址不是 https 或与持久化地址相同时不能回退');

const probeFile = `${STATE_DIR}/panel-probe.json`;
const updateFile = `${STATE_DIR}/update.json`;
const probesTo = origin => filter(requests, text => urlOf(text) == origin);
const workerStarts = () => length(filter(testState.commands, command => index(command, 'ecycloud-ctl update-tasks') >= 0));
const probeInBackground = () => {
	ensureUpdateWorker();
	runUpdates();
};
let announced = {};
let down = {};
let directDown = {};
let probeStatus = 401;
testState.onRequest = () => {
	let text = '';
	for (let path, value in testState.files)
		if (match(path, /\/req-[a-f0-9]+\.conf$/))
			text = value;
	push(requests, text);
	const failed = down[urlOf(text)] || (directDown[urlOf(text)] && index(text, 'proxy = "http://127.0.0.1:') < 0);
	const probe = index(text, 'Authorization:') < 0;
	testState.httpStatus = failed ? 0 : probe ? probeStatus : 200;
	testState.commandStatus = failed ? 7 : 0;
	testState.response = probe ? { ret: 0, msg: '缺少访问令牌' } : { ret: 1, data: announced };
};
testState.files['/proc/self/status'] = 'Name:\tucode\nPid:\t4242\n';
testState.files[buildFile] = sprintf('%J', { site_url: 'https://build-site.test', sub_url: 'https://build-sub.test' });
testState.config.site_url = 'https://moved.test';
testState.config.sub_url = 'https://moved-sub.test';
testState.files[PROFILE_FILE] = sprintf('%J', { account: 'fixture@test', binding: sessionBinding(), config: {},
	offline_authorization: { issued_at: 1, valid_until: 2000000000 } });
delete testState.files[reachFile];
announced = { enable: 1, site_origin: 'https://moved.test', api_origin: 'https://moved-sub.test' };
down = { 'https://moved.test': true };
now += 3600;
for (let i = 0; i < 3; i++)
	refreshAccount();
now += 600;
requests = [];
testState.commands = [];
check(refreshAccount().ok && checkin().ok && testState.config.site_url == 'https://build-site.test' && cached() != null &&
	!length(probesTo('https://moved.test')) && workerStarts() == 0,
	'请求里不能等探测：回退到出包地址后面板再次下发连不上的地址，请求立即返回并保持出包地址');
probeInBackground();
const blocked = probesTo('https://moved.test');
check(workerStarts() == 1 && readJson(updateFile)?.tasks?.[0]?.kind == 'probe' && length(blocked) == 1 &&
	index(blocked[0], 'url = "https://moved.test/api/client/v1/auth/options"') >= 0 && index(blocked[0], 'Authorization:') < 0,
	'看门狗把待探测的新地址交给后台更新任务，探测不带令牌');
check(readJson(reachFile)?.['https://moved.test'] == null, '探测失败不能计入回退次数');
check(refreshAccount().ok && checkin().ok && testState.config.site_url == 'https://build-site.test' && cached() != null,
	'后台探测失败后请求继续保持原地址');
now += 599;
requests = [];
probeInBackground();
check(!length(probesTo('https://moved.test')), '同一个新地址 10 分钟内最多探测一次');
now += 1;
down = {};
probeStatus = 503;
check(refreshAccount().ok && testState.config.site_url == 'https://build-site.test', '新的探测结果出来前不能切换');
requests = [];
probeInBackground();
check(length(probesTo('https://moved.test')) == 1 && refreshAccount().ok && testState.config.site_url == 'https://moved.test' &&
	cached() != null, '后台探测收到任何 HTTP 响应（含 5xx）后，下一次请求才切换地址并改绑缓存');

probeStatus = 401;
announced = { enable: 1, site_origin: 'https://moved.test', api_origin: 'https://next-sub.test' };
directDown = { 'https://next-sub.test': true };
requests = [];
check(checkin().ok && !length(probesTo('https://next-sub.test')), '签到下发的新配置地址同样不在请求里探测');
probeInBackground();
check(length(probesTo('https://next-sub.test')) == 1 &&
	index(probesTo('https://next-sub.test')[0], 'url = "https://next-sub.test/api/client/v1/config/revision"') >= 0 &&
	checkin().ok && testState.config.sub_url == 'https://moved-sub.test', '内核未运行时直连探测失败即保持当前配置地址');
now += 600;
testState.files['/proc/41/cmdline'] = '/usr/libexec/mihomo\0-d\0/etc/ecycloud/run/fixture-session\0';
requests = [];
probeInBackground();
check(length(probesTo('https://next-sub.test')) == 2 && index(probesTo('https://next-sub.test')[1], 'proxy = "http://127.0.0.1:10203"') >= 0 &&
	checkin().ok && testState.config.sub_url == 'https://next-sub.test', '内核运行时探测与面板请求一样，直连失败后经本地代理再试');
delete testState.files['/proc/41/cmdline'];
directDown = {};

announced = { enable: 1, site_origin: 'https://both.test', api_origin: 'https://both.test' };
down = { 'https://both.test': true };
requests = [];
refreshAccount();
probeInBackground();
check(length(probesTo('https://both.test')) == 1 && refreshAccount().ok && testState.config.site_url == 'https://moved.test' &&
	testState.config.sub_url == 'https://next-sub.test', '站点与配置下发同一个新地址时只探测一次，失败则两者都保持');
down = {};
check(readJson(probeFile)?.['https://moved.test'] == null, '过期的探测记录必须清理');

for (let path in testState.files)
	check(!match(path, /\/(req|resp)-[a-f0-9]+\./), '请求结束必须清理全部临时请求文件');
check(testState.files[addressFile] != null, '地址缓存必须使用既有状态目录');
print(`OpenWrt 面板直连回归通过：${assertions} 项断言。\n`);
