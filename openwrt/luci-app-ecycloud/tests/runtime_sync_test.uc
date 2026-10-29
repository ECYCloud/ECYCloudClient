'use strict';

import { testState } from 'fs';
import { ACCOUNT_FILE, ANNOUNCE_FILE, API_FILE, CRED_FILE, KICK_FILE, PROFILE_FILE, SPEED_FILE, STATE_FILE, readJson, sessionBinding, sessionValid,
         setState, settings, timestamp } from 'ecycloud.common';
import { cached, store } from 'ecycloud.profile';
import { endpoint, providerProgress } from 'ecycloud.clash';
import { call, refreshAccount } from 'ecycloud.panel';
import { activate, block, deactivate, enqueueSpeed, prepare, refresh, retryPrepare, runSpeed, speedQuota, update, watchdog } from 'ecycloud.service';
import * as statistics from 'ecycloud.statistics';
import * as panel from 'ecycloud.panel';
import * as clash from 'ecycloud.clash';
import * as profile from 'ecycloud.profile';
import * as release from 'ecycloud.release';
import { changeSession, noteSpeedSuccess } from 'ecycloud.service';

const rpc = length(ARGV[0]) ? loadfile(ARGV[0], { raw_mode: true })()['luci.ecycloud'] : null;

let assertions = 0;
function check(ok, message) { assertions++; if (!ok) die(message); };
let now = 1791126000;
global.time = () => now;
global.system = command => { push(testState.commands, command); return 0; };
testState.config = { run_dir: '/etc/ecycloud/run', site_url: 'https://panel.test', sub_url: 'https://sub.test',
	enabled: '1', mode: 'tun', device: 'br-lan' };
const credentials = { email: 'fixture@test', token: 'synthetic-token', device_id: 'fixture',
	session_id: 'fixture-session', expires_at: '2030-01-01T00:00:00Z' };
testState.files[CRED_FILE] = sprintf('%J', credentials);
testState.files[API_FILE] = sprintf('%J', { port: 19090, secret: 'synthetic-secret' });
const runFile = '/etc/ecycloud/run/config.json';
const remote = { revision: 'r1', config: { proxies: [{ name: 'fixture-node', type: 'ss', server: 'node.test',
	port: 10001, cipher: 'aes-128-gcm', password: 'fixture' }],
	'proxy-groups': [{ name: 'Fixture', type: 'select', proxies: [ 'fixture-node' ] }], rules: [ 'MATCH,Fixture' ],
	tun: { enable: false }, 'rule-providers': {} },
	offline_authorization: { issued_at: now - 60, valid_until: now + 86400 } };

check(timestamp('2030-01-02T03:04:05+08:00') == timestamp('2030-01-01T19:04:05Z'), '时间必须正确处理时区');
check(timestamp('10000-01-01T00:00:00+08:00') > now, '必须兼容面板年份为 10000 的长期会话');
check(timestamp('2030-02-30T00:00:00Z') == 0 && timestamp('invalid') == 0, '无效日期必须拒绝');
check(sessionValid() && store(remote) && cached() != null, '当前会话的有效配置必须可以离线使用');
testState.files[CRED_FILE] = sprintf('%J', { ...credentials, token: 'other-token' });
check(cached() == null, '同邮箱换令牌也不能沿用旧会话配置');
testState.files[CRED_FILE] = sprintf('%J', credentials);
testState.config.sub_url = 'https://other.test';
check(cached() == null, '面板来源改变后不能沿用旧授权');
testState.config.sub_url = 'https://sub.test';
now += 86400;
check(cached() == null, '离线授权到期必须拒绝');
now -= 86400 + 120;
check(cached() == null, '时间回拨到授权签发之前必须拒绝');
now += 120;
testState.files[CRED_FILE] = sprintf('%J', { ...credentials, expires_at: '2020-01-01T00:00:00Z' });
check(!sessionValid() && cached() == null && call('/user/profile').status == 401, '过期令牌不能复用配置或请求接口');
testState.files[CRED_FILE] = sprintf('%J', credentials);

setState('running', 'connected');
const since = readJson(STATE_FILE).connected_at;
now += 10;
setState('running', 'nodes updated');
check(readJson(STATE_FILE).connected_at == since, '节点热更新不能重置连接计时');
setState('stopped', '');
check(readJson(STATE_FILE).connected_at == 0, '实际断开必须清除连接计时');

testState.files['/proc/41/cmdline'] = '/usr/libexec/mihomo\0-d\0/etc/ecycloud/run\0';
let requests = [];
testState.onRequest = () => {
	for (let path, text in testState.files)
		if (match(path, /\/req-[a-f0-9]+\.conf$/)) {
			push(requests, text);
			testState.httpStatus = length(requests) == 1 ? 0 : 200;
			testState.commandStatus = length(requests) == 1 ? 7 : 0;
			testState.response = { ret: 1, data: {} };
		}
};
check(call('/user/profile').ok && length(requests) == 2 && index(requests[1], 'proxy = "http://127.0.0.1:10203"') >= 0,
	'直连失败的读请求必须尝试本地代理');
requests = [];
testState.onRequest = () => { push(requests, 'timeout'); testState.httpStatus = 0; testState.commandStatus = 28; };
check(!call('/user/checkin', { method: 'POST', body: {} }).ok && length(requests) == 1,
	'写请求发送后超时不能重放');
testState.onRequest = null;
testState.httpStatus = 200;
testState.commandStatus = 0;
testState.response = { ret: 1, data: { enable: 0, ban_reason: 'fixture-reason' } };
check(refreshAccount().restricted == true, '运行期间封禁状态必须作为连接限制返回');

testState.files[runFile] = sprintf('%J', { ...remote.config, 'rule-providers': { ready: {}, pending: {} } });
testState.response = { providers: { ready: { ruleCount: 1 }, pending: { ruleCount: 0, updatedAt: '0001-01-01T00:00:00Z' } } };
testState.commands = [];
check(providerProgress().ready == 1 && !activate(settings()) && readJson(STATE_FILE).stage == 'starting',
	'未加载的规则集必须显示真实进度并延后接管');
check(!length(filter(testState.commands, c => index(c, 'fw4') >= 0)), '规则集加载期间不能先修改防火墙');
testState.response.providers.pending.updatedAt = '2026-10-04T00:00:00Z';
check(providerProgress().ready == 2, '合法空规则集也必须按内核加载时间判断就绪');

testState.files[runFile] = sprintf('%J', remote.config);
testState.response = {};
testState.commands = [];
check(activate(settings()) && readJson(runFile).tun.enable == true, 'TUN 必须通过控制面启用并保存真实状态');
testState.config.enabled = '0';
check(deactivate() && readJson(runFile).tun.enable == false, 'TUN 关闭必须保存状态并恢复网络');
check(!length(filter(testState.commands, c => index(c, '/etc/init.d/ecycloud restart') >= 0)), 'TUN 手动启停不能重启内核');

store({ ...remote, offline_authorization: { issued_at: now - 60, valid_until: now + 1800 } });
let renewed = 0;
testState.onRequest = () => {
	for (let path, text in testState.files)
		if (match(path, /\/req-[a-f0-9]+\.conf$/)) {
			if (index(text, '/user/account-status') >= 0)
				testState.response = { ret: 1, data: { enable: 1 } };
			else if (index(text, '/user/profile') >= 0)
				testState.response = { ret: 1, data: { config_revision: 'r1' } };
			else if (index(text, '/config/clash') >= 0) {
				renewed++;
				testState.response = { ret: 1, data: remote };
			}
		}
};
check(update(false).ok && renewed == 1 && (cached(true) ?? cached()).offline_authorization.valid_until == remote.offline_authorization.valid_until,
	'节点版本未变时也必须续期临近到期的离线授权');
testState.onRequest = null;
testState.response = {};
testState.config.enabled = '1';
block('fixture-restriction');
check(testState.config.enabled == '0' && cached() == null && readJson(STATE_FILE).error == 'fixture-restriction',
	'受限账号必须撤销接管并保留明确原因');

delete testState.files['/var/run/ecycloud/stopping'];
store(remote);
statistics.clear();
const connection = { id: 'c1', upload: 100, download: 200, chains: [ 'fixture-node', 'fixture-group' ],
	metadata: { host: 'fixture.test', network: 'tcp' } };
statistics.collect({ connections: [connection] });
let stats = statistics.read();
check(!length(keys(stats.rank[stats.today].hosts)), '首次接管只建立连接基线，不能重复计入已保存流量');
now += 5;
statistics.collect({ connections: [{ ...connection, upload: 125, download: 275 }] });
stats = statistics.read();
check(stats.rank[stats.today].hosts['fixture.test'] == 100 && stats.rank[stats.today].groups['fixture-group'] == 100,
	'后台必须按代理连接增量统计排行');
check(stats.up == 5 && stats.down == 15, '后台速率必须按实际采样间隔计算');
now += 5;
const fresh = { ...connection, id: 'fresh', upload: 20, download: 40, metadata: { host: 'fresh.test' } };
statistics.collect({ connections: [{ ...connection, upload: 125, download: 275 }, fresh,
	{ ...connection, id: 'direct', chains: [ 'DIRECT' ], upload: 10000, download: 20000 }] });
stats = statistics.read();
check(stats.rank[stats.today].hosts['fresh.test'] == 60 && stats.rank[stats.today].groups['fixture-group'] == 160,
	'新连接首次读到的流量必须计入排行，直连流量不能混入');
statistics.collect({ connections: [{ ...connection, upload: 125, download: 275 }, fresh] });
check(statistics.read().rank[stats.today].hosts['fresh.test'] == 60, '重复快照不能重复累计流量');
statistics.clear(true);
statistics.collect({ connections: [{ ...connection, upload: 125, download: 275 }, fresh] });
check(statistics.read().rank[stats.today].groups['fixture-group'] == 160, '重新接管已有连接不能重复累计历史流量');
now += 5;
statistics.collect({ connections: [] });
check(length(statistics.read().closed) == 2, '网页关闭期间也必须记录已关闭连接');
const many = [];
for (let n = 1; n <= 1002; n++)
	push(many, { ...connection, id: `c${n}` });
statistics.collect({ connections: many });
statistics.collect({ connections: [] });
check(length(statistics.read().closed) == 1000, '已关闭连接必须受 1000 条上限约束');
const latestRank = 100 + 1002 * 300;
check(statistics.read().rank[stats.today].hosts['fixture.test'] == latestRank,
	'批量出现的新连接也必须计入首次读到的流量');
testState.files[CRED_FILE] = sprintf('%J', { ...credentials, token: 'other-token' });
check(statistics.read().rank[stats.today].hosts['fixture.test'] == latestRank && length(statistics.read().closed ?? []) == 0,
	'同账户新会话应保留排行，但不能继承旧连接明细');
testState.files[CRED_FILE] = sprintf('%J', credentials);
now += 3 * 86400;
check(length(keys(statistics.read().rank)) == 0, '排行必须只保留今天和昨天');
statistics.clear();
check(testState.files['/etc/ecycloud/traffic_rank.json'] == null && testState.files['/var/run/ecycloud/connections.json'] == null,
	'切号时必须清除后台统计');
testState.files['/etc/ecycloud/traffic_rank.json'] = 'invalid-json';
testState.files['/var/run/ecycloud/connections.json'] = 'invalid-json';
statistics.clear();
check(testState.files['/etc/ecycloud/traffic_rank.json'] == null && testState.files['/var/run/ecycloud/connections.json'] == null,
	'损坏的旧账户统计文件也必须清除');

delete testState.files[PROFILE_FILE];
delete testState.files['/proc/41/cmdline'];
testState.config.enabled = '1';
testState.httpStatus = 503;
testState.response = null;
check(!prepare() && readJson(STATE_FILE).retryable == true, '临时服务错误必须可重试');
let sleeps = 0;
let calls = 0;
testState.onRequest = () => { calls++; };
global.sleep = () => { if (++sleeps == 8) testState.config.enabled = '0'; };
retryPrepare();
check(calls == 3 && sleeps == 8, '重试必须按 1/2/4 秒退避，手动断开后立即取消');
testState.config.enabled = '1';
testState.httpStatus = 403;
check(!prepare() && readJson(STATE_FILE).retryable == false, '永久权限拒绝不能无限重试');

function securityFixture(enabled) {
	now = 1791126000;
	testState.files = {};
	testState.commands = [];
	testState.writes = {};
	testState.onRequest = null;
	testState.onCommand = null;
	testState.responses = {};
	testState.responseHeaders = '';
	testState.commandStatus = 0;
	testState.httpStatus = 200;
	testState.config = { run_dir: '/etc/ecycloud/run', site_url: 'https://panel.test', sub_url: 'https://sub.test',
		enabled, mode: 'tproxy', refresh_interval: '0' };
	testState.files[CRED_FILE] = sprintf('%J', credentials);
	testState.files[API_FILE] = sprintf('%J', { port: 19090, secret: 'synthetic-secret', speed: 'synthetic-speed' });
	testState.files['/proc/41/cmdline'] = '/usr/libexec/mihomo\0-d\0/etc/ecycloud/run\0';
	testState.files[STATE_FILE] = sprintf('%J', { stage: enabled == '1' ? 'running' : 'stopped' });
	testState.response = { version: 'fixture' };
	store(remote);
};

securityFixture('0');
testState.files[API_FILE] = sprintf('%J', { port: 19090, secret: 'synthetic-secret' });
const migrated = endpoint();
check(migrated.port == 19090 && migrated.secret == 'synthetic-secret' && length(migrated.speed) == 32 &&
	readJson(API_FILE).speed == migrated.speed, '读取旧控制缓存必须补齐并保存测速口令，不能改变运行中的端口和控制密钥');
check(endpoint().speed == migrated.speed, '测速口令迁移后必须稳定复用');
testState.files[API_FILE] = sprintf('%J', { port: 19090, secret: 'synthetic-secret' });
testState.failedRename = true;
let migrationRefused = false;
try { endpoint(); } catch (e) { migrationRefused = true; }
testState.failedRename = false;
check(migrationRefused && !length(readJson(API_FILE).speed), '口令保存失败必须拒绝，不能继续使用未保存的密钥');

securityFixture('0');
testState.files[API_FILE] = sprintf('%J', { port: 19090, secret: 'synthetic-secret' });
const legacyRemote = { ...remote, config: { ...remote.config,
	dns: { enable: true, 'enhanced-mode': 'redir-host', nameserver: [ '1.1.1.1' ] } } };
store(legacyRemote);
testState.files[runFile] = sprintf('%J', { ...legacyRemote.config, listeners: [{ name: 'ecy-speed', users: [] }] });
testState.onRequest = () => {
	for (let path, text in testState.files)
		if (match(path, /\/req-[a-f0-9]+\.conf$/)) {
			if (index(text, '/user/account-status') >= 0)
				testState.response = { ret: 1, data: { enable: 1 } };
			else if (index(text, '/user/profile') >= 0)
				testState.response = { ret: 1, data: { config_revision: 'r1' } };
			else if (index(text, '/config/clash') >= 0)
				testState.response = { ret: 1, data: legacyRemote };
			else
				testState.response = {};
		}
};
const legacyUpdate = update(true);
check(legacyUpdate.ok && legacyUpdate.reloaded == true && readJson(runFile).listeners[0].users[0].password == readJson(API_FILE).speed,
	'面板配置未变时也必须热载旧无认证测速入口，不能被配置版本缓存跳过');
check(testState.config.enabled == '0' && !length(filter(testState.commands, c => index(c, ' restart') >= 0)),
	'旧口令修复不得接管待机网络或重启可热载的内核');

for (let enabled in [ '0', '1' ]) {
	securityFixture(enabled);
	testState.files[PROFILE_FILE] = sprintf('%J', { ...readJson(PROFILE_FILE),
		offline_authorization: { issued_at: now - 60, valid_until: now - 1 } });
	let rounds = 0;
	global.sleep = () => { if (++rounds == 2) testState.files['/var/run/ecycloud/stopping'] = ''; };
	watchdog();
	check(length(filter(testState.commands, c => index(c, '/etc/init.d/ecycloud stop') >= 0)) > 0,
		`启用状态 ${enabled} 的常驻内核都必须在离线授权过期时停止`);
}
securityFixture('0');
testState.httpStatus = 503;
testState.files[PROFILE_FILE] = sprintf('%J', { ...readJson(PROFILE_FILE),
	offline_authorization: { issued_at: now - 60, valid_until: now - 1 } });
global.sleep = () => { testState.files['/var/run/ecycloud/stopping'] = ''; };
watchdog();
check(length(filter(testState.commands, c => index(c, '/etc/init.d/ecycloud stop') >= 0)) > 0,
	'待机控制面未响应也不能让已过期的内核继续运行');

securityFixture('0');
let accountRequests = 0;
let standbyUsageHeaders = 0;
testState.onRequest = () => {
	for (let path, text in testState.files)
		if (match(path, /\/req-[a-f0-9]+\.conf$/)) {
			if (index(text, 'X-ECY-Connected') >= 0 || index(text, 'X-ECY-Node-Used') >= 0)
				standbyUsageHeaders++;
			if (index(text, '/user/account-status') >= 0) {
				accountRequests++;
				testState.response = { ret: 1, data: { enable: 1, node_connector: 1, online_client_self: false } };
			} else if (index(text, '/user/profile') >= 0)
				testState.response = { ret: 1, data: { config_revision: 'r1' } };
			else
				testState.response = { version: 'fixture' };
		}
};
let refreshRounds = 0;
global.sleep = () => { now += 5; if (++refreshRounds == 14) testState.files['/var/run/ecycloud/stopping'] = ''; };
refresh();
check(accountRequests == 2 && testState.config.enabled == '0', '待机必须每分钟同步账户状态，不能停轮询或改为五秒占额轮询');
check(standbyUsageHeaders == 0, '待机轮询不得上报已连接或实际节点使用，不能刷新最后使用时间');
securityFixture('1');
testState.files['/var/run/ecycloud/network.json'] = sprintf('%J', { active: true });
let connectedHeaders = 0;
testState.onRequest = () => {
	for (let path, text in testState.files)
		if (match(path, /\/req-[a-f0-9]+\.conf$/)) {
			if (index(text, 'X-ECY-Connected') >= 0)
				connectedHeaders++;
			testState.response = { ret: 1, data: { enable: 1, config_revision: 'r1' } };
		}
};
global.sleep = () => { testState.files['/var/run/ecycloud/stopping'] = ''; };
refresh();
check(connectedHeaders == 3, '实际接管网络的身份和账户同步必须继续上报已连接');

for (let enabled in [ '1', '0' ]) {
	for (let reason in [ 'limit_denied', 'limit' ]) {
		securityFixture(enabled);
		testState.files['/var/run/ecycloud/network.json'] = sprintf('%J', { active: enabled == '1' });
		let acknowledgements = 0;
		testState.onRequest = () => {
			for (let path, text in testState.files)
				if (match(path, /\/req-[a-f0-9]+\.conf$/)) {
					if (index(text, '/user/device-kick-ack') >= 0)
						acknowledgements++;
					testState.response = { ret: 1, data: { enable: 1, config_revision: 'r1',
						node_connector: 1, online_client_count: 1, online_client_self: false,
						device_kick_notice: true, device_kick_reason: reason } };
				}
		};
		let rounds = 0;
		global.sleep = () => { now += 5; if (++rounds == 14) testState.files['/var/run/ecycloud/stopping'] = ''; };
		refresh();
		check(testState.config.enabled == enabled && sessionValid(), '自动超限通知必须保留当前启用状态和登录');
		check(testState.files[KICK_FILE] == null, '自动超限通知不能生成本机强制下线标记');
		check(length(filter(testState.commands, c => index(c, 'ecycloud-ctl revert') >= 0)) == 0,
			'自动超限通知不能撤销网络接管');
		check(acknowledgements == 0 && cached() != null &&
			!length(filter(testState.commands, c => index(c, '/etc/init.d/ecycloud stop') >= 0)),
			'后台自动超限通知必须保留确认通知、有效缓存和常驻内核');
	}
}

securityFixture('1');
testState.files['/var/run/ecycloud/network.json'] = sprintf('%J', { active: true });
let acknowledgements = 0;
testState.onRequest = () => {
	for (let path, text in testState.files)
		if (match(path, /\/req-[a-f0-9]+\.conf$/)) {
			if (index(text, '/user/device-kick-ack') >= 0)
				acknowledgements++;
			testState.response = { ret: 1, data: { enable: 1, device_kick_notice: true, device_kick_reason: 'remove' } };
		}
};
global.sleep = () => { testState.files['/var/run/ecycloud/stopping'] = ''; };
refresh();
check(testState.config.enabled == '0' && readJson(STATE_FILE).stage == 'stopped', '主动下线必须撤销网络接管');
check(acknowledgements == 1 && sessionValid() && cached() != null && endpoint().speed == 'synthetic-speed',
	'主动下线必须确认通知并保留登录、有效缓存和测速口令');
check(length(filter(testState.commands, c => index(c, 'ecycloud-ctl revert') >= 0)) == 1 &&
	!length(filter(testState.commands, c => index(c, '/etc/init.d/ecycloud stop') >= 0)), '主动下线必须保留待机内核并恢复网络');

for (let header in [ '5', '', 'invalid', '0', '120' ]) {
	securityFixture('0');
	testState.httpStatus = 429;
	testState.response = { ret: 0 };
	testState.responseHeaders = `HTTP/1.1 200 Connection established\r\nRetry-After: 59\r\n\r\nHTTP/2 429\r\nretry-after: ${header}\r\n\r\n`;
	check(call('/user/profile').status == 429, '限流必须返回 429');
	const seconds = header == '5' ? 5 : header == '120' ? 60 : 6;
	check(readJson('/var/run/ecycloud/cooldown.json')['/user/profile'] == now + seconds, '限流必须采用最终响应的 Retry-After 或客户端相同的六秒备用时间');
	check(!length(filter(keys(testState.files), p => match(p, /\/resp-[a-f0-9]+\.headers$/))), 'HTTP 响应头临时文件必须清理');
	now += seconds;
	testState.httpStatus = 200;
	testState.response = { ret: 1, data: {} };
	check(call('/user/profile').ok, '限流等待结束后必须恢复请求');
}

if (rpc != null) {
	for (let scenario in [ 'valid', 'expired', 'changed-session', 'notice', 'missing-account', 'refresh' ]) {
		securityFixture('0');
		testState.files[ACCOUNT_FILE] = sprintf('%J', { email: credentials.email, node_connector: 1,
			online_client_count: 0, online_client_self: false, device_kick_notice: scenario == 'notice' });
		if (scenario == 'expired')
			testState.files[PROFILE_FILE] = sprintf('%J', { ...readJson(PROFILE_FILE), offline_authorization: { issued_at: now - 60, valid_until: now - 1 } });
		if (scenario == 'changed-session')
			testState.files[CRED_FILE] = sprintf('%J', { ...credentials, token: 'changed-token' });
		if (scenario == 'missing-account')
			delete testState.files[ACCOUNT_FILE];
		let requests = 0;
		testState.onRequest = () => { requests++; testState.httpStatus = 503; testState.response = { ret: 0 }; };
		const result = rpc.refresh_account.call({ args: { use_cache: scenario != 'refresh' } });
		check((result.ok == true) == (scenario == 'valid'), '只有有效同会话缓存且无下线通知时才能直接用于连接');
		check(requests == (scenario == 'valid' ? 0 : 1), '正常刷新和无有效缓存的连接仍必须请求面板');
	}
}

for (let scenario in [ 'reported', 'timeout', 'denied', 'download-failed' ]) {
	securityFixture('0');
	testState.files[ACCOUNT_FILE] = sprintf('%J', { id: 2 });
	let milliseconds = 0;
	global.clock = () => [ int(milliseconds / 1000), int(milliseconds % 1000 * 1000000) ];
	testState.onCommand = command => {
		if (index(command, 'curl -K ') == 0) {
			for (let path in keys(testState.files))
				if (match(path, /\/spd-[a-f0-9]+\.conf$/))
					testState.files[replace(path, '.conf', '.headers')] = scenario == 'download-failed' ? 'HTTP/2 500\r\n\r\n' : 'HTTP/2 200\r\n\r\n';
			testState.responses[command] = { text: scenario == 'download-failed' ? '' : sprintf('%65536s', 'x'), status: 0,
				onRead: chunk => { milliseconds += length(chunk) * 2000 / 65536; } };
		}
	};
	let reports = 0;
	testState.onRequest = () => {
		for (let path, text in testState.files)
			if (match(path, /\/req-[a-f0-9]+\.conf$/)) {
				testState.httpStatus = 200;
				testState.commandStatus = 0;
				testState.response = {};
				if (index(text, '/user/speed-test') >= 0) {
					reports++;
					check(length(readJson('/etc/ecycloud/speed_quota.json').nodes['node-1']) == 1, '测速成功必须在上报前立即计入本地次数');
					testState.httpStatus = scenario == 'timeout' ? 0 : 200;
					testState.commandStatus = scenario == 'timeout' ? 28 : 0;
					testState.response = { ret: 1, data: scenario == 'denied'
						? { allowed: [], denied: [{ proxy_name: 'node-1', reset_at: now + 3600 }] }
						: { allowed: ['node-1'], denied: [] } };
				}
			}
	};
	check(enqueueSpeed(['node-1'], '').ok, '测速任务必须可以排队');
	runSpeed();
	const count = length(readJson('/etc/ecycloud/speed_quota.json')?.nodes?.['node-1'] ?? []);
	check(count == (scenario == 'download-failed' ? 0 : scenario == 'denied' ? 5 : 1), '成功上报与上报失败均计一次，下载失败不计次，面板拒绝则记为满额');
	check(reports == (scenario == 'download-failed' ? 0 : 1), '下载失败不能上报成功结果');
	check((readJson(SPEED_FILE).speeds['node-1'] > 0) == (scenario == 'reported' || scenario == 'timeout'), '上报超时不能丢掉已测得的速度，明确拒绝和下载失败须显示失败');
}

for (let message in [ '账号不存在或已被禁用', 'fixture-unauthorized', '' ]) {
	securityFixture('0');
	testState.httpStatus = 401;
	testState.response = { ret: 0, msg: message };
	check(call('/user/account-status').status == 401 && !sessionValid(), '任何鉴权401都必须清理本地会话，不依赖文案');
}
securityFixture('0');
testState.httpStatus = 401;
testState.response = { ret: 2, msg: 'fixture-two-factor' };
check(!call('/user/profile').ok && sessionValid(), '两步验证挑战不能被当成失效会话清理');
testState.response = { ret: 0, msg: 'fixture-unauthorized' };
check(!call('/auth/login', { anonymous: true }).ok && sessionValid(), '匿名认证失败不能清理已有会话');
function latestRequest() {
	for (let path, text in testState.files)
		if (match(path, /\/req-[a-f0-9]+\.conf$/))
			return text;
	return '';
};

securityFixture('0');
delete testState.files[PROFILE_FILE];
delete testState.files['/proc/41/cmdline'];
testState.response = { ret: 1, data: remote };
let fetches = 0;
testState.onRequest = () => { if (index(latestRequest(), '/config/clash') >= 0) fetches++; };
testState.onCommand = command => {
	if (index(command, ' -t -f ') >= 0)
		testState.responses[command] = { text: 'invalid protocol', status: 1 };
};
check(!prepare() && !prepare() && cached() == null && cached(true) == null && fetches == 2,
	'首启校验失败不能缓存配置，重试必须重新获取');
testState.onCommand = null;
testState.responses = {};
check(prepare() && cached() == null && cached(true) != null, '校验通过后只暂存候选，内核未加载前不能提交离线缓存');
if (rpc != null) {
	check(rpc.start.call({ args: {} }).ok, '启动接口必须接受当前会话已校验的候选配置');
}
testState.files['/proc/42/cmdline'] = '/usr/libexec/mihomo\0-d\0/etc/ecycloud/run\0';
testState.onRequest = () => {
	testState.response = index(latestRequest(), '/user/') >= 0 ? { ret: 1, data: { enable: 1, config_revision: 'r1' } } : {};
};
global.sleep = () => { testState.files['/var/run/ecycloud/stopping'] = ''; };
refresh();
check(cached() != null && cached(true) == null, '新内核就绪后必须提交候选并清除暂存');
delete testState.files['/var/run/ecycloud/stopping'];
store(remote, true);
refresh();
check(cached(true) != null, '重启前旧内核仍响应时不能提前提交候选');
delete testState.files['/var/run/ecycloud/stopping'];
testState.files['/proc/43/cmdline'] = testState.files['/proc/42/cmdline'];
delete testState.files['/proc/42/cmdline'];
refresh();
check(cached(true) == null, '快速重启跨过两次轮询时也必须识别新 PID 并提交');
delete testState.files['/var/run/ecycloud/stopping'];
fetches = 0;
testState.onRequest = () => {
	const request = latestRequest();
	if (index(request, '/config/clash') >= 0) {
		fetches++;
		testState.response = { ret: 1, data: { ...remote, revision: 'r2' } };
	} else
		testState.response = index(request, '/user/') >= 0 ? { ret: 1, data: { enable: 1, config_revision: 'r2' } } : {};
};
refresh();
check(fetches == 1 && cached().revision == 'r2', '关闭定时刷新也必须立即同步账户返回的新配置版本');

securityFixture('0');
for (let i = 0; i < 5; i++) noteSpeedSuccess('node-1');
now += 3600;
check(length(speedQuota(['node-1']).allowed) == 0, '恰好一小时的记录必须仍计入窗口');
now++;
check(length(speedQuota(['node-1']).allowed) == 1, '超过一小时必须释放次数');
now -= 3601;

securityFixture('0');
testState.httpStatus = 503;
testState.response = { ret: 0 };
panel.reportNodeUsed();
testState.httpStatus = 200;
testState.response = { ret: 1, data: {} };
let retried = false;
testState.onRequest = () => { retried = index(latestRequest(), 'X-ECY-Node-Used: 1') >= 0; };
check(call('/user/profile').ok && retried, '实际节点使用上报失败后必须在后续鉴权请求重试');
call('/user/profile');
check(!retried, '成功确认使用标记后不能重复携带');
testState.onRequest = null;
testState.httpStatus = 503;
panel.reportNodeUsed();
testState.files[CRED_FILE] = sprintf('%J', { ...credentials, token: 'changed-token' });
testState.httpStatus = 200;
testState.onRequest = () => { retried = index(latestRequest(), 'X-ECY-Node-Used: 1') >= 0; };
call('/user/profile');
check(!retried, '旧会话待上报标记不能写入新会话');

securityFixture('0');
testState.httpStatus = 429;
testState.response = { ret: 0 };
testState.responseHeaders = 'HTTP/2 429\r\nRetry-After: 300\r\n\r\n';
panel.clashProfile();
check(readJson('/var/run/ecycloud/cooldown.json')['/config/clash'] == now + 300,
	'有效缓存下配置后台刷新必须遵守长 Retry-After');
delete testState.files[PROFILE_FILE];
delete testState.files['/var/run/ecycloud/cooldown.json'];
panel.clashProfile();
check(readJson('/var/run/ecycloud/cooldown.json')['/config/clash'] == now + 60, '无缓存连接仍采用最长六十秒等待');

securityFixture('0');
statistics.clear();
statistics.collect({ connections: [] });
now += 5;
statistics.collect({ connections: [connection] });
let rank = statistics.read();
check(rank.rank[rank.today].hosts['fixture.test'] == 300 && rank.total_up == 100 && rank.total_down == 200,
	'基线建立后的新连接首帧必须计入流量总量和排行');
now += 5;
statistics.collect({ connections: [{ ...connection, download: 500 }] });
noteSpeedSuccess('node-1');
testState.files[ANNOUNCE_FILE] = sprintf('%J', { seen_revisions: { '2': 'r1' }, dismissed_popup_id: 2 });
testState.response = { ret: 1, data: {} };
global.system = command => {
	push(testState.commands, command);
	const stopped = match(command, />'([^']+)'/);
	if (index(command, '/etc/init.d/ecycloud stop') >= 0 && stopped) {
		testState.files[stopped[1]] = '0';
		delete testState.files['/proc/41/cmdline'];
	}
	return 0;
};
check(changeSession(panel.logout, true).ok && readJson(ANNOUNCE_FILE) != null &&
	readJson('/etc/ecycloud/speed_quota.json') != null, '退出必须保留公告状态与按账户绑定的本地次数');
testState.files[CRED_FILE] = sprintf('%J', { ...credentials, token: 'new-token' });
rank = statistics.read();
check(rank.rank[rank.today].hosts['fixture.test'] == 600 && length(speedQuota(['node-1']).allowed) == 1,
	'同账户新会话必须恢复排行与未耗尽的本地次数');
testState.files[CRED_FILE] = sprintf('%J', { ...credentials, email: 'other@test', token: 'other' });
check(length(keys(statistics.read().rank)) == 0, '其他账户不能读取原账户排行');
now -= 10;

securityFixture('0');
const selectedRemote = { ...remote.config, proxies: [ ...remote.config.proxies, { ...remote.config.proxies[0], name: 'node-2' } ],
	'proxy-groups': [{ name: 'Fixture', type: 'select', proxies: ['fixture-node', 'node-2'] }] };
const assembledSelection = profile.assemble(selectedRemote, settings(), endpoint(), { Fixture: 'node-2' });
check(assembledSelection.config['proxy-groups'][0]['default-selected'] == 'node-2' &&
	assembledSelection.config.profile['store-selected'] == false, '接管前配置必须包含有效的账户选择，禁止被内核旧选择覆盖');
check(profile.assemble(selectedRemote, settings(), endpoint(), { Fixture: 'removed' }).config['proxy-groups'][0]['default-selected'] == null,
	'已移除的节点不能注入启动选择');

securityFixture('0');
let milliseconds = 0;
global.clock = () => [ int(milliseconds / 1000), int(milliseconds % 1000 * 1000000) ];
testState.onCommand = command => {
	if (index(command, 'curl -K ') != 0) return;
	for (let path in keys(testState.files))
		if (match(path, /\/spd-[a-f0-9]+\.conf$/))
			testState.files[replace(path, '.conf', '.headers')] = 'HTTP/2 200\r\n\r\n';
	let n = 0;
	const sizes = [1, 16384, 16384, 16384, 16384, 16384, 16384, 1695, 10000, 0];
	const times = [0, 100, 200, 300, 400, 500, 600, 1000, 2000, 2000];
	testState.responses[command] = { read: () => { milliseconds = times[n]; return sprintf(`%${sizes[n++]}s`, sizes[n-1] ? 'x' : ''); }, close: () => 0 };
};
check(clash.speedOne('fixture-node').bytes_per_second == 99900, '测速必须取一秒窗口最高值，不能取整段平均');
check(!length(filter(keys(testState.files), path => match(path, /\/spd-/))), '测速临时请求文件必须全部清理');

securityFixture('0');
testState.files['/etc/openwrt_release'] = "DISTRIB_ARCH='x86_64'\nDISTRIB_RELEASE='24.10.8'\n";
testState.responseHeaders = sprintf('HTTP/2 403\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Reset: %d\r\n\r\n', now + 10);
let githubRequests = 0;
testState.onRequest = () => {
	if (index(latestRequest(), 'api.github.com') >= 0) {
		githubRequests++;
		testState.httpStatus = 403;
		testState.response = {};
	} else {
		testState.httpStatus = 200;
		testState.response = { packages: { 'mihomo-meta': '1.19.32' } };
	}
};
release.checkPeriodic();
check(readJson('/var/run/ecycloud/updates.json').next_check == now + 11, 'GitHub 限流必须按恢复时间重试，不能固定等一小时');
release.checkApp();
check(githubRequests == 1, '限流恢复前手动检查也不能重复请求 GitHub');

printf('OpenWrt 运行逻辑同步回归通过：%d 项断言。\n', assertions);
