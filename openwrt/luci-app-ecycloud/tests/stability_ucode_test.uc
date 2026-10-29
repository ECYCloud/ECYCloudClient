'use strict';

import { testState } from 'fs';
import { API_FILE, CRED_FILE, NETWORK_FILE, PROFILE_FILE, readJson, sessionBinding, settings, writeJson } from 'ecycloud.common';
import { apply, revert } from 'ecycloud.network';
import { assemble, rollback, write } from 'ecycloud.profile';
import { cleanup, refresh, standby, watchdog } from 'ecycloud.service';

function check(ok, message) {
	if (!ok)
		die(message);
};

let failedCommand = '';
let failures = 0;
global.system = command => {
	push(testState.commands, command);
	if (command == failedCommand && failures > 0) {
		failures--;
		return 1;
	}
	return 0;
};

testState.config = { run_dir: '/etc/ecycloud/run', device: 'br-lan', enabled: '1', ipv6: '1' };
testState.files[CRED_FILE] = sprintf('%J', { email: 'router@test', token: 'synthetic-token', device_id: 'fixture', expires_at: '2030-01-01T00:00:00Z' });

const paths = [
	'/usr/share/nftables.d/ruleset-post/ecycloud.nft',
	'/usr/share/nftables.d/chain-pre/input/ecycloud.nft',
	'/usr/share/nftables.d/chain-pre/forward/ecycloud.nft',
	'/usr/share/nftables.d/chain-pre/dstnat/ecycloud.nft',
	'/tmp/dnsmasq.test.d/ecycloud.conf'
];
const cases = [
	{ label: '防火墙规则校验失败', command: 'fw4 check >/dev/null 2>&1' },
	{ label: '防火墙加载失败', command: 'fw4 reload >/dev/null 2>&1' },
	{ label: 'IPv4 策略规则失败', command: 'ip rule add fwmark 502 lookup 1936' },
	{ label: 'IPv4 路由失败', command: 'ip route add local default dev lo table 1936' },
	{ label: 'IPv6 策略规则失败', command: 'ip -6 rule add fwmark 502 lookup 1936' },
	{ label: 'IPv6 路由失败', command: 'ip -6 route add local default dev lo table 1936' },
	{ label: 'DNS 重启失败', command: '/etc/init.d/dnsmasq restart >/dev/null 2>&1' }
];
for (let path in paths)
	push(cases, { label: `写入失败：${path}`, path });

for (let item in cases) {
	testState.config.mode = item.path == paths[2] ? 'tun' : 'tproxy';
	failedCommand = item.command ?? '';
	failures = 1;
	testState.failedWrite = item.path ?? '';
	const result = apply(settings());
	check(!result.ok, `接管失败不能返回成功：${item.label}`);
	check(testState.files[NETWORK_FILE] == null, `恢复成功后不能残留网络记录：${item.label}`);
	for (let path in paths)
		check(testState.files[path] == null, `接管失败后必须清除 ${path}：${item.label}`);
}
failedCommand = '';
testState.failedWrite = '';
testState.config.mode = 'tproxy';
testState.failedRename = true;
check(!apply(settings()).ok, '恢复记录写入失败必须拒绝接管');
testState.failedRename = false;
for (let path in paths)
	check(testState.files[path] == null, '未保存恢复记录时不能写入网络规则');
let recordWrites = 0;
testState.onWrite = path => {
	if (index(path, NETWORK_FILE + '.') == 0 && ++recordWrites == 2)
		testState.failedRename = true;
};
check(!apply(settings()).ok, '最终接管状态写入失败必须回滚');
testState.onWrite = null;
testState.failedRename = false;
check(testState.files[NETWORK_FILE] == null, '最终状态写入失败后不能残留恢复记录');
for (let path in paths)
	check(testState.files[path] == null, '最终状态写入失败后必须清除全部网络规则');
check(apply(settings()).ok, '正常 TPROXY 接管必须成功');
check(readJson(NETWORK_FILE).dnsmasq == paths[4], '恢复记录必须包含 DNS 配置文件');
check(revert(), '正常接管必须可以完整恢复');

let recordReady = true;
testState.onWrite = (path) => {
	if (path in paths)
		recordReady = recordReady && readJson(NETWORK_FILE)?.dnsmasq == paths[4];
};
check(apply(settings()).ok && recordReady, '写入规则之前必须保存完整恢复记录');
testState.onWrite = null;
check(revert(), '记录先行的正常接管必须可以恢复');

const snapshot = '/var/run/ecycloud/atomic-test.json';
const previous = { token: 'old', values: [ 1, 2 ] };
testState.files[snapshot] = sprintf('%J', previous);
let targetTouched = false;
testState.onWrite = path => { targetTouched = targetTouched || path == snapshot; };
check(writeJson(snapshot, { token: 'new', values: [ 3 ] }), '正常 JSON 写入必须成功');
check(!targetTouched, '不能截断正在被其它任务读取的 JSON 文件');
testState.onWrite = null;
testState.failedRename = true;
check(!writeJson(snapshot, previous) && readJson(snapshot).token == 'new', '替换失败必须保留上一次完整 JSON');
testState.failedRename = false;
for (let path in testState.files)
	check(index(path, snapshot + '.') != 0, 'JSON 写入失败不能残留临时文件');

const runDir = '/etc/ecycloud/run';
const runtimePath = `${runDir}/config.json`;
testState.files[runtimePath] = sprintf('%J', { mode: 'rule' });
targetTouched = false;
testState.onWrite = path => { targetTouched = targetTouched || path == runtimePath; };
check(write(runDir, { mode: 'global' }).ok && !targetTouched, '内核重启不能读取到写入了一半的运行配置');
check(rollback(runDir) && !targetTouched && readJson(runtimePath).mode == 'rule', '配置回滚也必须完整替换');
testState.onWrite = null;
testState.failedRename = true;
check(!write(runDir, { mode: 'direct' }).ok && readJson(runtimePath).mode == 'rule',
	'备份失败时必须拒绝覆盖运行配置');
testState.failedRename = false;

testState.config.mode = 'tun';
testState.config.enabled = '1';
const tunConfig = assemble({
	proxies: [ { name: 'node', type: 'direct' } ],
	'proxy-groups': [ { name: 'group', type: 'select', proxies: [ 'node' ] } ],
	rules: [ 'MATCH,group' ]
}, settings(), { port: 19090, secret: 'fixture', speed: 'synthetic-speed' });
check(tunConfig.ok && tunConfig.config.tun['iproute2-table-index'] == 1937 &&
	tunConfig.config.tun['iproute2-rule-index'] == 1937, 'TUN 必须使用插件独立的路由表和规则优先级');
check(apply(settings()).ok && index(testState.files[paths[1]], 'iifname "ECYCloud" accept') >= 0 &&
	index(testState.files[paths[2]], 'oifname "ECYCloud" accept') >= 0,
	'TUN 必须同时放行内核的本机接收与转发流量');
check(revert(), 'TUN 接管后必须清除本机接收规则');
testState.failedWrite = paths[1];
check(!apply(settings()).ok && readJson(NETWORK_FILE) == null && testState.files[paths[2]] == null,
	'TUN 本机接收规则写入失败必须回滚全部接管');
testState.failedWrite = '';
testState.files[runtimePath] = sprintf('%J', tunConfig.config);
testState.files['/proc/41/cmdline'] = '/usr/libexec/mihomo\0-d\0/etc/ecycloud/run\0';
testState.commands = [];
check(apply(settings()).ok && !length(filter(testState.commands, command => index(command, 'rule flush pref') >= 0)),
	'接管时不能清除正在运行的 TUN 路由');
delete testState.files['/proc/41/cmdline'];
failedCommand = 'ip -6 rule flush pref 1947 2>/dev/null';
failures = 1;
check(!revert() && readJson(NETWORK_FILE) != null, '强杀后 TUN 规则删除失败必须保留恢复记录');
failedCommand = '';
check(revert() && readJson(NETWORK_FILE) == null, '强杀后必须清除独立 IPv4 和 IPv6 TUN 规则');
check(length(filter(testState.commands, command => index(command, 'rule flush pref 1937 ') >= 0)) == 4 &&
	!length(filter(testState.commands, command => match(command, /rule flush pref (0|9000|32766|32767) /))),
	'恢复只能删除插件的规则，不能清除系统和其它 VPN 的规则');
testState.files[NETWORK_FILE] = sprintf('%J', { active: false });
testState.responses['ip -N rule show 2>/dev/null'] = { status: 0, text: '1947: from all nop\n' };
check(!revert() && readJson(NETWORK_FILE) != null, '命令返回成功但 TUN 规则仍残留时不能报告恢复成功');
delete testState.responses['ip -N rule show 2>/dev/null'];
check(revert(), '残留规则消失后必须可以完成恢复');
testState.files['/proc/41/cmdline'] = '/usr/libexec/mihomo\0-d\0/etc/ecycloud/run\0';
testState.files[runtimePath] = sprintf('%J', { tun: { enable: false } });
testState.commands = [];
check(revert() && length(filter(testState.commands, command => index(command, 'rule flush pref 1937 ') >= 0)) == 2,
	'待机内核已重启时仍必须清除前一个内核的 TUN 残留');
delete testState.files['/proc/41/cmdline'];

for (let mode in [ 'tun', 'tproxy' ]) {
	testState.config.mode = mode;
	testState.config.enabled = '0';
	testState.commands = [];
	standby();
	check(length(filter(testState.commands, command => index(command,
		'/usr/libexec/ecycloud-ctl revert') >= 0)) == 1,
		`停止 ${mode} 必须撤销对应接管`);
}

testState.config.mode = 'tproxy';
testState.files[PROFILE_FILE] = sprintf('%J', { account: 'router@test', config: {}, binding: sessionBinding(), offline_authorization: { issued_at: 1, valid_until: 2000000000 } });
testState.files[NETWORK_FILE] = sprintf('%J', { dnsmasq: paths[4] });
testState.files[paths[4]] = 'old-dns';
failedCommand = '/etc/init.d/dnsmasq restart >/dev/null 2>&1';
failures = 1;
let rounds = 0;
global.sleep = () => {
	if (++rounds == 2)
		testState.files['/var/run/ecycloud/stopping'] = '';
};
watchdog();
check(testState.files[NETWORK_FILE] == null, '看门狗首次恢复失败后必须继续重试');
delete testState.files['/var/run/ecycloud/stopping'];

testState.config.enabled = '1';
const stale = settings();
let locked = 0;
testState.onLock = path => {
	if (path == '/var/run/ecycloud/network.lock') {
		locked++;
		testState.config.enabled = '0';
	}
};
check(!apply(stale).ok && testState.files[NETWORK_FILE] == null,
	'锁等待期间断开连接后，旧请求不能重新接管网络');
check(revert() && locked == 2, '接管和撤销必须使用同一把网络锁');
testState.onLock = null;

testState.config.enabled = '1';
testState.files['/proc/41/cmdline'] = '/usr/libexec/mihomo\0-d\0/etc/ecycloud/run\0';
testState.files['/var/run/ecycloud/api.json'] = sprintf('%J', { port: 19090, secret: 'fixture' });
testState.response = { version: 'fixture' };
check(apply(settings()).ok, '快速重连测试必须先接管');
rounds = 0;
let reapplied = false;
testState.onRequest = () => {
	for (let path, text in testState.files)
		if (match(path, /\/req-[a-f0-9]+\.conf$/))
			check(index(text, 'url = "http://127.0.0.1:') >= 0, '看门狗不能等待远程面板请求');
};
global.sleep = () => {
	if (++rounds == 1) {
		check(revert(), '快速断开必须成功');
		testState.config.enabled = '1';
	} else {
		reapplied = readJson(NETWORK_FILE)?.active == true;
		testState.files['/var/run/ecycloud/stopping'] = '';
	}
};
watchdog();
check(reapplied, '两轮看门狗之间断开再重连后必须重新接管');
delete testState.files['/var/run/ecycloud/stopping'];
testState.onRequest = null;

let tunClosed = false;
testState.onRequest = () => {
	for (let path, text in testState.files) {
		if (!match(path, /\/req-[a-f0-9]+\.conf$/))
			continue;
		check(index(text, '/configs"') >= 0 && index(text, 'request = "PATCH"') >= 0,
			'结束内核前必须使用控制面关闭 TUN');
		const body = readJson(replace(path, /\.conf$/, '.json'));
		check(body?.tun?.enable === false, '停止时必须关闭正在运行的 TUN');
		tunClosed = true;
	}
};
const originalSystem = global.system;
global.system = command => {
	if (command == 'fw4 reload >/dev/null 2>&1')
		check(tunClosed, '必须先关闭内核 TUN，再恢复防火墙');
	return originalSystem(command);
};
check(cleanup() && tunClosed, '启动中断或模式切换后停止也必须关闭旧内核 TUN');
delete testState.files['/var/run/ecycloud/stopping'];
global.system = originalSystem;
testState.onRequest = null;
check(apply(settings()).ok, '停止失败测试必须先接管');
testState.httpStatus = 500;
check(!cleanup() && readJson(NETWORK_FILE) == null,
	'TUN 关闭失败必须报告失败，同时仍恢复防火墙和 DNS');
testState.httpStatus = 200;
delete testState.files['/var/run/ecycloud/stopping'];
check(apply(settings()).ok, '面板任务测试必须重新接管');

testState.config.site_url = 'https://panel.test';
testState.config.sub_url = 'https://sub.test';
testState.config.refresh_interval = '1';
testState.files[API_FILE] = sprintf('%J', { port: 19090, secret: 'fixture', speed: 'synthetic-speed' });
testState.files[runtimePath] = sprintf('%J', tunConfig.config);
testState.files[PROFILE_FILE] = sprintf('%J', { account: 'router@test', revision: 'r1', binding: sessionBinding(), offline_authorization: { issued_at: 1, valid_until: 2000000000 },
	config: { 'proxy-providers': { 'ecy-panel-nodes': { type: 'file' } } } });
testState.files['/var/run/ecycloud/state.json'] = sprintf('%J', { stage: 'running' });
testState.files['/var/run/ecycloud/updates.json'] = sprintf('%J', { next_check: 2000000000 });
let now = 1000;
let identityRequests = 0;
let connectedRequests = 0;
let profileRequests = 0;
global.time = () => now;
testState.onRequest = () => {
	for (let path, text in testState.files) {
		if (!match(path, /\/req-[a-f0-9]+\.conf$/))
			continue;
		if (index(text, '/config/revision') >= 0)
			identityRequests++;
		if (index(text, '/user/profile') >= 0) {
			profileRequests++;
			if (index(text, 'X-ECY-Connected: 1') >= 0 && index(text, 'X-ECY-Node-Used: 1') >= 0)
				connectedRequests++;
		}
		check(index(text, '/config/clash') < 0, '配置版本未变时不能重复拉取完整配置');
	}
	testState.response = { ret: 1, data: { id: 2, email: 'router@test', config_revision: 'r1' } };
};
global.sleep = duration => {
	now += duration / 1000;
	if (now >= 1062)
		testState.files['/var/run/ecycloud/stopping'] = '';
};
refresh();
check(identityRequests == 2 && connectedRequests == 2 && profileRequests == 3,
	'独立面板任务必须保留每 60 秒心跳、连接上报和配置刷新');
delete testState.files['/var/run/ecycloud/stopping'];
testState.onRequest = null;

delete testState.files['/proc/41/cmdline'];
check(revert(), '长期失联测试必须先恢复网络');
testState.commands = [];
rounds = 0;
global.sleep = () => {
	if (++rounds == 305)
		testState.files['/var/run/ecycloud/stopping'] = '';
};
watchdog();
check(length(filter(testState.commands, command => index(command, '内核 300 秒内未就绪') >= 0)) == 1,
	'长期内核失联不能每秒重复写同一条错误日志');
delete testState.files['/var/run/ecycloud/stopping'];

print('OpenWrt 稳定性回归通过：接管失败恢复、原子写入、TUN 断开与启动中断、恢复重试、快速重连及面板任务隔离。\n');
