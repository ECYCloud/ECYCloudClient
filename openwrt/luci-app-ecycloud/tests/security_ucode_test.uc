'use strict';

import { testState } from 'fs';
import { ACCOUNT_FILE, ANNOUNCE_CACHE, API_FILE, ANNOUNCE_FILE, CRED_FILE, NETWORK_FILE, PROFILE_FILE,
         SESSION_CHANGE, sessionBinding, httpRequest, lanDevices, origins, randomHex, sessionLease, settings } from 'ecycloud.common';
import { call, clearToken, login, loginWithVerifyCode, logout, refreshAccount } from 'ecycloud.panel';
import { acceptIconUrl, imageExt } from 'ecycloud.icons';
import { closeConnection } from 'ecycloud.clash';
import { assemble, cached, inspect, readRunFile } from 'ecycloud.profile';
import { applySelectors, changeSession, rememberSelector, selectors } from 'ecycloud.service';
import { revert } from 'ecycloud.network';

function check(ok, message) {
	if (!ok)
		die(message);
};

for (let url in [ 'file:///etc/shadow', 'https://panel.test/\noutput="/etc/file"', 'https://panel.test/\r', 'https://panel.test/\0x' ])
	check(httpRequest({ url }).status == 0, `必须拒绝地址：${url}`);
check(httpRequest({ url: 'https://panel.test', headers: [ 'X-Test: a\noutput=/etc/file' ] }).status == 0,
	'必须拒绝请求头换行注入');
check(httpRequest({ url: 'https://panel.test', headers: [ 'X-Test: a\0b' ] }).status == 0,
	'必须拒绝请求头 NUL 字符');
check(length(testState.commands) == 0, '非法输入不能调用 curl');

check(httpRequest({ url: 'https://panel.test/?q="x"', headers: [ 'X-Test: "quoted"\\value' ] }).status == 200,
	'合法请求必须保持可用');
let conf = '';
for (let path, content in testState.writes)
	if (match(path, /\.conf$/))
		conf = content;
check(index(conf, 'url = "https://panel.test/?q=\\"x\\""') >= 0, 'URL 必须按 curl 配置语法转义');
check(index(conf, 'header = "X-Test: \\"quoted\\"\\\\value"') >= 0, '请求头必须按 curl 配置语法转义');
check(index(testState.commands[0], 'curl -q -K ') == 0, '不能加载用户 curl 配置');

for (let origin in [ 'https://user@panel.test', 'https://panel.test"', 'https://panel.test\\evil', 'https://panel.test/\n',
	'http://panel.test', 'http://panel.test/path' ]) {
	testState.config.site_url = origin;
	check(origins().site == '', `必须拒绝 origin：${origin}`);
}
testState.config.site_url = 'https://panel.test/path';
check(origins().site == 'https://panel.test', '正常 origin 解析失败');
testState.config.sub_url = 'http://sub.test';
check(origins().sub == 'https://panel.test', 'http 订阅域名必须丢弃并回退到站点域名');
delete testState.config.sub_url;
testState.random = '';
let refused = false;
try { randomHex(16); } catch (e) { refused = true; }
check(refused, '随机数读取失败不能继续生成密钥');

const remote = {
	proxies: [{ name: 'node', type: 'direct' }],
	'proxy-groups': [{ name: 'group', type: 'select', proxies: [ 'node' ] }],
	rules: [ 'MATCH,group' ]
};
for (let section in [ 'rule-providers', 'proxy-providers' ]) {
	for (let path in [ '../credentials.json', '/etc/shadow', 'a/../../x', 'a\\x', 'x:stream', 'CON',
		'config.json', './cache.db', 'proxy-snapshot.json', 'a/.. /x', '.validate-a', 'x\0y' ]) {
		const config = { ...remote };
		config[section] = { test: { type: 'http', url: 'https://panel.test/rules', path } };
		check(!inspect(config).ok, `必须拒绝保存路径：${path}`);
	}
}
const valid = { ...remote, 'rule-providers': { test: { type: 'file', path: './rules/list.txt' } } };
check(inspect(valid).ok, '合法规则路径不能被拒绝');
const withNtp = { ...remote, ntp: { enable: true, server: 'time.example.test', 'write-to-system': true } };
const withServers = { ...remote, iptables: { enable: true }, 'ss-config': 'ss://fixture@:18081',
	'vmess-config': 'vmess://fixture@:18082', 'tuic-server': { enable: true, listen: '0.0.0.0:18083' } };
const closedServers = assemble(withServers, settings(), { port: 19090, secret: 'test', speed: 'synthetic-speed' });
check(closedServers.ok && closedServers.config['ss-config'] == '' && closedServers.config['vmess-config'] == '' &&
	closedServers.config['tuic-server'].enable == false && closedServers.config.iptables.enable == false,
	'面板不能启用额外入站服务和内核自管防火墙');
const assembled = assemble(withNtp, settings(), { port: 19090, secret: 'test', speed: 'synthetic-speed' });
check(assembled.ok && assembled.config.ntp['write-to-system'] == false, '面板校时不能修改系统时钟');
check(assembled.config.ntp.server == 'time.example.test', '面板的校时服务器应保持原值');
check(!assemble(withNtp, settings(), { port: 19090, secret: 'test' }).ok,
	'缺少测速口令必须拒绝生成配置，不能回退到无认证入口');
const withSpeed = assemble(withNtp, settings(), { port: 19090, secret: 'test', speed: 'abcdef0123456789' });
const speedListener = withSpeed.config.listeners[0];
check(length(speedListener.users) == 1 && speedListener.users[0].username == 'ecy-speed' &&
	speedListener.users[0].password == 'abcdef0123456789', '测速入站必须带上 api.speed 口令');

testState.config.run_dir = '/other-account';
testState.paths['/other-account'] = '/other-account';
testState.paths['/other-account/private.txt'] = '/other-account/private.txt';
testState.info['/other-account/private.txt'] = { type: 'file', size: 6 };
testState.files['/other-account/private.txt'] = 'secret';
refused = false;
try { readRunFile('private.txt'); } catch (e) { refused = true; }
check(refused, '插件 UCI 写权限不能把读取根目录改到其他账户或系统目录');
testState.config.run_dir = '/etc/ecycloud/run';
for (let name in [ 'tun" accept\n}', 'tun\ninclude "/etc/private"', '../device', 'a b', 'abcdefghijklmnop' ]) {
	testState.config.tun_device = name;
	refused = false;
	try { settings(); } catch (e) { refused = true; }
	check(refused, `必须拒绝防火墙规则中的非法网卡名：${sprintf('%J', name)}`);
}
testState.config.tun_device = 'ECYCloud';
check(settings().tunDevice == 'ECYCloud', '合法网卡名不能被拒绝');

for (let device in [ 'br-lan" accept\n}', 'eth0\ninclude "/etc/x"', 'eth0\n', 'eth0\0hidden', 'a b', 'dev;evil', 'abcdefghijklmnop' ]) {
	testState.config.device = device;
	check(length(lanDevices()) == 0, `必须过滤防火墙规则中的非法 LAN 网卡名：${sprintf('%J', device)}`);
}
testState.config.device = 'br-lan';
check(lanDevices()[0] == 'br-lan', '合法 LAN 网卡名不能被过滤');
delete testState.config.device;

testState.paths['/etc/ecycloud/run'] = '/etc/ecycloud/run';
testState.paths['/etc/ecycloud/run/rules.txt'] = '/etc/ecycloud/run/rules.txt';
testState.info['/etc/ecycloud/run/rules.txt'] = { type: 'file', size: 4 };
testState.files['/etc/ecycloud/run/rules.txt'] = 'rule';
check(readRunFile('./rules.txt').text == 'rule', '合法规则文件读取失败');
testState.paths['/etc/ecycloud/run/escape'] = '/etc/shadow';
check(!readRunFile('escape').ok, '不能通过软链接越界读取');
check(!readRunFile('../shadow').ok, '不能通过相对路径越界读取');
testState.info['/etc/ecycloud/run/rules.txt'].type = 'fifo';
check(!readRunFile('rules.txt').ok, '不能读取特殊文件');
testState.info['/etc/ecycloud/run/rules.txt'] = { type: 'file', size: 8 * 1024 * 1024 + 1 };
check(!readRunFile('rules.txt').ok, '不能读取超大文件');
testState.random = '0123456789abcdef0123456789abcdef';
const accountA = { expires_at: '2030-01-01T00:00:00Z', token: 'token-a', email: 'a@test', device_id: 'test-device' };
const accountB = { expires_at: '2030-01-01T00:00:00Z', token: 'token-b', email: 'b@test', device_id: 'test-device' };
testState.files[CRED_FILE] = sprintf('%J', accountA);
testState.response = { ret: 1, data: { email: 'a@test', name: 'private-a' } };
testState.onRequest = () => { testState.files[CRED_FILE] = sprintf('%J', accountB); };
check(!refreshAccount().ok, '账户切换后不能接收旧账户的资料');
check(testState.files[ACCOUNT_FILE] == null, '旧账户资料不能污染新账户缓存');

testState.files[CRED_FILE] = sprintf('%J', accountA);
logout();
check(json(testState.files[CRED_FILE]).token == accountB.token, '旧登出请求不能清除新登录会话');
testState.files[CRED_FILE] = sprintf('%J', accountA);
check(!call('/auth/login', { anonymous: true }).ok, '并行登录不能用迟到的响应覆盖新会话');
testState.onRequest = null;
testState.files[CRED_FILE] = sprintf('%J', accountA);
check(refreshAccount().ok, '当前账户的正常请求应保持可用');
check(json(testState.files[ACCOUNT_FILE]).email == accountA.email, '正常账户资料应写入缓存');

testState.files[PROFILE_FILE] = sprintf('%J', { config: remote });
check(cached() == null, '缺少账户归属的历史配置不能授予当前账户');
testState.files[PROFILE_FILE] = sprintf('%J', { account: accountB.email, config: remote });
check(cached() == null, '其他账户的配置不能使用');
testState.files[PROFILE_FILE] = sprintf('%J', { account: accountA.email, config: remote, binding: sessionBinding(), offline_authorization: { issued_at: 1, valid_until: 2000000000 } });
check(cached() != null, '同账户配置应保持可用');
testState.files[ANNOUNCE_CACHE] = '{}';
testState.files[ANNOUNCE_FILE] = '{}';
clearToken();
for (let path in [ ACCOUNT_FILE, ANNOUNCE_CACHE, PROFILE_FILE ])
	check(testState.files[path] == null, `退出时必须清理账户缓存：${path}`);
check(testState.files[ANNOUNCE_FILE] != null, '退出应保留公告已读与弹窗关闭记录');

for (let item in [
	{ status: { enable: 0, ban_reason: '违规使用' }, expected: '账号已被封禁：违规使用' },
	{ status: { enable: 0 }, expected: '账号已被封禁，请到网站查看详情' },
	{ status: { enable: -1 }, expected: '账号正在等待删除，请先到网站取消删除再登录' }
]) {
	testState.response = {
		ret: 1,
		data: { token: 'token-restricted', expires_at: '', account_status: item.status }
	};
	for (let attempt in [ () => login('a@test', 'pw', ''), () => loginWithVerifyCode('a@test', '123456') ]) {
		delete testState.files[CRED_FILE];
		const res = attempt();
		check(!res.ok && res.msg == item.expected, `受限账号必须拒绝登录：${item.expected}`);
		const saved = json(testState.files[CRED_FILE]);
		check(length(saved.device_id) && length(keys(saved)) == 1, '受限账号只可保存设备标识，不得保存会话凭据');
	}
}
delete testState.files[CRED_FILE];
testState.response = {
	ret: 1,
	data: { token: 'token-normal', expires_at: '', user: { email: 'a@test' } }
};
check(login('a@test', 'pw', '').ok, '正常账号登录不能被拒绝');
check(json(testState.files[CRED_FILE]).token == 'token-normal', '正常账号必须写入会话凭据');
for (let status in [ 302, 401, 403, 500 ]) {
	testState.httpStatus = status;
	check(!call('/user/profile').ok, `HTTP ${status} 中的 ret=1 不能当作成功`);
}
delete testState.httpStatus;

if (length(ARGV[0])) {
	const rpc = loadfile(ARGV[0], { raw_mode: true })()['luci.ecycloud'];
	testState.files[CRED_FILE] = sprintf('%J', accountA);
	for (let item in [
		{ label: 'node-1x', text: 'node-1 node-1', expected: 'x x' },
		{ label: '$&-$1-$$', text: 'node-1', expected: '$&-$1-$$' },
		{ label: '正常节点', text: 'node-1 node-1 node-99', expected: '正常节点 正常节点 ' }
	]) {
		testState.files[PROFILE_FILE] = sprintf('%J', {
			account: accountA.email, node_labels: { 'node-1': item.label }, binding: sessionBinding(),
			offline_authorization: { issued_at: 1, valid_until: 2000000000 }
		});
		testState.log = item.text;
		check(rpc.logs.call({ args: { lines: 10 } }).log == item.expected, '日志替换必须终止且保持字面量');
	}
}

let stopFailed = false;
let deleteFailed = false;
let failedCommand = '';
global.sleep = () => {};
global.system = command => {
	push(testState.commands, command);
	if (failedCommand == command)
		return 1;
	const stop = match(command, />(['])(\/var\/run\/ecycloud\/session-stop-[a-f0-9]+)[']/);
	if (stop)
		testState.files[stop[2]] = stopFailed ? '1' : '0';
	if (index(command, 'rm -rf -- ') == 0) {
		if (deleteFailed)
			return 1;
		for (let path in keys(testState.files))
			if (index(path, '/etc/ecycloud/run/') == 0)
				delete testState.files[path];
		delete testState.paths['/etc/ecycloud/run'];
	}
	return 0;
};
let called = 0;
const action = () => { called++; return { ok: true }; };
testState.files[CRED_FILE] = sprintf('%J', { device_id: 'test-device' });
testState.files['/etc/ecycloud/run/config.json'] = 'private-old-profile';
testState.files['/var/run/ecycloud/api.json'] = 'private-old-api';
testState.files['/etc/ecycloud/selectors.json'] = sprintf('%J', { group: 'old' });
check(length(selectors()) == 0, '无账户归属的旧选中节点不能使用');
check(changeSession(action, false).ok && called == 1, '正常停止清理后应允许交接');
check(testState.files['/etc/ecycloud/run/config.json'] == null &&
	testState.files['/var/run/ecycloud/api.json'] == null, '交接前必须清理旧配置和控制密钥');
check(testState.files[SESSION_CHANGE] == null, '成功交接应解除阻止标记');
testState.authBusy = true;
check(!changeSession(action, false).ok && called == 1, '并行账户切换必须被拒绝');
testState.authBusy = false;
for (let failure in [ 'stop', 'worker', 'network', 'delete', 'cache' ]) {
	stopFailed = failure == 'stop';
	testState.workBusy = failure == 'worker';
	testState.commandStatus = failure == 'network' ? 1 : 0;
	deleteFailed = failure == 'delete';
	testState.failedUnlink = failure == 'cache' ? PROFILE_FILE : '';
	testState.files[PROFILE_FILE] = '{}';
	check(!changeSession(action, false).ok && called == 1, `交接失败时不能执行登录：${failure}`);
	check(testState.files[SESSION_CHANGE] != null && sessionLease() == null,
		`失败状态必须阻止新任务：${failure}`);
}
stopFailed = false;
testState.workBusy = false;
testState.commandStatus = 0;
deleteFailed = false;
testState.failedUnlink = '';
check(changeSession(action, false).ok && called == 2, '失败原因消除后应允许重新交接');

testState.files[CRED_FILE] = sprintf('%J', accountA);
rememberSelector('group', 'node-2');
rememberSelector('secondary', 'node-2');
testState.files[PROFILE_FILE] = sprintf('%J', { account: accountA.email, config: remote, binding: sessionBinding(), offline_authorization: { issued_at: 1, valid_until: 2000000000 } });
testState.files['/etc/ecycloud/run/config.json'] = 'old-config';
testState.files['/var/run/ecycloud/api.json'] = 'old-api';
testState.response = { ret: 1, msg: 'logged out' };
check(changeSession(logout, true).ok, '退出账户应成功');
check(testState.files['/etc/ecycloud/selectors.json'] != null &&
	json(testState.files['/etc/ecycloud/selectors.json']).selected.secondary == 'node-2',
	'退出后必须保留各组选中节点');
check(length(selectors()) == 0 && !length(json(testState.files[CRED_FILE]).token),
	'退出后不能使用选择记录或旧令牌');
for (let path in [ PROFILE_FILE, '/etc/ecycloud/run/config.json', '/var/run/ecycloud/api.json' ])
	check(testState.files[path] == null, `退出仍须清理敏感缓存：${path}`);
testState.response = { ret: 1, data: { token: 'new-token-a', user: { email: accountA.email } } };
check(changeSession(() => login(accountA.email, 'pw', ''), false).ok, '同账户重新登录应成功');
check(selectors().group == 'node-2' && selectors().secondary == 'node-2', '新会话应读取原账户的各组选择');
testState.files['/var/run/ecycloud/api.json'] = sprintf('%J', { port: 19090, secret: 'test' });
testState.response = { proxies: {
	group: { type: 'Selector', all: [ 'node-1', 'node-2' ], now: 'node-1' },
	secondary: { type: 'Selector', all: [ 'node-1', 'node-2' ], now: 'node-1' }
} };
let selectedRequests = [];
testState.onRequest = () => {
	for (let path, text in testState.files) {
		if (!match(path, /\/req-[a-f0-9]+\.conf$/) || index(text, 'request = "PUT"') < 0)
			continue;
		push(selectedRequests, { group: match(text, /\/proxies\/([^"\n]+)/)[1],
			name: json(testState.files[replace(path, '.conf', '.json')]).name });
	}
};
applySelectors();
check(length(selectedRequests) == 2 && selectedRequests[0].name == 'node-2' && selectedRequests[1].name == 'node-2',
	'同账户重新登录后必须恢复各组选中节点');
testState.response.proxies.secondary.all = [ 'node-1' ];
selectedRequests = [];
applySelectors();
check(length(selectedRequests) == 1 && selectedRequests[0].group == 'group' && selectedRequests[0].name == 'node-2',
	'只恢复当前内核中仍存在的节点，已移除节点必须忽略');
testState.files[CRED_FILE] = sprintf('%J', accountB);
selectedRequests = [];
check(length(selectors()) == 0, '其他账户不能读取原账户节点选择');
applySelectors();
check(length(selectedRequests) == 0, '其他账户不能恢复原账户节点选择');
testState.onRequest = null;

for (let command in [ 'fw4 reload >/dev/null 2>&1', '/etc/init.d/dnsmasq restart >/dev/null 2>&1' ]) {
	testState.files[NETWORK_FILE] = sprintf('%J', { dnsmasq: '/tmp/dnsmasq.test.d/ecycloud.conf' });
	testState.files['/tmp/dnsmasq.test.d/ecycloud.conf'] = 'old-dns';
	failedCommand = command;
	check(!revert() && testState.files[NETWORK_FILE] != null, '网络恢复命令失败必须保留恢复记录');
	failedCommand = '';
	check(revert() && testState.files[NETWORK_FILE] == null, '网络命令失败后必须支持再次恢复');
}
for (let item in [
	{ command: 'nft list tables 2>/dev/null', text: '', status: 1 },
	{ command: 'ip -N rule show 2>/dev/null', text: '100: from all lookup 1936\n', status: 0 },
	{ command: 'ip -6 -N route show table all 2>/dev/null', text: 'local default dev lo table 1936\n', status: 0 }
]) {
	testState.files[NETWORK_FILE] = '{}';
	testState.responses[item.command] = item;
	check(!revert() && testState.files[NETWORK_FILE] != null, '不能把查询失败或遗留路由当成恢复成功');
	delete testState.responses[item.command];
	check(revert(), '遗留路由消除后必须允许恢复');
}
check(acceptIconUrl('http://cdn.example/a.png', 'https://panel.example') == '', '图标地址必须是 https');
check(acceptIconUrl('https://user:pass@cdn.example/a.png', 'https://panel.example') == '', '图标地址不能带账号');
check(acceptIconUrl('//cdn.example/a.png', 'https://panel.example') == '', '图标地址不能是协议相对地址');
check(acceptIconUrl('/images/a.png', 'https://panel.example') == 'https://panel.example/images/a.png', '站内图标必须拼到站点源');
check(acceptIconUrl('https://cdn.example/a.png', 'https://panel.example') == 'https://cdn.example/a.png', '合法 https 图标必须可用');
check(imageExt('<html><body>not-an-icon</body></html>') == '', 'HTML 不能当成图标');
check(imageExt("\x89PNG\r\n\x1a\n" + '0123') == 'png', 'PNG 图标必须可用');
testState.files[API_FILE] = sprintf('%J', { port: 19090, secret: 'fixture-secret', speed: 'fixture-speed' });
const curlCount = () => length(filter(testState.commands, command => index(command, 'curl ') == 0));
const closeBefore = curlCount();
for (let id in [ '', '../configs', 'a/b', '00000000-0000-0000-0000-00000000000g', '00000000-0000-0000-0000-000000000000/x', [ 'x' ] ])
	check(!closeConnection(id).ok && curlCount() == closeBefore, `连接 id 格式不符不能请求控制面：${id}`);
check(closeConnection('0f8e1c2a-3b4d-4e5f-8a9b-0c1d2e3f4a5b').ok && curlCount() == closeBefore + 1, '合法连接 id 必须可关闭');
let closeConf = '';
for (let path, content in testState.writes)
	if (match(path, /\.conf$/) && index(content, '/connections/') >= 0)
		closeConf = content;
check(index(closeConf, 'url = "http://127.0.0.1:19090/connections/0f8e1c2a-3b4d-4e5f-8a9b-0c1d2e3f4a5b"') >= 0 &&
	index(closeConf, 'request = "DELETE"') >= 0, '关闭连接只能对该 id 发 DELETE');
print('OpenWrt ucode 安全回归通过：curl、origin、随机数、路径、账户切换、缓存清理、日志替换、图标地址和关闭连接 id 校验。\n');
