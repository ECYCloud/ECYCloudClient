'use strict';

import { testState } from 'fs';
import { ACCOUNT_FILE, ANNOUNCE_CACHE, API_FILE, ANNOUNCE_FILE, CRED_FILE, NETWORK_FILE, PROFILE_FILE,
         coreRunning, sessionBinding, httpRequest, lanDevices, origins, randomHex, settings } from 'ecycloud.common';
import { call, clearToken, login, loginWithVerifyCode, logout, refreshAccount } from 'ecycloud.panel';
import { acceptIconUrl, imageExt, sync as syncIcons } from 'ecycloud.icons';
import { closeConnection } from 'ecycloud.clash';
import { assemble, cached, inspect, maskRuntime, readRunFile } from 'ecycloud.profile';
import { applySelectors, changeSession, collectGarbage, rememberSelector, selectors } from 'ecycloud.service';
import { apply, revert } from 'ecycloud.network';

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
for (let section in [ 'rule-providers', 'proxy-providers' ]) {
	const config = { ...remote };
	for (let url in [ 'http://panel.test/rules.mrs', 'HTTP://panel.test/rules.mrs', 'ftp://panel.test/rules.mrs' ]) {
		config[section] = { test: { type: 'http', url, path: 'rules/test.mrs' } };
		const checked = inspect(config);
		check(!checked.ok && index(checked.error, '的下载地址必须使用 https') >= 0, `${section} 必须拒绝非 https 下载地址：${url}`);
	}
	config[section] = { test: { type: 'http', url: 'HTTPS://panel.test/rules.mrs', path: 'rules/test.mrs' } };
	check(inspect(config).ok, `${section} 的 https 下载地址必须照常放行`);
}
for (let section in [ 'rule-providers', 'proxy-providers' ]) {
	const config = { ...remote };
	for (let key in [ 'URL', 'Url' ]) {
		const spec = { type: 'http', url: 'https://panel.test/rules.mrs', path: 'rules/test.mrs' };
		spec[key] = 'http://panel.test/rules.mrs';
		config[section] = { test: spec };
		const checked = inspect(config);
		check(!checked.ok && index(checked.error, '的下载地址必须使用 https') >= 0, `${section} 的 ${key} 键同样必须使用 https`);
		config[section] = { test: { type: 'http', path: 'rules/test.mrs' } };
		config[section].test[key] = 'http://panel.test/rules.mrs';
		check(!inspect(config).ok, `${section} 只写 ${key} 键的 http 下载地址不能放行`);
	}
	for (let key in [ 'PATH', 'Path' ]) {
		const spec = { type: 'http', url: 'https://panel.test/rules.mrs', path: 'rules/test.mrs' };
		spec[key] = './config.json';
		config[section] = { test: spec };
		const checked = inspect(config);
		check(!checked.ok && index(checked.error, '的保存路径必须位于运行目录内') >= 0, `${section} 的 ${key} 键同样不能指向客户端文件`);
	}
	config[section] = { test: { type: 'http', url: 'https://panel.test/rules.mrs', URL: 'https://panel.test/rules.mrs',
		path: 'rules/test.mrs', Path: 'rules/test.mrs' } };
	check(inspect(config).ok, `${section} 大小写不同的合法地址与路径键必须照常放行`);
}
const proxyPath = inspect({ ...remote, 'proxy-providers': { test: { type: 'http', url: 'https://panel.test/nodes', PATH: '../credentials.json' } } });
check(!proxyPath.ok && index(proxyPath.error, '的保存路径必须位于运行目录内') >= 0, '节点订阅只写大写 PATH 键时也必须检查保存路径');
const geoxChecked = inspect({ ...remote, 'geox-url': { geoip: 'http://mirror.test/geoip.dat', mmdb: 'https://mirror.test/geoip.metadb' } });
check(!geoxChecked.ok && index(geoxChecked.error, 'geox-url「geoip」必须使用 https') >= 0, '面板下发的 http geox-url 必须拒绝');
check(inspect({ ...remote, 'geox-url': { geoip: 'https://mirror.test/geoip.dat', mmdb: 'https://mirror.test/geoip.metadb', asn: '' } }).ok,
	'https 的 geox-url 必须照常放行');
const geoxBase = testState.config.geox_base;
for (let base in [ 'http://mirror.test/Clash', ' ftp://mirror.test/Clash', '//mirror.test/Clash' ]) {
	testState.config.geox_base = base;
	const refused = assemble(remote, settings(), { port: 19090, secret: 'test', speed: 'synthetic-speed' });
	check(!refused.ok && refused.error == 'GeoData 镜像地址必须使用 https', `GeoData 镜像地址必须使用 https：${base}`);
}
testState.config.geox_base = 'HTTPS://mirror.test/Clash/';
const mirrored = assemble(remote, settings(), { port: 19090, secret: 'test', speed: 'synthetic-speed' });
check(mirrored.ok && mirrored.config['geox-url'].mmdb == 'HTTPS://mirror.test/Clash/geoip.metadb', 'https 的 GeoData 镜像地址必须照常使用');
testState.config.geox_base = ' ';
check(assemble(remote, settings(), { port: 19090, secret: 'test', speed: 'synthetic-speed' }).ok, 'GeoData 镜像地址留空必须沿用面板地址');
testState.config.geox_base = geoxBase;
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

testState.files[CRED_FILE] = sprintf('%J', { token: 'fixture-token', session_id: 'fixture-session', account_key: 'fixture-session', expires_at: '2030-01-01T00:00:00Z' });
testState.config.run_dir = '/other-account';
testState.paths['/other-account'] = '/other-account';
testState.paths['/other-account/private.txt'] = '/other-account/private.txt';
testState.info['/other-account/private.txt'] = { type: 'file', size: 6 };
testState.files['/other-account/private.txt'] = 'secret';
check(settings().runDir == '/etc/ecycloud/run/fixture-session' && readRunFile('private.txt').text != 'secret',
	'插件 UCI 写权限不能把读取根目录改到其他账户或系统目录');
testState.config.run_dir = '/etc/ecycloud/run/fixture-session';
for (let name in [ 'tun" accept\n}', 'tun\ninclude "/etc/private"', '../device', 'a b', 'abcdefghijklmnop', 'tun\0hidden' ]) {
	testState.config.tun_device = name;
	check(settings().tunDevice == '', `必须拒绝防火墙规则中的非法网卡名：${sprintf('%J', name)}`);
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

testState.paths['/etc/ecycloud/run/fixture-session'] = '/etc/ecycloud/run/fixture-session';
testState.paths['/etc/ecycloud/run/fixture-session/rules.txt'] = '/etc/ecycloud/run/fixture-session/rules.txt';
testState.info['/etc/ecycloud/run/fixture-session/rules.txt'] = { type: 'file', size: 4 };
testState.files['/etc/ecycloud/run/fixture-session/rules.txt'] = 'rule';
check(readRunFile('./rules.txt').text == 'rule', '合法规则文件读取失败');
testState.paths['/etc/ecycloud/run/fixture-session/escape'] = '/etc/shadow';
check(!readRunFile('escape').ok, '不能通过软链接越界读取');
check(!readRunFile('../shadow').ok, '不能通过相对路径越界读取');
check(!readRunFile('config.json').ok && !readRunFile('./cache.db').ok, '规则文件查看不能读出客户端自己的运行文件');
testState.paths['/etc/ecycloud/run/fixture-session/ecy-panel-nodes.json'] = '/etc/ecycloud/run/fixture-session/ecy-panel-nodes.json';
testState.info['/etc/ecycloud/run/fixture-session/ecy-panel-nodes.json'] = { type: 'file', size: 23 };
testState.files['/etc/ecycloud/run/fixture-session/ecy-panel-nodes.json'] = '{"proxies":[{"uuid":1}]}';
check(!readRunFile('ecy-panel-nodes.json').ok && !readRunFile('./ECY-PANEL-nodes.json').ok, '规则文件查看不能读出含节点凭据的面板节点文件');
const shownRuntime = maskRuntime({ secret: 'control-secret', 'external-controller': '127.0.0.1:9090',
	listeners: [ { name: 'ecy-speed', users: [ { username: 'ecy-speed', password: 'speed-digest' } ] } ],
	proxies: [ { name: 'node-1', server: 'node.example.test', uuid: 'device-uuid' } ],
	'proxy-providers': { 'ecy-panel-nodes': { type: 'file', payload: [
		{ name: 'node-2', password: 'device-password', 'plugin-opts': { password: 'nested-secret' } },
		{ name: 'node-3', auth: 'device-auth' },
		{ name: 'node-4', uuid: 'reality-uuid', 'reality-opts': { 'public-key': 'reality-public-key', 'short-id': '0123abcd' } } ] } } });
check(index(shownRuntime, 'control-secret') < 0 && index(shownRuntime, 'speed-digest') < 0 && index(shownRuntime, '127.0.0.1:9090') >= 0,
	'运行配置展示不含控制密钥与测速口令');
check(index(shownRuntime, 'device-uuid') < 0 && index(shownRuntime, 'device-password') < 0 && index(shownRuntime, 'nested-secret') < 0 &&
	index(shownRuntime, 'device-auth') < 0 && index(shownRuntime, 'node.example.test') >= 0, '运行配置展示不含本设备的节点凭据');
check(index(shownRuntime, 'reality-public-key') < 0 && index(shownRuntime, '0123abcd') < 0, 'VLESS Reality 的 public-key 与 short-id 必须打码');
check(maskRuntime(null) == null, '没有运行配置时不返回内容');
testState.info['/etc/ecycloud/run/fixture-session/rules.txt'].type = 'fifo';
check(!readRunFile('rules.txt').ok, '不能读取特殊文件');
testState.info['/etc/ecycloud/run/fixture-session/rules.txt'] = { type: 'file', size: 8 * 1024 * 1024 + 1 };
check(!readRunFile('rules.txt').ok, '不能读取超大文件');
testState.random = '0123456789abcdef0123456789abcdef';
const accountA = { expires_at: '2030-01-01T00:00:00Z', token: 'token-a', session_id: 'session-a', account_key: 'session-a', email: 'a@test', device_id: 'test-device' };
const accountB = { expires_at: '2030-01-01T00:00:00Z', token: 'token-b', session_id: 'session-b', account_key: 'session-b', email: 'b@test', device_id: 'test-device' };
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
	const labelProfile = (nodes, groups) => {
		testState.files[PROFILE_FILE] = sprintf('%J', {
			account: accountA.email, node_labels: nodes, group_labels: groups ?? {}, binding: sessionBinding(),
			offline_authorization: { issued_at: 1, valid_until: 2000000000 }
		});
	};
	for (let item in [
		{ nodes: { 'node-1': 'node-1x' }, text: 'node-1 node-1', expected: 'node-1x node-1x', message: '日志替换必须终止' },
		{ nodes: { 'node-1': '$&-$1-$$' }, text: 'node-1', expected: '$&-$1-$$', message: '日志替换必须保持字面量' },
		{ nodes: { 'node-1': '正常节点' }, text: 'node-1 node-1 node-99', expected: '正常节点 正常节点 ', message: '没有显示名的节点标识必须删除' },
		{ nodes: { '': 'label', 'node-1': '正常节点' }, text: 'ab  node-1, [x]', expected: 'ab  正常节点, [x]', message: '面板下发空键的节点名时不能把显示名插进日志的字符之间' },
		{ nodes: { 'node-1': 'HK' }, text: 'using node-1 then node-12', expected: 'using HK then ', message: 'node-1 的显示名不能替换进 node-12' },
		{ nodes: { 'node-1': 'HK', 'node-12': 'JP' }, text: '[node-12] [node-1] node-123,node-1', expected: '[JP] [HK] ,HK',
			message: '互为前缀的节点标识只能替换各自完整的标识' },
		{ nodes: { 'node-5': 'HK 05' }, text: 'xnode-5 node-5x node-5-a a_node-5 node-5', expected: 'xnode-5 node-5x node-5-a a_node-5 HK 05',
			message: '两侧紧挨字母、数字、_ 或 - 的节点标识不能替换也不能删除' },
		{ nodes: { 'node-5': 'HK 05' }, groups: { '香港': 'Hong Kong' }, text: 'using 香港节点[node-5] and 香港[node-5] 香港node-5',
			expected: 'using 香港节点[HK 05] and Hong Kong[HK 05] 香港', message: '较短的策略组名不能替换进更长的中文组名' },
		{ nodes: { 'node-5': 'HK 05' }, groups: { '香港': 'Hong Kong' }, text: '策略组「香港」的成员「node-5」不存在；🇭🇰香港，（node-5）',
			expected: '策略组「Hong Kong」的成员「HK 05」不存在；🇭🇰Hong Kong，（HK 05）', message: '中文标点与国旗表情两侧的标识必须替换' },
		{ nodes: { 'node-5': 'HK 05' }, groups: { 'G12': '香港 01', '香港': 'Hong Kong' }, text: 'using G12[node-5]', expected: 'using Hong Kong 01[HK 05]',
			message: '替换顺序须与 node_labels.dart 一致：按 UTF-16 长度从长到短' },
		{ nodes: { 'node-1': 'node-7', 'node-2': '' }, groups: { 'G': '', 'H': 'node-9' }, text: 'G[node-1] H[node-2] G-x node-1x', expected: '[] [] G-x node-1x',
			message: 'node-数字 形式或空的显示名必须把标识替换成空' },
		{ nodes: { 'node-1': '🇭🇰 香港 01' }, text: 'using 🚀 节点选择[node-1]', expected: 'using 🚀 节点选择[🇭🇰 香港 01]', message: '日志里的节点名必须保留国旗' }
	]) {
		labelProfile(item.nodes, item.groups);
		testState.log = item.text;
		check(rpc.logs.call({ args: { lines: 10 } }).log == item.expected, item.message);
	}
	labelProfile({ 'node-1': '🇭🇰 香港 01', 'node-3': 'node-7' }, { 'G': '', 'H': 'node-9' });
	testState.files['/var/run/ecycloud/connections.json'] = sprintf('%J', { binding: sessionBinding(), at: 1, closed: [],
		alive: { c1: { id: 'c1', rule: 'Match', chains: [ 'node-1', 'G', 'H', 'node-3', '🚀 节点选择' ] } } });
	check(join('|', rpc.connections.call({ args: {} }).connections[0].chains) == '🇭🇰 香港 01||||🚀 节点选择',
		'连接链路的节点名必须保留国旗，node-数字 形式或空的显示名显示为空');
	delete testState.files['/var/run/ecycloud/connections.json'];
	testState.files[PROFILE_FILE] = sprintf('%J', {
		account: accountA.email, binding: sessionBinding(), offline_authorization: { issued_at: 1, valid_until: 2000000000 },
		node_labels: { 'node-1': '\u3000🇭🇰 香港 01 \ufeff', 'node-2': ' \t\u00a0', 'node-3': ' node-5 ', 'node-4': '退\u2009' },
		group_labels: { 'G': '\u205f主节点\u00a0' },
		config: { proxies: map([ 'node-1', 'node-2', 'node-3', 'node-4' ], name => ({ name, type: 'ss' })),
			'proxy-groups': [ { name: 'G', type: 'select', proxies: [ 'node-1', 'node-2', 'node-3', 'node-4' ] } ], rules: [ 'MATCH,G' ] }
	});
	const shownLabels = group => `${group?.label}|${join('|', map(group?.members ?? [], member => member.label))}|${group?.now_label}`;
	check(shownLabels(rpc.groups.call({ args: {} }).groups?.[0]) == '主节点|🇭🇰 香港 01| \t\u00a0|node-5|退|',
		'节点页显示名必须与 displayName 一样去掉首尾空白（含全角空格等 Unicode 空白），去空了保留原名');
	testState.files[API_FILE] = sprintf('%J', { port: 19090, secret: 'synthetic-secret', speed: 'synthetic-speed' });
	testState.response = { proxies: { G: { type: 'Selector', now: 'node-1', all: [ 'node-1', 'node-2', 'node-3', 'node-4' ] } } };
	check(shownLabels(rpc.groups.call({ args: {} }).groups?.[0]) == '主节点|🇭🇰 香港 01| \t\u00a0|node-5|退|🇭🇰 香港 01',
		'内核运行时节点页与当前选中的显示名同样去掉首尾空白');
	delete testState.files[API_FILE];
	testState.response = null;
	testState.files['/var/run/ecycloud/connections.json'] = sprintf('%J', { binding: sessionBinding(), at: 1, closed: [],
		alive: { c1: { id: 'c1', rule: 'Match', chains: [ 'node-1', 'G' ] } } });
	testState.log = 'using G[node-1]';
	check(join('|', rpc.connections.call({ args: {} }).connections[0].chains) == '\u3000🇭🇰 香港 01 \ufeff|\u205f主节点\u00a0' &&
		rpc.logs.call({ args: { lines: 10 } }).log == 'using \u205f主节点\u00a0[\u3000🇭🇰 香港 01 \ufeff]',
		'连接链路与日志同 fullName，显示名原样保留');
	delete testState.files['/var/run/ecycloud/connections.json'];
	testState.files['/etc/ecycloud/run/session-a/config.json'] = sprintf('%J', {
		proxies: [ { name: 'node-1', type: 'ss' }, { name: 'node-12', type: 'ss' } ],
		'proxy-groups': [ { name: 'G', type: 'select', proxies: [ 'node-1', 'node-12' ] } ],
		rules: [ 'MATCH,node-1', 'DOMAIN,example.com,node-12' ]
	});
	labelProfile({ 'node-1': 'HK "1" \\' });
	let runtimeShown = null;
	try { runtimeShown = json(rpc.update.call({ args: { what: 'runtime' } }).text); } catch (e) {}
	check(runtimeShown?.proxies?.[0]?.name == 'HK "1" \\' && runtimeShown.proxies[1].name == '' &&
		join('|', runtimeShown['proxy-groups'][0].proxies) == 'HK "1" \\|' && runtimeShown.rules[0] == 'MATCH,HK "1" \\' &&
		runtimeShown.rules[1] == 'DOMAIN,example.com,', '运行配置只替换带引号或逗号边界的整段标识，显示名必须按 JSON 转义');
	delete testState.files['/etc/ecycloud/run/session-a/config.json'];
}

let failedCommand = '';
global.system = command => {
	push(testState.commands, command);
	if (failedCommand == command)
		return 1;
	const target = match(command, /^rm -rf -- '([^']+)'$/);
	if (target)
		for (let path in keys(testState.files))
			if (path == target[1] || index(path, `${target[1]}/`) == 0)
				delete testState.files[path];
	return 0;
};
let called = 0;
const action = () => { called++; return { ok: true }; };
testState.files[CRED_FILE] = sprintf('%J', { device_id: 'test-device' });
testState.files['/etc/ecycloud/run/session-a/config.json'] = 'private-old-profile';
testState.files['/proc/41/cmdline'] = '/usr/libexec/mihomo\0-d\0/etc/ecycloud/run/session-a\0';
testState.files['/etc/ecycloud/selectors.json'] = sprintf('%J', { group: 'old' });
check(length(selectors()) == 0, '无账户归属的旧选中节点不能使用');
testState.commands = [];
check(changeSession(action, false).ok && called == 1 && !length(testState.commands), '登录不做任何清理，也不等待旧服务');
testState.files[CRED_FILE] = sprintf('%J', accountB);
check(settings().runDir == '/etc/ecycloud/run/session-b' && !coreRunning(),
	'新账号只使用自己的运行目录，旧账号仍在跑的内核不算当前内核');
check(testState.files['/etc/ecycloud/run/session-a/config.json'] != null, '登录不能删除旧账号数据');
collectGarbage();
check(testState.files['/etc/ecycloud/run/session-a/config.json'] == null, '回收必须删除不属于当前会话的运行目录');
delete testState.files['/proc/41/cmdline'];
testState.files[CRED_FILE] = sprintf('%J', { device_id: 'test-device' });
testState.authBusy = true;
check(!changeSession(action, false).ok && called == 1, '并行账户切换必须被拒绝');
testState.authBusy = false;

testState.files[CRED_FILE] = sprintf('%J', accountA);
rememberSelector('group', 'node-2');
rememberSelector('secondary', 'node-2');
testState.files[PROFILE_FILE] = sprintf('%J', { account: accountA.email, config: remote, binding: sessionBinding(), offline_authorization: { issued_at: 1, valid_until: 2000000000 } });
testState.files['/etc/ecycloud/run/session-a/config.json'] = 'old-config';
testState.files['/var/run/ecycloud/api.json'] = 'old-api';
testState.response = { ret: 1, msg: 'logged out' };
check(changeSession(logout, true).ok, '退出账户应成功');
collectGarbage();
check(testState.files['/etc/ecycloud/selectors.json'] != null &&
	json(testState.files['/etc/ecycloud/selectors.json']).selected.secondary == 'node-2',
	'退出后必须保留各组选中节点');
check(length(selectors()) == 0 && !length(json(testState.files[CRED_FILE]).token),
	'退出后不能使用选择记录或旧令牌');
for (let path in [ PROFILE_FILE, '/etc/ecycloud/run/session-a/config.json', '/var/run/ecycloud/api.json' ])
	check(testState.files[path] == null, `退出后的回收必须清理敏感缓存：${path}`);
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
const configBeforeTun = { ...testState.config };
testState.config = { ...configBeforeTun, enabled: '1', mode: 'tun', dns_hijack: '0', device: 'br-lan', router_proxy: '1' };
const tunScope = assemble(remote, settings(), { port: 19090, secret: 'test', speed: 'synthetic-speed' });
check(tunScope.ok && join(',', tunScope.config.tun['include-interface'] ?? []) == 'br-lan,lo',
	'TUN 只能接管 LAN 设备与路由器自身，WAN 侧等其它接口的流量不能进内核');
testState.config.router_proxy = '0';
const tunLanOnly = assemble(remote, settings(), { port: 19090, secret: 'test', speed: 'synthetic-speed' });
check(tunLanOnly.ok && join(',', tunLanOnly.config.tun['include-interface'] ?? []) == 'br-lan',
	'不代理路由器自身时 TUN 不得接管 lo，路由器自身流量必须留在主路由表直连');
check(apply(settings()).ok, 'TUN 接管必须成功');
const tunForward = testState.files['/usr/share/nftables.d/chain-pre/forward/ecycloud.nft'];
check(index(tunForward, 'iifname "ECYCloud" oifname { "br-lan" } accept') >= 0 &&
	index(tunForward, 'iifname { "br-lan" } oifname "ECYCloud" accept') >= 0 &&
	!length(filter(split(trim(tunForward), '\n'), line => !match(line, /iifname .+ oifname .+ accept/))),
	'TUN 转发只能放行 LAN 设备与 TUN 之间的流量，不能放行 WAN 侧经路由器进出 TUN');
check(revert(), 'TUN 接管后必须可以恢复');
testState.config = { ...testState.config, dns_hijack: '1', server: [ '223.5.5.5', '9.9.9.9\nconf-file=/etc/shadow' ],
	local: '/lan/\nlog-queries', resolvfile: '/tmp/resolv.auto\nlog-facility=/etc/passwd' };
check(apply(settings()).ok, '主实例 UCI 含非法字符时 TUN 接管仍须成功');
const routerDns = testState.writes['/var/run/ecycloud/router-dns.conf'];
check(index(routerDns, 'server=223.5.5.5\n') >= 0 && index(routerDns, 'no-resolv\n') >= 0 && index(routerDns, '9.9.9.9') < 0 &&
	index(routerDns, 'conf-file') < 0 && index(routerDns, 'log-queries') < 0 && index(routerDns, 'log-facility') < 0,
	'主实例 UCI 里带换行的上游、本地域与 resolv 文件不能注入路由器自身解析实例的配置');
check(revert(), '路由器自身解析实例启动后必须可以恢复');
testState.config = configBeforeTun;
check(acceptIconUrl('http://cdn.example/a.png', 'https://panel.example') == '', '图标地址必须是 https');
check(acceptIconUrl('https://user:pass@cdn.example/a.png', 'https://panel.example') == '', '图标地址不能带账号');
check(acceptIconUrl('//cdn.example/a.png', 'https://panel.example') == '', '图标地址不能是协议相对地址');
check(acceptIconUrl('/images/a.png', 'https://panel.example') == 'https://panel.example/images/a.png', '站内图标必须拼到站点源');
check(acceptIconUrl('https://cdn.example/a.png', 'https://panel.example') == 'https://cdn.example/a.png', '合法 https 图标必须可用');
check(imageExt('<html><body>not-an-icon</body></html>') == '', 'HTML 不能当成图标');
check(imageExt(chr(0x89) + 'PNG\r\n\x1a\n0123') == 'png', 'PNG 图标必须可用');
check(imageExt(chr(0xff, 0xd8, 0xff, 0xe0) + '00000000') == 'jpg', 'JPEG 图标必须可用');
check(imageExt('<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>') == '', 'SVG 不能落盘到 LuCI 同源静态目录');
check(imageExt('<?xml version="1.0"?><svg/>') == '', '带 XML 声明的 SVG 同样拒绝');
testState.files[CRED_FILE] = sprintf('%J', accountA);
testState.files[PROFILE_FILE] = sprintf('%J', { account: accountA.email, config: remote, binding: sessionBinding(),
	offline_authorization: { issued_at: 1, valid_until: 2000000000 }, group_icons: { group: 'https://cdn.example/a.png' } });
let iconConf = '';
testState.onCommand = command => {
	if (index(command, 'curl -q -K ') != 0)
		return;
	for (let path in keys(testState.files))
		if (match(path, /\/icon-[a-f0-9]+\.conf$/)) {
			iconConf = testState.files[path];
			testState.files[replace(path, /\.conf$/, '.bin')] = chr(0x89) + 'PNG\r\n\x1a\n0123';
		}
};
testState.files['/proc/self/stat'] = '4242 (ucode) R 1';
syncIcons();
delete testState.files['/proc/self/stat'];
testState.onCommand = null;
const iconLines = split(iconConf, '\n');
check('location' in iconLines && 'proto = "=https"' in iconLines && 'proto-redir = "=https"' in iconLines && 'max-redirs = 5' in iconLines,
	'图标下载必须跟随跳转，且每一跳都只允许 https、最多跳转 5 次');
check(length(filter(keys(testState.files), path => match(path, /^\/www\/luci-static\/resources\/ecycloud\/icons\/[0-9a-f]{64}\.png$/))) == 1,
	'跳转后取回的图标必须落盘');
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
