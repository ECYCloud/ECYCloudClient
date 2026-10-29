'use strict';

import { testState } from 'fs';
import { API_FILE, CRED_FILE, PROFILE_FILE, readJson, sessionBinding, sessionValid, settings } from 'ecycloud.common';
import { NODE_PROVIDER, SPEED_GROUP, assemble, canUpdateNodes, inspect, membersOf, nodesOf, write, writeNodeProviders } from 'ecycloud.profile';
import { delayBatch, proxies } from 'ecycloud.clash';
import { update } from 'ecycloud.service';

let assertions = 0;
function check(ok, message) {
	assertions++;
	if (!ok)
		die(message);
};

function copy(value) { return json(sprintf('%J', value)); };
const runDir = '/etc/ecycloud/run';
const groupProvider = 'ecy-panel-' + join('', map([ 1, 2, 3, 4 ], () => '0123456789abcdef'));
const initial = {
	proxies: [],
	'proxy-providers': {
		'ecy-panel-nodes': { type: 'file', path: 'ecy-panel-nodes.json', payload: [
			{ name: '节点一', type: 'ss', server: '127.0.0.1', port: 10001, cipher: 'aes-128-gcm', password: 'fixture' }
		] }
	},
	'proxy-groups': [ { name: '代理', type: 'select', use: [ groupProvider ],
		'exclude-filter': '^ecy-panel-empty$', 'empty-fallback': 'REJECT', 'default-selected': '节点一' } ],
	rules: [ 'MATCH,代理' ],
	dns: { enable: true, 'enhanced-mode': 'fake-ip' }
};
initial['proxy-providers'][groupProvider] = { type: 'file', path: `${groupProvider}.json`, payload: copy(nodesOf(initial)) };
testState.config = { run_dir: runDir, site_url: 'https://panel.test', sub_url: 'https://sub.test', enabled: '1', mode: 'tun' };
testState.files[CRED_FILE] = sprintf('%J', { email: 'router@test', token: 'synthetic-token', device_id: 'fixture', expires_at: '2030-01-01T00:00:00Z' });
testState.files[API_FILE] = sprintf('%J', { port: 19090, secret: 'synthetic-secret', speed: 'synthetic-speed' });
testState.files['/proc/41/cmdline'] = `/usr/libexec/mihomo\0-d\0${runDir}\0`;
testState.files[`${runDir}/geoip.metadb`] = 'fixture';
testState.files[`${runDir}/GeoSite.dat`] = 'fixture';
global.system = command => { push(testState.commands, command); return 0; };

check(inspect(initial).ok, '本地节点订阅与 use 策略组必须通过结构检查');
check(nodesOf(initial)[0].name == '节点一' && membersOf(initial, initial['proxy-groups'][0])[0] == '节点一', '节点和离线组成员必须取自 payload');
const ordered = { proxies: [ 'DIRECT', 'REJECT' ], use: [ NODE_PROVIDER ], filter: '^DIRECT$`^(?!(?:DIRECT|REJECT)$).*`^REJECT$' };
check(join(',', membersOf(initial, ordered)) == 'DIRECT,节点一,REJECT', '离线 fallback 顺序必须保留左侧、节点、右侧顺序');
const pinned = copy(initial);
push(pinned['proxy-providers'][NODE_PROVIDER].payload, { ...nodesOf(initial)[0], name: '节点二' }, { ...nodesOf(initial)[0], name: '节点三' });
check(join(',', membersOf(pinned, { use: [ NODE_PROVIDER ],
	filter: '^节点一$`^(?!(?:节点一|节点二)$).*`^节点二$' })) == '节点一,节点三,节点二',
	'固定在左侧或右侧的具体节点也必须保留面板顺序');
const quoted = copy(initial);
quoted['proxy-providers'][NODE_PROVIDER].payload[0].name = '节点`一(测试)';
check(membersOf(quoted, { proxies: [ '节点`一(测试)', 'DIRECT' ], use: [],
	filter: '^节点\\x60一\\(测试\\)$`^DIRECT$' })[0] == '节点`一(测试)', '有序筛选必须保留反引号和正则特殊字符名称');
const speed = assemble(initial, settings(), readJson(API_FILE));
check(speed.ok && speed.config['proxy-groups'][-1].name == SPEED_GROUP &&
	speed.config['proxy-groups'][-1].use[0] == NODE_PROVIDER, '测速组必须复用节点订阅');
for (let mutation in [ 'path', 'type', 'payload', 'name', 'reference' ]) {
	const invalid = copy(initial);
	if (mutation == 'path') invalid['proxy-providers'][NODE_PROVIDER].path = '../credentials.json';
	if (mutation == 'type') invalid['proxy-providers'][NODE_PROVIDER].type = 'http';
	if (mutation == 'payload') invalid['proxy-providers'][NODE_PROVIDER].payload = [];
	if (mutation == 'name') invalid['proxy-providers']['ecy-panel-invalid'] = invalid['proxy-providers'][NODE_PROVIDER];
	if (mutation == 'reference') invalid['proxy-groups'][0].use = [ 'missing' ];
	check(!inspect(invalid).ok, `无效本地节点订阅必须拒绝：${mutation}`);
}
const runtime = speed.config;
check(write(runDir, runtime).ok && writeNodeProviders(runDir, runtime).ok, '初始运行配置与节点文件必须保存成功');
const file = `${runDir}/${NODE_PROVIDER}.json`;
const originalFile = testState.files[file];
for (let info in [ { type: 'link', nlink: 1 }, { type: 'file', nlink: 2 }, { type: 'directory', nlink: 1 } ]) {
	testState.info[file] = info;
	check(!writeNodeProviders(runDir, runtime).ok && testState.files[file] == originalFile, '符号链接、多硬链接和非普通文件必须拒绝，原文件不能改变');
}
delete testState.info[file];
testState.info[runDir] = { type: 'link' };
check(!writeNodeProviders(runDir, runtime).ok, '节点目录本身为符号链接时必须拒绝');
delete testState.info[runDir];
const oversized = copy(runtime);
oversized['proxy-providers'][NODE_PROVIDER].payload[0].server = sprintf('%8388608s', 'x');
check(!writeNodeProviders(runDir, oversized).ok && testState.files[file] == originalFile, '超过 8 MiB 的节点文件必须拒绝，原文件不能改变');

let candidate = copy(initial);
let revision = 'r2';
let requests = [];
let failedProvider = '';
let validationFailed = false;
let expectedBeforeValidation = originalFile;
testState.onCommand = command => {
	if (index(command, ' -t -f ') < 0)
		return;
	check(testState.files[file] == expectedBeforeValidation, '内核校验之前不能覆盖运行中的节点文件');
	for (let path, text in testState.files) {
		if (index(path, `${runDir}/.validate-`) != 0)
			continue;
		const config = json(text);
		check(config['proxy-providers'][NODE_PROVIDER].type == 'inline' && config.profile['store-fake-ip'] == false,
			'校验必须直接使用候选 payload，且不能修改运行中 Fake-IP 数据库');
	}
	testState.commandStatus = validationFailed ? 1 : 0;
	testState.commandText = validationFailed ? 'fixture validation failed' : '';
};
testState.onRequest = () => {
	for (let path, text in testState.files) {
		if (!match(path, /\/req-[a-f0-9]+\.conf$/))
			continue;
		push(requests, text);
		testState.httpStatus = 200;
		if (index(text, '/user/account-status') >= 0)
			testState.response = { ret: 1, data: { enable: 1 } };
		else if (index(text, '/user/profile') >= 0)
			testState.response = { ret: 1, data: { config_revision: revision } };
		else if (index(text, '/config/clash') >= 0) {
			check(index(text, 'X-ECY-Node-Providers: 1') >= 0, 'OpenWrt 必须请求面板节点订阅格式');
			testState.response = { ret: 1, data: { revision, config: candidate, offline_authorization: { issued_at: 1, valid_until: 2000000000 } } };
		} else if (index(text, '/providers/proxies/') >= 0) {
			if (length(failedProvider) && index(text, failedProvider) >= 0) {
				failedProvider = '';
				testState.httpStatus = 500;
				testState.response = { message: 'fixture provider failed' };
			} else
				testState.response = { proxies: [ { name: '节点一', type: 'Shadowsocks', history: [ { delay: 23 } ] } ] };
		} else
			testState.response = { proxies: { '代理': { type: 'Selector', all: [ '节点一' ], now: '节点一' } } };
	}
};
function cache(config, rev) {
	testState.files[PROFILE_FILE] = sprintf('%J', { account: 'router@test', revision: rev, config, binding: sessionBinding(), offline_authorization: { issued_at: 1, valid_until: 2000000000 } });
};
cache(initial, 'r1');
candidate['proxy-providers'][NODE_PROVIDER].payload[0].port = 10002;
candidate['proxy-providers'][groupProvider].payload = copy(nodesOf(candidate));
check(canUpdateNodes(initial, candidate), '仅节点参数变更必须识别为独立更新');
testState.commands = [];
let result = update(false);
check(result.ok && result.changed && result.reloaded == false, 'TUN + Fake-IP 下更新节点也不能整份重载或重启');
check(readJson(file).proxies[0].port == 10002 && readJson(PROFILE_FILE).revision == 'r2', '独立更新成功后必须保存新文件与缓存');
check(length(filter(requests, text => index(text, '/providers/proxies/') >= 0 && index(text, 'request = "PUT"') >= 0)) == 2,
	'所有受管节点订阅必须调用独立更新接口');
function uninterrupted() {
	check(!length(filter(requests, text => index(text, '/configs') >= 0 || index(text, '/connections') >= 0)),
		'节点更新不能重载完整配置、切换 TUN 或关闭已有连接');
	check(!length(filter(testState.commands, command => index(command, '/etc/init.d/') >= 0 || index(command, 'fw4 ') >= 0 || index(command, 'ip rule') >= 0)),
		'节点更新不能重启内核、DNS 或重新接管防火墙与路由');
};
uninterrupted();
const persisted = copy(candidate);
const persistedFile = testState.files[file];
const enriched = proxies();
check(enriched.ok && enriched.data.proxies['节点一'].history[0].delay == 23, '运行中的节点列表必须读取 provider 的实际节点与测速记录');
delayBatch([ '节点一', '代理' ], 500);
check(length(filter(values(testState.writes), text => index(text, `/providers/proxies/${NODE_PROVIDER}/`) >= 0 && index(text, '/healthcheck?') >= 0)) > 0,
	'文件订阅节点必须通过 provider 的逐节点测速接口测延迟');
if (length(ARGV[0])) {
	const rpc = loadfile(ARGV[0], { raw_mode: true })()['luci.ecycloud'];
	const groups = rpc.groups.call({ args: {} }).groups;
	check(groups[0].members[0].protocol == 'Shadowsocks' && groups[0].members[0].delay == 23,
		'LuCI RPC 必须保留 provider 节点的协议与实际延迟');
	const status = rpc.status.call({ args: {} });
	check(status.profile.nodes == 1 && status.profile.servers[0] == '127.0.0.1', 'LuCI 节点数量和流量排除地址必须取自 provider');
	const oldRequest = testState.onRequest;
	delete testState.files['/proc/41/cmdline'];
	const offline = copy(persisted);
	push(offline['proxy-groups'], { name: '隐藏辅助组', type: 'select', use: [ NODE_PROVIDER ], hidden: true });
	cache(offline, 'r2');
	testState.onRequest = () => { testState.httpStatus = 500; testState.response = { message: 'fixture offline' }; };
	const offlineGroups = rpc.groups.call({ args: {} }).groups;
	check(length(offlineGroups) == 1 && offlineGroups[0].members[0].name == '节点一' &&
		offlineGroups[0].members[0].protocol == 'Shadowsocks', '离线节点卡片必须支持 use 成员并隐藏辅助组');
	testState.files['/proc/41/cmdline'] = `/usr/libexec/mihomo\0-d\0${runDir}\0`;
	testState.onRequest = oldRequest;
	cache(persisted, 'r2');
}

for (let failure in [ 'validation', 'write', 'provider' ]) {
	candidate = copy(persisted);
	candidate['proxy-providers'][NODE_PROVIDER].payload[0].port = 10003;
	candidate['proxy-providers'][groupProvider].payload = copy(nodesOf(candidate));
	revision = 'r3'; requests = []; testState.commands = [];
	expectedBeforeValidation = persistedFile;
	validationFailed = failure == 'validation';
	failedProvider = failure == 'provider' ? groupProvider : '';
	testState.onWrite = path => {
		if (failure == 'write' && index(path, `${runDir}/${groupProvider}.json.`) == 0) {
			testState.failedRename = true;
			testState.onWrite = () => { testState.failedRename = false; testState.onWrite = null; };
		}
	};
	result = update(false);
	check(!result.ok && testState.files[file] == persistedFile && readJson(PROFILE_FILE).revision == 'r2',
		`节点更新失败必须恢复旧文件与缓存：${failure}`);
	check(readJson(`${runDir}/config.json`)['proxy-providers'][NODE_PROVIDER].payload[0].port == 10002,
		`节点更新失败必须恢复旧运行配置：${failure}`);
	uninterrupted();
	validationFailed = false; testState.commandStatus = 0; testState.onWrite = null;
}
candidate = copy(persisted);
candidate['proxy-providers'][NODE_PROVIDER].payload = [ { ...nodesOf(candidate)[0], name: '节点二' } ];
candidate['proxy-providers'][groupProvider].payload = [ { name: 'ecy-panel-empty', type: 'reject' } ];
candidate['proxy-groups'][0]['default-selected'] = 'DIRECT';
requests = []; testState.commands = [];
result = update(false);
check(result.ok && !result.reloaded && !length(membersOf(candidate, candidate['proxy-groups'][0])),
	'节点增删和策略组节点暂时为空时，仍应独立更新并排除占位节点');
uninterrupted();
const rulesChanged = copy(candidate);
rulesChanged.rules = [ 'MATCH,DIRECT' ];
check(!canUpdateNodes(candidate, rulesChanged), '规则变更不能错误归类为仅节点更新');
const dnsChanged = copy(candidate);
dnsChanged.dns.nameserver = [ '1.1.1.1' ];
check(!canUpdateNodes(candidate, dnsChanged), 'DNS 变更不能错误归类为仅节点更新');
testState.onRequest = () => { testState.httpStatus = 401; testState.response = { ret: 0, msg: 'fixture denied' }; };
result = update(false);
check(!result.ok && testState.files[PROFILE_FILE] == null && !sessionValid(), '相同配置版本也必须先确认会话，401 必须清除旧授权缓存和会话');
print(`OpenWrt 节点独立更新回归通过：${assertions} 项断言。\n`);
