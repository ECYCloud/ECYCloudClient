'use strict';

import { testState } from 'fs';
import { ACCOUNT_FILE, ANNOUNCE_FILE, API_FILE, CRED_FILE, KICK_FILE, PROFILE_FILE, SPEED_FILE, STATE_FILE, coreRunning, origins, readJson, sessionBinding, sessionValid,
         setState, settings, timestamp, urlencode } from 'ecycloud.common';
import { cached, issuedReached, store } from 'ecycloud.profile';
import { endpoint, providerProgress } from 'ecycloud.clash';
import { call, refreshAccount } from 'ecycloud.panel';
import { activate, block, deactivate, enqueueSpeed, prepare, refresh, retryPrepare, runSpeed, speedQuota, standby, update, watchdog } from 'ecycloud.service';
import * as statistics from 'ecycloud.statistics';
import * as panel from 'ecycloud.panel';
import * as clash from 'ecycloud.clash';
import * as profile from 'ecycloud.profile';
import * as release from 'ecycloud.release';
import { changeSession, collectGarbage, ensureUpdateWorker, noteSpeedSuccess, retireSignedOut, runUpdates, shareGeodata } from 'ecycloud.service';

const rpc = length(ARGV[0]) ? loadfile(ARGV[0], { raw_mode: true })()['luci.ecycloud'] : null;

let assertions = 0;
function check(ok, message) { assertions++; if (!ok) die(message); };
let now = 1791126000;
global.time = () => now;
global.system = command => { push(testState.commands, command); return 0; };
testState.config = { run_dir: '/etc/ecycloud/run/fixture-session', site_url: 'https://panel.test', sub_url: 'https://sub.test',
	enabled: '1', mode: 'tun', device: 'br-lan' };
const credentials = { email: 'fixture@test', token: 'synthetic-token', device_id: 'fixture',
	session_id: 'fixture-session', account_key: 'fixture-session', expires_at: '2030-01-01T00:00:00Z' };
testState.files[CRED_FILE] = sprintf('%J', credentials);
testState.files[API_FILE] = sprintf('%J', { port: 19090, secret: 'synthetic-secret' });
const runFile = '/etc/ecycloud/run/fixture-session/config.json';
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
check(cached() != null && !issuedReached(cached()), '本机时间慢于签发时间只影响离线复用，运行中的缓存不能因此失效');
now += 50;
check(issuedReached(cached()), '本机时间比签发时间慢 10 秒以内属于校时误差，离线复用仍可用');
now -= 1;
check(!issuedReached(cached()), '本机时间比签发时间慢超过 10 秒，离线复用必须拒绝');
now += 86400 + 71;
check(cached() == null, '签发一侧的容差不能让到期的授权继续可用');
now -= 86400 + 120;
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

testState.files['/proc/41/cmdline'] = '/usr/libexec/mihomo\0-d\0/etc/ecycloud/run/fixture-session\0';
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
now += 61;
testState.response.tun = { enable: true };
check(activate(settings()) && length(filter(testState.commands, c => index(c, 'fw4') >= 0)) > 0,
	'规则集下载失败时同一内核等满 60 秒仍没加载完就先接管，不能永远停在加载中');
deactivate();
now -= 61;
testState.commands = [];
testState.response.providers.pending.updatedAt = '2026-10-04T00:00:00Z';
check(providerProgress().ready == 2, '合法空规则集也必须按内核加载时间判断就绪');

testState.files[runFile] = sprintf('%J', remote.config);
testState.response = { tun: { enable: false } };
testState.commands = [];
check(!activate(settings()) && readJson(STATE_FILE).stage == 'failed' && index(readJson(STATE_FILE).error, 'TUN 接管失败') == 0 &&
	readJson(runFile).tun.enable != true && length(filter(testState.commands, c => index(c, 'fw4 reload') >= 0)) >= 2,
	'内核没能建出 TUN（运行态 tun.enable 仍为 false）时不能显示已接管，必须报失败并撤销网络设置');
testState.response = { tun: { enable: true } };
testState.commands = [];
check(activate(settings()) && readJson(runFile).tun.enable == true, 'TUN 必须通过控制面启用并保存真实状态');
testState.config.enabled = '0';
check(deactivate() && readJson(runFile).tun.enable == false, 'TUN 关闭必须保存状态并恢复网络');
check(profile.write('/etc/ecycloud/run/fixture-session', { ...remote.config, tun: { enable: true, stack: 'mixed' } }).ok &&
	readJson(runFile).tun.enable == true && readJson('/etc/ecycloud/run/fixture-session/kernel.json').tun.enable == false,
	'procd 重启内核读的 kernel.json 必须关着 TUN，只能由看门狗核对后经控制面打开');
testState.files[runFile] = sprintf('%J', remote.config);
check(!length(filter(testState.commands, c => index(c, '/etc/init.d/ecycloud restart') >= 0)), 'TUN 手动启停不能重启内核');

/* 节点文件加载前转来的 DNS 等也会读 url-test，内核把空组回落的 REJECT 缓存 10 秒：接管前要先清掉，且只清 url-test */
testState.files[runFile] = sprintf('%J', { ...remote.config, 'proxy-groups': [ ...remote.config['proxy-groups'],
	{ name: '自动选择', type: 'url-test', proxies: [ 'fixture-node' ] } ] });
testState.config.enabled = '1';
let resets = [];
let resetStatus = 204;
testState.onRequest = () => {
	testState.httpStatus = 200;
	for (let path, text in testState.files)
		if (match(path, /\/req-[a-f0-9]+\.conf$/) && index(text, 'request = "DELETE"') >= 0) {
			push(resets, { url: match(text, /url = "([^"]+)"/)?.[1], at: length(testState.commands) });
			testState.httpStatus = resetStatus;
		}
};
testState.response = { tun: { enable: true } };
testState.commands = [];
const firstFw4 = () => length(filter(testState.commands, c => index(c, 'fw4') >= 0)) ?
	index(testState.commands, filter(testState.commands, c => index(c, 'fw4') >= 0)[0]) + 1 : 0;
check(activate(settings()) && length(resets) == 1 && resets[0].url == `http://127.0.0.1:19090/proxies/${urlencode('自动选择')}` &&
	firstFw4() > resets[0].at, '接管透明代理前必须先清掉 url-test 的选点缓存，且只清 url-test');
deactivate();
resets = [];
resetStatus = 500;
testState.commands = [];
check(activate(settings()) && length(resets) == 1 && firstFw4() > 0, '清缓存失败不能阻止接管');
deactivate();
resetStatus = 204;
testState.onRequest = null;
testState.httpStatus = 200;
testState.config.enabled = '0';
testState.files[runFile] = sprintf('%J', remote.config);

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
if (rpc) {
	const snapshotFile = '/var/run/ecycloud/connections.json';
	const keptSnapshot = testState.files[snapshotFile];
	const crowd = json(keptSnapshot);
	const sample = crowd.closed[0];
	crowd.alive = {};
	crowd.closed = [];
	for (let i = 0; i < 4000; i++)
		crowd.alive[`alive-${i}`] = { ...sample, id: `alive-${i}`, host: i % 40 == 7 ? `Wanted-${i}.test` : `other-${i}.test`, start: sprintf('2026-01-01T00:%02d:%02dZ', i / 60 % 60, i % 60) };
	for (let i = 0; i < 1000; i++)
		push(crowd.closed, { ...sample, id: `closed-${i}`, host: i % 40 == 7 ? `wanted-closed-${i}.test` : `gone-${i}.test`, start: '2025-12-31T00:00:00Z' });
	testState.files[snapshotFile] = sprintf('%J', crowd);
	const first = rpc.connections.call({ args: {} });
	check(first.ok != false && length(first.connections) == 100 && first.page == 1 && first.pages == 50 && first.total.active == 4000 &&
		first.total.closed == 1000 && first.matched.active == 4000 && first.matched.closed == 1000 && first.connections[0].active == true,
		'连接再多也只回一页明细，活跃与已关闭的总数照实给出');
	const seen = {};
	for (let page = 1; page <= 50; page++)
		for (let conn in rpc.connections.call({ args: { page } }).connections)
			seen[conn.id] = true;
	const tail = rpc.connections.call({ args: { page: 50 } });
	check(length(keys(seen)) == 5000 && length(tail.connections) == 100 && tail.connections[99].active == false, '逐页取回必须不重不漏，按开始时间从新到旧');
	const wanted = rpc.connections.call({ args: { keyword: 'WANTED', page: 2 } });
	check(wanted.matched.active == 100 && wanted.matched.closed == 25 && wanted.pages == 2 && wanted.page == 2 && length(wanted.connections) == 25 &&
		!length(filter(wanted.connections, conn => index(lc(conn.host), 'wanted') < 0)) && wanted.total.active == 4000,
		'搜索必须先过滤再分页，匹配数与总数分别给出');
	const closedOnly = rpc.connections.call({ args: { scope: 'closed', keyword: 'wanted', page: 9, limit: 99999 } });
	check(closedOnly.page == 1 && closedOnly.pages == 1 && length(closedOnly.connections) == 25 && closedOnly.connections[0].active == false,
		'页码越界回到最后一页，每页条数不能超过上限');
	check(rpc.connections.call({ args: { page: -3, limit: -1, keyword: [ 'x' ], scope: 'bogus' } }).page == 1, '非法分页参数按默认值处理');
	const found = rpc.connections.call({ args: { scope: 'closed', id: 'alive-3999' } });
	check(found.detail?.id == 'alive-3999' && found.detail.active == true && rpc.connections.call({ args: { id: 'closed-5' } }).detail.active == false &&
		rpc.connections.call({ args: { id: 'missing' } }).detail == null, '详情按连接标识单独取，不依赖它是否在当前页');
	testState.files[snapshotFile] = keptSnapshot;
}
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
const rankFile = '/etc/ecycloud/traffic_rank.json';
const crowdDay = statistics.read().today;
const crowdHosts = {};
const crowd = [];
for (let n = 1; n <= 150; n++) {
	crowdHosts[`h${n}.test`] = n;
	push(crowd, { ...connection, id: `h${n}`, upload: n, download: 0, metadata: { host: `h${n}.test` } });
}
const longHost = sprintf('%0254d', 0);
push(crowd, { ...connection, id: 'long', upload: 100000, download: 0, metadata: { host: longHost } });
testState.files[rankFile] = sprintf('%J', { accounts: { 'other@test': { '2020-01-01': { groups: {}, hosts: { 'stale.test': 1 } },
	[crowdDay]: { groups: {}, hosts: crowdHosts } } } });
statistics.collect({ connections: [] });
now += 5;
statistics.collect({ connections: crowd });
const crowdRank = statistics.read().rank[crowdDay];
check(length(keys(crowdRank.hosts)) == 100 && crowdRank.hosts['h150.test'] == 150 && crowdRank.hosts['h51.test'] == 51 &&
	crowdRank.hosts['h50.test'] == null, '运行快照与状态接口每天只能保留流量最高的 100 个主机');
check(length(keys(readJson('/var/run/ecycloud/connections.json').rank[crowdDay].hosts)) == 100, 'rpcd 每次读取的运行快照文件也只能写入前 100 个主机');
check(!exists(crowdRank.hosts, longHost), '超过域名长度上限的主机名不能计入排行');
now += 5;
crowd[0] = { ...crowd[0], upload: 1001 };
statistics.collect({ connections: crowd });
check(statistics.read().rank[crowdDay].hosts['h1.test'] == 1001, '今天排在前 100 之外的主机必须继续累计，不能因截断丢掉已有流量');
const savedRank = readJson(rankFile)?.accounts;
check(length(keys(savedRank?.[credentials.email]?.[crowdDay]?.hosts ?? {})) == 100 && savedRank['other@test']['2020-01-01'] == null &&
	length(keys(savedRank['other@test'][crowdDay].hosts)) == 100, '落盘排行每天只保留前 100 项，其它账户也不能保留过期日期');
delete testState.files['/var/run/ecycloud/connections.json'];
testState.files[rankFile] = sprintf('%J', { accounts: { [credentials.email]: { [crowdDay]: { groups: {}, hosts: crowdHosts } } } });
check(length(keys(statistics.read().rank[crowdDay].hosts)) == 100, '旧版落盘的完整排行也不能整份回传给界面');
statistics.clear();

delete testState.files[PROFILE_FILE];
delete testState.files['/proc/41/cmdline'];
testState.config.enabled = '1';
testState.files['/usr/libexec/mihomo'] = '';
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
testState.httpStatus = 200;
const earlyClock = { ret: 1, data: { ...remote, offline_authorization: { issued_at: time() + 3600, valid_until: time() + 90000 } } };
testState.response = earlyClock;
check(prepare() && cached(true) != null, '系统时间落后于面板签发时间时，刚从面板取到的配置照常可用（与另两端一致）');
let clockFetches = 0;
testState.onRequest = () => { clockFetches++; };
testState.httpStatus = 503;
check(!prepare() && clockFetches > 0 && readJson(STATE_FILE).retryable == true,
	'缓存签发时间晚于本机时间超过 10 秒时，启动不能离线复用缓存，必须先向面板取配置');
testState.onRequest = null;
testState.httpStatus = 200;
delete testState.files[profile.PENDING_FILE];
earlyClock.data.offline_authorization = { issued_at: time() - 7200, valid_until: time() - 3600 };
check(!prepare() && readJson(STATE_FILE).retryable == false && cached() == null && cached(true) == null,
	'已到期的离线授权不能因时钟问题被重试或放行');
testState.response = null;

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
	testState.config = { run_dir: '/etc/ecycloud/run/fixture-session', site_url: 'https://panel.test', sub_url: 'https://sub.test',
		enabled, mode: 'tproxy', refresh_interval: '0' };
	testState.files[CRED_FILE] = sprintf('%J', credentials);
	testState.files[API_FILE] = sprintf('%J', { port: 19090, secret: 'synthetic-secret', speed: 'synthetic-speed' });
	testState.files['/usr/libexec/mihomo'] = '';
	testState.files['/proc/41/cmdline'] = '/usr/libexec/mihomo\0-d\0/etc/ecycloud/run/fixture-session\0';
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

const BLOCKED = '/var/run/ecycloud/blocked.json';
const serviceCommands = () => filter(testState.commands, c => match(c, /\/etc\/init\.d\/ecycloud (stop|restart)/));
for (let enabled in [ '0', '1' ]) {
	securityFixture(enabled);
	testState.files[PROFILE_FILE] = sprintf('%J', { ...readJson(PROFILE_FILE),
		offline_authorization: { issued_at: now - 60, valid_until: now - 1 } });
	let rounds = 0;
	global.sleep = () => {
		if (++rounds == 1)
			check(!length(serviceCommands()) && length(filter(readJson('/var/run/ecycloud/update.json')?.tasks ?? [], t => t.kind == 'profile')) == 1,
				`启用状态 ${enabled}：离线授权到点必须先排一次在线续期，等待期间不撤销接管`);
		now += 31;
		if (rounds == 3) testState.files['/var/run/ecycloud/stopping'] = '';
	};
	watchdog();
	check(length(filter(serviceCommands(), c => index(c, enabled == '1' ? ' restart' : ' stop') >= 0)) > 0 && readJson(PROFILE_FILE) == null &&
		testState.config.enabled == enabled && (readJson(BLOCKED)?.renew == true) == (enabled == '1') && readJson(STATE_FILE).retryable == (enabled == '1'),
		`启用状态 ${enabled}：续期没成功就撤销接管、删掉过期缓存；已连接的保留连接开关并重启服务继续向面板取配置，待机的停服务`);
}
securityFixture('1');
testState.files[PROFILE_FILE] = sprintf('%J', { ...readJson(PROFILE_FILE),
	offline_authorization: { issued_at: now - 60, valid_until: now - 1 } });
let renewRounds = 0;
global.sleep = () => {
	if (++renewRounds == 1)
		store({ ...remote, offline_authorization: { issued_at: now, valid_until: now + 86400 } });
	if (renewRounds == 2) testState.files['/var/run/ecycloud/stopping'] = '';
};
watchdog();
check(!length(serviceCommands()) && testState.config.enabled == '1' && cached() != null, '到点在线续期成功后不能撤销接管或重启内核');
securityFixture('0');
testState.httpStatus = 503;
testState.files[PROFILE_FILE] = sprintf('%J', { ...readJson(PROFILE_FILE),
	offline_authorization: { issued_at: now - 60, valid_until: now - 1 } });
renewRounds = 0;
global.sleep = () => { now += 31; if (++renewRounds == 2) testState.files['/var/run/ecycloud/stopping'] = ''; };
watchdog();
check(length(filter(serviceCommands(), c => index(c, ' stop') >= 0)) > 0,
	'待机控制面未响应也不能让已过期的内核继续运行');
for (let renew in [ false, true ]) {
	securityFixture('1');
	testState.files[BLOCKED] = sprintf('%J', { reason: 'fixture-expired', renew });
	delete testState.files[PROFILE_FILE];
	testState.response = { ret: 1, data: { ...remote, config: { ...remote.config, proxies: [] },
		offline_authorization: { issued_at: now, valid_until: now + 86400 } } };
	check(!prepare() && readJson(STATE_FILE).retryable == renew && (readJson(BLOCKED) != null) == renew,
		renew ? '离线授权到期后面板还没续期（不下发节点）时必须继续重试' : '普通连接遇到面板配置不规范仍不能无限重试');
	check(renew ? readJson(STATE_FILE).error == 'fixture-expired' &&
		length(filter(testState.commands, c => index(c, '面板未续期：面板配置不规范') >= 0)) > 0 :
		index(readJson(STATE_FILE).error, '面板配置不规范') == 0,
		renew ? '续期被拒时状态沿用到期提示，面板给的原因只写日志，不能弹「面板配置不规范」' : '普通连接仍要原样显示面板配置问题');
}
testState.response = { ret: 1, data: { ...remote, offline_authorization: { issued_at: now, valid_until: now + 86400 } } };
check(prepare() && readJson(BLOCKED) == null, '续期后取到有效配置必须恢复启动并清掉到期标记');
testState.response = null;
for (let renew in [ true, false ]) {
	securityFixture('1');
	testState.files[BLOCKED] = sprintf('%J', { reason: 'fixture-expired', renew });
	delete testState.files[PROFILE_FILE];
	let fetches = 0;
	let naps = 0;
	testState.onRequest = () => {
		fetches++;
		testState.httpStatus = renew ? 200 : 503;
		testState.response = renew ? { ret: 1, data: { ...remote, config: { ...remote.config, proxies: [] },
			offline_authorization: { issued_at: now, valid_until: now + 86400 } } } : { ret: 0 };
	};
	const fetchedAt = [];
	const counted = testState.onRequest;
	testState.onRequest = () => { push(fetchedAt, naps); counted(); };
	global.sleep = () => { now++; if (++naps == 1000) testState.config.enabled = '0'; };
	retryPrepare();
	check(renew ? join(',', fetchedAt) == '30,90,210,450,750' : fetches == 37, renew
		? `面板拒绝续期后第一次重试等 30 秒，之后翻倍、最长 300 秒一次，1000 秒内应在 30,90,210,450,750 秒拉配置，实际 ${join(',', fetchedAt)}`
		: `其它可重试错误仍按最长 30 秒一次重试，1000 秒内应 37 次，实际 ${fetches} 次`);
}
securityFixture('1');
testState.files[BLOCKED] = sprintf('%J', { reason: 'fixture-expired', renew: true });
delete testState.files[PROFILE_FILE];
testState.onRequest = () => {
	testState.httpStatus = 200;
	testState.response = { ret: 1, data: { ...remote, config: { ...remote.config, proxies: [] },
		offline_authorization: { issued_at: now, valid_until: now + 86400 } } };
};
let napsBeforeStart = 0;
global.sleep = () => {
	now++;
	if (++napsBeforeStart == 70) {
		testState.onRequest = null;
		testState.response = null;
		store({ ...remote, offline_authorization: { issued_at: now, valid_until: now + 86400 } }, true);
		testState.info[profile.PENDING_FILE] = { type: 'file', nlink: 1, mtime: now };
	}
	if (napsBeforeStart == 400) testState.config.enabled = '0';
};
retryPrepare();
check(napsBeforeStart == 70 && length(filter(testState.commands, c => index(c, '/etc/init.d/ecycloud start') >= 0)) == 1,
	'续期重试等待期间界面手动刷新拿到了新配置，必须立即启动，不能等满这一轮的长间隔');
delete testState.info[profile.PENDING_FILE];

const RENEWING = '/etc/ecycloud/renewing.json';
const reboot = () => {
	for (let path in keys(testState.files))
		if (index(path, '/var/run/') == 0)
			delete testState.files[path];
};
const noNodes = () => {
	testState.httpStatus = 200;
	testState.response = { ret: 1, data: { ...remote, config: { ...remote.config, proxies: [] },
		offline_authorization: { issued_at: now, valid_until: now + 86400 } } };
};
securityFixture('1');
let renewWrites = 0;
testState.onWrite = path => { if (index(path, RENEWING) == 0) renewWrites++; };
block('配置离线授权已到期，面板续期后将自动恢复连接', true);
block('配置离线授权已到期，面板续期后将自动恢复连接', true);
check(readJson(RENEWING)?.reason == '配置离线授权已到期，面板续期后将自动恢复连接' && renewWrites == 1,
	'等面板续期的状态必须另存闪存，且只在状态变化时写一次');
reboot();
delete testState.files[PROFILE_FILE];
noNodes();
check(!prepare() && readJson(STATE_FILE).retryable == true && readJson(STATE_FILE).error == '配置离线授权已到期，面板续期后将自动恢复连接',
	'续期失败期间路由器重启后，开机启动仍要按续期处理：可重试并显示到期提示');
let rebootNaps = 0;
const rebootFetches = [];
testState.onRequest = () => {
	push(rebootFetches, rebootNaps);
	if (length(rebootFetches) < 3)
		noNodes();
	else
		testState.response = { ret: 1, data: { ...remote, offline_authorization: { issued_at: now, valid_until: now + 86400 } } };
};
testState.commands = [];
global.sleep = () => { now++; if (++rebootNaps == 1000) testState.config.enabled = '0'; };
retryPrepare();
check(join(',', rebootFetches) == '30,90,210' && length(filter(testState.commands, c => index(c, '/etc/init.d/ecycloud start') >= 0)) == 1 &&
	readJson(RENEWING) == null && renewWrites == 1,
	`重启后仍按 30 秒起、翻倍的续期退避重试，续费后自动恢复连接并清掉续期状态，实际在 ${join(',', rebootFetches)} 秒拉配置`);
testState.onRequest = null;
testState.onWrite = null;

securityFixture('1');
block('fixture-config-error');
check(readJson(RENEWING) == null, '非续期的拦截不得写续期状态');
reboot();
delete testState.files[PROFILE_FILE];
noNodes();
check(!prepare() && readJson(STATE_FILE).retryable == false && index(readJson(STATE_FILE).error, '面板配置不规范') == 0,
	'真正的配置错误在重启后不能被当成续期而无限重试');
securityFixture('1');
block('fixture-expired', true);
check(readJson(RENEWING) != null, '续期状态必须已写入');
block('fixture-config-error');
check(readJson(RENEWING) == null, '续期期间转成真正的拦截（如账号受限）时必须清掉续期状态');
block('fixture-expired', true);
standby();
check(readJson(RENEWING) == null, '用户主动停止后必须清掉续期状态');
block('fixture-expired', true);
panel.clearToken();
check(readJson(RENEWING) == null, '退出登录或会话失效时必须清掉续期状态');
securityFixture('1');
testState.files[RENEWING] = sprintf('%J', { session: 'other-session', reason: 'fixture-expired' });
delete testState.files[PROFILE_FILE];
noNodes();
check(!prepare() && readJson(STATE_FILE).retryable == false, '别的登录会话留下的续期状态不得生效');
testState.response = null;
testState.config.enabled = '1';
securityFixture('1');
delete testState.files['/etc/ecycloud/run/fixture-session/config.json'];
testState.commandStatus = -9;
check(!prepare() && readJson(STATE_FILE).retryable == true && index(readJson(STATE_FILE).error, '配置校验未能完成') == 0,
	'校验进程被杀（如内存不足）时启动必须按可重试失败退避重试，不能当成配置不合法就此放弃');
testState.commandStatus = 0;
delete testState.files['/usr/libexec/mihomo'];
check(!prepare() && readJson(STATE_FILE).retryable == true, '内核文件暂时不可执行（升级中、权限被改）时启动必须可重试');
testState.files['/usr/libexec/mihomo'] = '';
securityFixture('1');
testState.config.device = 'br-lan';
let backoffRounds = 0;
global.sleep = ms => { now += ms / 1000; if (++backoffRounds == 40) testState.files['/var/run/ecycloud/stopping'] = ''; };
watchdog();
const takeoverFailures = length(filter(testState.commands, c => index(c, '透明代理规则未生效') >= 0));
check(takeoverFailures >= 4 && takeoverFailures <= 7 && readJson(STATE_FILE).stage == 'failed',
	`接管持续失败（每次都要重载防火墙）必须按 1/2/4… 秒退避，40 秒内实际重试 ${takeoverFailures} 次`);
securityFixture('1');
let hungRounds = 0;
global.sleep = ms => {
	now += ms / 1000;
	if (++hungRounds == 1) testState.httpStatus = 0;
	if (hungRounds == 40) testState.files['/var/run/ecycloud/stopping'] = '';
};
watchdog();
check(length(filter(testState.commands, c => c == 'kill -9 41 2>/dev/null')) == 1, '内核进程还在但控制面连续 30 秒无响应（假死）必须杀掉交给 procd 重启');
testState.httpStatus = 200;

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

for (let migrate in [ () => refreshAccount(true), () => panel.checkin() ]) {
	securityFixture('1');
	testState.files['/var/run/ecycloud/network.json'] = sprintf('%J', { active: true });
	store(remote, true);
	testState.onRequest = () => {
		for (let path, text in testState.files)
			if (match(path, /\/req-[a-f0-9]+\.conf$/))
				testState.response = index(text, 'http://127.0.0.1:19090/') >= 0 ? { version: 'fixture' } :
					{ ret: 1, data: { enable: 1, config_revision: 'r1', site_origin: 'https://moved.test', api_origin: 'https://moved-sub.test' } };
	};
	testState.files['/proc/self/status'] = 'Name:\tucode\nPid:\t4242\n';
	check(migrate().ok && origins().site == 'https://panel.test' && origins().sub == 'https://sub.test', '面板下发的新地址要等后台探测通过后才切换');
	ensureUpdateWorker();
	runUpdates();
	check(migrate().ok && origins().site == 'https://moved.test' && origins().sub == 'https://moved-sub.test', '面板下发的新地址必须生效');
	check(cached() != null && cached(true) != null, '面板经已鉴权响应迁移地址后，同一会话的配置缓存与候选配置必须继续有效');
	global.sleep = () => { testState.files['/var/run/ecycloud/stopping'] = ''; };
	watchdog();
	check(testState.config.enabled == '1' && !length(filter(testState.commands, c => index(c, '/etc/init.d/ecycloud stop') >= 0)),
		'面板迁移地址后看门狗不能停服或撤销连接');
	delete testState.files['/var/run/ecycloud/stopping'];
	testState.config.site_url = 'https://manual.test';
	check(cached() == null, '手动改写面板地址仍须使旧授权失效');
}

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
		const offline = scenario in [ 'notice', 'missing-account', 'refresh' ];
		check((result.ok == true) == (scenario == 'valid' || offline) && (result.offline == true) == offline,
			'面板 5xx 且当前会话离线授权有效时可凭缓存连接（重启后没有账户缓存也一样），授权失效或会话已换不能');
		check(requests == (scenario == 'valid' ? 0 : 1), '正常刷新和无有效缓存的连接仍必须请求面板');
	}
	for (let status in [ 429, 403 ]) {
		securityFixture('0');
		testState.onRequest = () => { testState.httpStatus = status; testState.response = { ret: 0 }; };
		const result = rpc.refresh_account.call({ args: { use_cache: false } });
		check((result.ok == true) == (status == 429), '限流可凭有效缓存连接，明确拒绝不能');
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
let announceConf = '';
testState.onRequest = () => {
	for (let path, text in testState.files)
		if (match(path, /\/req-[a-f0-9]+\.conf$/) && index(text, '/announcements') >= 0)
			announceConf = text;
	testState.response = { ret: 1, data: { announcements: [] } };
};
check(panel.fetchAnnouncements('zh-CN').ok && index(announceConf, 'max-time = 5\n') >= 0,
	'公告与刷新配置共用串行的后台队列，必须用短超时，面板挂起时不能让排在后面的任务久等');
for (let banned in [ true, false ]) {
	securityFixture('0');
	testState.onRequest = () => {
		for (let path, text in testState.files)
			if (match(path, /\/req-[a-f0-9]+\.conf$/)) {
				const status = index(text, '/user/account-status') >= 0 && banned;
				testState.httpStatus = status ? 200 : 401;
				testState.response = status ? { ret: 1, data: { enable: 0, ban_reason: 'fixture-ban' } } : { ret: 0, msg: '账号不存在或已被禁用' };
			}
	};
	check(call('/config/revision').status == 401 && sessionValid() == banned,
		banned ? '封禁账号访问放行名单以外的接口回 401 时，同一令牌查账号状态仍是 200，不能清会话' : '账号状态也回 401 才清会话');
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
testState.files['/proc/42/cmdline'] = '/usr/libexec/mihomo\0-d\0/etc/ecycloud/run/fixture-session\0';
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
for (let i = 0; i < 5; i++) noteSpeedSuccess('node-1');
testState.files[ACCOUNT_FILE] = sprintf('%J', { id: 1 });
check(length(speedQuota(['node-1']).allowed) == 0, '用户 ID 1 没有面板标记时仍按次数限制');
testState.files[ACCOUNT_FILE] = sprintf('%J', { id: 42, speed_test_unlimited: true });
check(length(speedQuota(['node-1']).allowed) == 1, '面板标记不限次的账号跳过本地次数限制');

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
statistics.clear();
statistics.collect({ connections: [] });
now += 5;
statistics.collect({ connections: [connection] });
now += 5;
statistics.collect({ connections: [{ ...connection, download: 500 }] });
testState.failedRename = true;
let rankSaveBlocked = false;
try { statistics.clear(true); } catch (e) { rankSaveBlocked = true; }
testState.failedRename = false;
check(!rankSaveBlocked && testState.files['/var/run/ecycloud/connections.json'] == null && length(statistics.read().closed ?? []) == 0,
	'流量排行保存失败不能阻止清除旧账户快照');
now -= 10;

function emulateRemoval(fails) {
	global.system = command => {
		push(testState.commands, command);
		const target = match(command, /^rm -rf -- '([^']+)'$/);
		if (target && !fails)
			for (let path in keys(testState.files))
				if (path == target[1] || index(path, `${target[1]}/`) == 0)
					delete testState.files[path];
		return target && fails ? 1 : 0;
	};
}

if (rpc != null) {
	securityFixture('0');
	const previousSystem = global.system;
	emulateRemoval(true);
	testState.response = { ret: 1, data: {} };
	const logout = rpc.logout.call({ args: {} });
	check(logout.ok && !logout.session.logged_in && !sessionValid() && testState.config.enabled == '0',
		'退出必须立即删除凭据并关闭连接，不等待旧服务停止');
	const retireCommand = filter(testState.commands, c => index(c, 'ecycloud-ctl retire') >= 0)[0] ?? '';
	check(index(retireCommand, "ecycloud-ctl retire '/etc/ecycloud/run/fixture-session'") >= 0 && index(retireCommand, '&') >= 0 &&
		!length(filter(testState.commands, c => index(c, '/etc/init.d/ecycloud stop') >= 0)),
		'退出只在后台交给 retire 停服务，不在 rpcd 里同步等待');
	check(testState.files[API_FILE] == null, '旧账号的控制面与测试结果必须在切换锁内同步删除');
	testState.files['/etc/ecycloud/run/fixture-session/config.json'] = 'old-config';
	testState.files['/etc/ecycloud/run/fixture-session/ecy-panel-nodes.json'] = 'old-nodes';
	testState.files['/etc/ecycloud/run/fixture-session/.last-used'] = `${now}`;
	testState.files['/etc/ecycloud/run/fixture-session/cache.db'] = 'cache';
	testState.commands = [];
	check(retireSignedOut('/etc/ecycloud/run/fixture-session'), '后台退出必须完成');
	const stopCommand = join('\n', testState.commands);
	check(index(stopCommand, '/etc/init.d/ecycloud stop') >= 0 &&
		index(stopCommand, "rm -f -- '/etc/ecycloud/run/fixture-session'/config.json") >= 0 &&
		index(stopCommand, "'/etc/ecycloud/run/fixture-session'/ecy-panel-*.json") >= 0 &&
		index(stopCommand, "rm -rf -- '/etc/ecycloud/run/fixture-session'") < 0,
		'仍无会话时停服务并只删带节点凭据的配置，账号目录本身留给同账号复用');
	check(!retireSignedOut('/etc/passwd') && !retireSignedOut('/etc/ecycloud/run/../x'), '后台退出只接受账号运行目录');
	testState.files[CRED_FILE] = sprintf('%J', { ...credentials, token: 'next-token', session_id: 'next-session', account_key: 'next-session' });
	testState.commands = [];
	retireSignedOut('/etc/ecycloud/run/fixture-session');
	check(!length(filter(testState.commands, c => index(c, 'ecycloud stop') >= 0)), '新账号已登录时晚到的后台退出不能停掉服务');
	testState.files[CRED_FILE] = sprintf('%J', { device_id: 'fixture' });
	testState.commands = [];
	testState.files['/etc/ecycloud/run/fixture-session/geoip.metadb'] = 'geo';
	shareGeodata('/etc/ecycloud/run/fixture-session');
	check(length(filter(testState.commands, c => index(c, "ln -f -- '/etc/ecycloud/run/fixture-session/geoip.metadb' '/etc/ecycloud/geodata/geoip.metadb'") == 0)) == 1,
		'账号目录里下载到的 geodata 必须硬链接到共享位置，回收账号目录不会删掉它');
	testState.files['/etc/ecycloud/geodata/GeoSite.dat'] = 'geo';
	testState.commands = [];
	shareGeodata('/etc/ecycloud/run/new-account');
	check(length(filter(testState.commands, c => index(c, "ln -f -- '/etc/ecycloud/geodata/GeoSite.dat' '/etc/ecycloud/run/new-account/GeoSite.dat'") == 0)) == 1,
		'新账号目录必须从共享位置链接 geodata，首次连接不用在线下载');
	testState.files['/etc/ecycloud/run/stale-account/.last-used'] = `${now - 31 * 86400}`;
	testState.files['/etc/ecycloud/run/stale-account/cache.db'] = 'stale';
	collectGarbage();
	check(testState.files['/etc/ecycloud/run/stale-account/cache.db'] != null, '删除过期目录失败只记日志，不能抛错');
	testState.commands = [];
	rpc.status.call({ args: {} });
	check(!length(filter(testState.commands, c => index(c, 'ecycloud-ctl') >= 0)), '查询状态不能再触发后台清理');
	check(!coreRunning(), '退出后旧账号目录里的内核不能当作当前内核');
	testState.files[CRED_FILE] = sprintf('%J', { ...credentials, token: 'next-token', session_id: 'next-session', account_key: 'next-session' });
	check(settings().runDir == '/etc/ecycloud/run/next-session' && !coreRunning(),
		'新账号只能使用自己的运行目录，旧账号仍在跑的内核不属于新账号');
	emulateRemoval(false);
	testState.files['/etc/ecycloud/run/next-session/cache.db'] = 'new-account-cache';
	testState.files['/etc/ecycloud/run/fixture-session/.last-used'] = `${now - 29 * 86400}`;
	testState.files['/etc/ecycloud/run/fixture-session/cache.db'] = 'recent-account-cache';
	testState.files['/etc/ecycloud/run/old-login/config.json'] = 'unmarked';
	testState.files['/etc/ecycloud/run/config.json'] = 'legacy-shared-config';
	collectGarbage();
	check(testState.files['/etc/ecycloud/run/stale-account/cache.db'] == null && testState.files['/etc/ecycloud/run/old-login/config.json'] == null &&
		testState.files['/etc/ecycloud/run/config.json'] == null, '超过 30 天未用的账号目录、无使用记录的旧目录与旧版共享数据必须回收');
	check(testState.files['/etc/ecycloud/run/fixture-session/cache.db'] != null && testState.files['/etc/ecycloud/run/next-session/cache.db'] != null,
		'30 天内用过的账号与当前账号的目录不能回收');
	testState.files[CRED_FILE] = sprintf('%J', { device_id: 'fixture' });
	testState.response = { ret: 1, data: { token: 'again-1', expires_at: '2030-01-01T00:00:00Z' } };
	check(changeSession(() => panel.login('Fixture@Test', 'pw', ''), false).ok, '登录必须成功');
	const firstKey = readJson(CRED_FILE).account_key;
	check(settings().runDir == `/etc/ecycloud/run/${firstKey}` && +(testState.files[`/etc/ecycloud/run/${firstKey}/.last-used`] ?? 0) == now,
		'登录必须记录账号目录的使用时间');
	testState.files[CRED_FILE] = sprintf('%J', { device_id: 'fixture' });
	testState.response = { ret: 1, data: { token: 'again-2', expires_at: '2030-01-01T00:00:00Z' } };
	panel.login('fixture@test', 'pw', '');
	check(readJson(CRED_FILE).account_key == firstKey && readJson(CRED_FILE).session_id != null,
		'同一账号重新登录必须回到同一个运行目录');
	testState.files[CRED_FILE] = sprintf('%J', { device_id: 'fixture' });
	panel.login('other@test', 'pw', '');
	check(length(readJson(CRED_FILE).account_key) == 64 && readJson(CRED_FILE).account_key != firstKey, '不同账号必须使用不同运行目录');
	const legacy = { ...credentials, token: 'legacy' };
	delete legacy.account_key;
	testState.files[CRED_FILE] = sprintf('%J', legacy);
	panel.session();
	check(length(readJson(CRED_FILE).account_key) == 64, '旧版凭据缺少账号键时必须按站点与邮箱补上');
	global.system = previousSystem;
}

securityFixture('0');
testState.files[CRED_FILE] = sprintf('%J', { device_id: 'fixture' });
testState.authBusy = true;
const busyLogin = changeSession(() => ({ ok: true }), false);
testState.authBusy = false;
check(!busyLogin.ok && busyLogin.msg == '账户正在切换，请稍后重试', '另一请求正在切换账户时登录必须立即返回，不能等待');
testState.commands = [];
check(changeSession(() => ({ ok: true }), false).ok && !length(filter(testState.commands, c => index(c, 'rm -rf') >= 0 || index(c, 'ecycloud stop') >= 0)),
	'登录前不能做任何清理或停止服务');
securityFixture('0');
testState.files[CRED_FILE] = sprintf('%J', { ...credentials, token: 'next-token', session_id: 'next-session', account_key: 'next-session' });
testState.commands = [];
watchdog();
check(length(filter(testState.commands, c => index(c, '/etc/init.d/ecycloud stop') >= 0)) == 1,
	'看门狗发现内核跑在其他会话的目录里，必须停掉服务而不是继续接管');

securityFixture('0');
const selectedRemote = { ...remote.config, proxies: [ ...remote.config.proxies, { ...remote.config.proxies[0], name: 'node-2' } ],
	'proxy-groups': [{ name: 'Fixture', type: 'select', proxies: ['fixture-node', 'node-2'] }] };
const assembledSelection = profile.assemble(selectedRemote, settings(), endpoint(), { Fixture: 'node-2' });
check(assembledSelection.config['proxy-groups'][0]['default-selected'] == 'node-2' &&
	assembledSelection.config.profile['store-selected'] == false, '接管前配置必须包含有效的账户选择，禁止被内核旧选择覆盖');
check(profile.assemble(selectedRemote, settings(), endpoint(), { Fixture: 'removed' }).config['proxy-groups'][0]['default-selected'] == null,
	'已移除的节点不能注入启动选择');

testState.config.region = 'overseas';
check(settings().region == 'overseas', '海外地区必须读出 overseas');
testState.config.region = 'other';
check(settings().region == 'cn', '非 overseas 的地区一律按中国处理');
delete testState.config.region;
check(settings().region == 'cn', '未设置地区时默认中国');
const regionRules = [ 'GEOSITE,CN,DIRECT', 'GEOIP,cn,DIRECT,no-resolve', 'GEOIP, CN, DIRECT', 'GEOIP,private,DIRECT',
	'RULE-SET,direct,DIRECT', 'MATCH,Fixture' ];
function assembledRules(region, rules) {
	return profile.assemble({ ...remote.config, rules, 'rule-providers': { direct: { type: 'http', behavior: 'domain',
		url: 'https://rules.test/direct.yaml', path: './direct.yaml', interval: 86400 } } },
		{ ...settings(), region }, endpoint()).config?.rules;
}
check(sprintf('%J', assembledRules('overseas', regionRules)) == sprintf('%J', [ 'GEOSITE,CN,Fixture', 'GEOIP,cn,Fixture,no-resolve',
	'GEOIP,CN,Fixture', 'GEOIP,private,DIRECT', 'RULE-SET,direct,DIRECT', 'MATCH,Fixture' ]),
	'海外必须把中国直连规则改走 MATCH 的出站，其余规则原样保留');
check(sprintf('%J', assembledRules('cn', regionRules)) == sprintf('%J', regionRules), '中国地区不改规则');
const finalRules = [ 'GEOSITE,CN,DIRECT', 'FINAL,Fixture' ];
check(sprintf('%J', assembledRules('overseas', finalRules)) == sprintf('%J', finalRules), '没有 MATCH 规则时不改规则');
const directRules = [ 'GEOSITE,CN,DIRECT', 'MATCH, direct ' ];
check(sprintf('%J', assembledRules('overseas', directRules)) == sprintf('%J', directRules), 'MATCH 指向 DIRECT 时不改规则');

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
testState.onRequest = () => {
	if (index(latestRequest(), 'api.github.com') >= 0)
		githubRequests++;
	testState.httpStatus = 200;
	testState.response = { ret: 1, data: [ { tag_name: 'v0.0.4', published_at: '2026-04-01T00:00:00Z', prerelease: false } ] };
};
check(release.checkApp().latest == '0.0.4' && githubRequests == 1, 'GitHub 限流期间仍须读取网站发布缓存');

now += 20;
githubRequests = 0;
testState.responseHeaders = 'HTTP/2 200\r\n\r\n';
testState.onRequest = () => {
	const github = index(latestRequest(), 'api.github.com') >= 0;
	if (github)
		githubRequests++;
	testState.httpStatus = 200;
	testState.response = github
		? [ { tag_name: 'v0.0.1', published_at: '2026-01-01T00:00:00Z', prerelease: false } ]
		: { packages: { 'mihomo-meta': '1.19.32' } };
};
release.checkPeriodic();
check(githubRequests == 1 && readJson('/var/run/ecycloud/updates.json').app.ok &&
	readJson('/var/run/ecycloud/updates.json').next_check == now + 3600, '检查成功后必须一小时后再查');
now += 3599;
release.checkPeriodic();
check(githubRequests == 1, '距上次检查不满一小时不能重复检查');
release.checkPeriodic(true);
check(githubRequests == 2 && readJson('/var/run/ecycloud/updates.json').next_check == now + 3600,
	'接管成功时必须立即检查，不等满一小时');

for (let siteUp in [ true, false ]) {
	githubRequests = 0;
	let siteRequests = 0;
	testState.onRequest = () => {
		const text = latestRequest();
		const github = index(text, 'api.github.com') >= 0;
		const site = index(text, 'https://panel.test/api/client/v1/releases/client') >= 0;
		if (github)
			githubRequests++;
		if (site)
			siteRequests++;
		testState.httpStatus = site && !siteUp ? 503 : 200;
		testState.response = site
			? (siteUp ? { ret: 1, data: [ { tag_name: 'v0.0.3', published_at: '2026-03-01T00:00:00Z', prerelease: false } ] }
				: { ret: 0, msg: 'fixture-unavailable' })
			: [ { tag_name: 'v0.0.2', published_at: '2026-02-01T00:00:00Z', prerelease: false } ];
	};
	const app = release.checkApp();
	check(siteRequests == 1 && app.ok && app.latest == (siteUp ? '0.0.3' : '0.0.2') && githubRequests == (siteUp ? 0 : 1),
		'网站发布缓存可用时不能请求 GitHub，网站 503 时必须回落 GitHub');
}
now -= 3619;

if (rpc != null) {
	securityFixture('0');
	const updateFile = '/var/run/ecycloud/update.json';
	testState.files['/proc/self/status'] = 'Name:\tucode\nPid:\t4242\n';
	let profileFetches = 0;
	let geoRequests = 0;
	testState.onRequest = () => {
		const request = latestRequest();
		if (index(request, '/config/clash') >= 0) {
			profileFetches++;
			testState.response = { ret: 1, data: remote };
		} else if (index(request, '/configs/geo') >= 0) {
			geoRequests++;
			testState.response = {};
		} else
			testState.response = index(request, '/user/') >= 0 ? { ret: 1, data: { enable: 1, config_revision: 'r1' } } : { version: 'fixture' };
	};
	const workerStarts = () => length(filter(testState.commands, c => index(c, 'ecycloud-ctl update-tasks') >= 0));
	const taskOf = id => filter(rpc.status.call({ args: {} }).update_tasks ?? [], task => task.id == id)[0];
	testState.commands = [];
	const queued = rpc.update.call({ args: { what: '', path: '', locale: 'zh-CN' } });
	check(queued.ok && queued.pending == true && length(queued.id) == 16 && profileFetches == 0 && workerStarts() == 1,
		'刷新配置的 RPC 必须立即返回并交给后台任务，rpcd 里不能拉取配置');
	testState.random = 'fedcba9876543210fedcba9876543210';
	check(rpc.update.call({ args: { what: '', path: '', locale: 'zh-CN' } }).id == queued.id && length(readJson(updateFile).tasks) == 1 &&
		workerStarts() == 2, '排队中的同类刷新必须合并成同一个任务');
	const geo = rpc.update.call({ args: { what: 'geo', path: '', locale: 'zh-CN' } });
	testState.random = '0123456789abcdef0123456789abcdef';
	check(geo.pending == true && geo.id != queued.id && geoRequests == 0, 'GeoData 更新也必须交给后台任务');
	check(taskOf(queued.id)?.state == 'queued' && taskOf(geo.id)?.state == 'queued', 'status 必须带上排队中的后台任务');
	testState.files['/var/run/ecycloud/stopping'] = '';
	runUpdates();
	delete testState.files['/var/run/ecycloud/stopping'];
	const profileTask = taskOf(queued.id);
	const geoTask = taskOf(geo.id);
	check(profileTask?.state == 'done' && profileTask.ok && profileTask.changed && profileFetches == 1 &&
		geoTask?.state == 'done' && geoTask.ok && geoTask.changed == false && geoRequests == 1 && readJson(updateFile).pid == 0,
		'后台任务必须逐个执行，停机标记期间也要把刷新与 GeoData 的结果写回 status');
	testState.files[updateFile] = sprintf('%J', { pid: 999, tasks: [
		{ id: 'lost', session: credentials.session_id, kind: 'profile', locale: '', state: 'running' },
		{ id: 'other', session: 'other-session', kind: 'profile', locale: '', state: 'done', ok: true } ] });
	const lost = taskOf('lost');
	check(lost?.state == 'done' && !lost.ok && lost.msg == '后台更新已中断，请重试' && taskOf('other') == null,
		'后台进程意外退出时必须报告任务中断，其他会话的任务不能出现在当前会话');
	testState.httpStatus = 0;
	const offline = rpc.update.call({ args: { what: 'geo', path: '', locale: '' } });
	testState.httpStatus = 200;
	check(!offline.ok && offline.msg == '内核未运行' && offline.pending == null, '内核控制面不可用时 GeoData 更新必须立即报错，不排后台任务');
	testState.files[updateFile] = sprintf('%J', { pid: 0, tasks: [ { id: 'old', session: credentials.session_id, kind: 'profile', locale: '', state: 'queued' } ] });
	check(rpc.logout.call({ args: {} }).ok, '面板通知失败也必须退出成功');
	collectGarbage();
	check(testState.files[updateFile] == null, '退出后的回收必须清掉旧账户的后台更新任务');

	const fetchProfile = testState.onRequest;
	securityFixture('0');
	testState.files['/proc/self/status'] = 'Name:\tucode\nPid:\t4242\n';
	let announceRequests = 0;
	testState.onRequest = () => {
		if (index(latestRequest(), '/announcements') >= 0)
			announceRequests++;
		testState.response = { ret: 1, data: { announcements: [ { id: 7, title: 'fixture-notice', date: '2026-11-01', updated_at: 'u7', content: '' } ] } };
	};
	testState.commands = [];
	const announceArgs = path => ({ args: { what: 'announcements', path, locale: 'zh-CN' } });
	const firstRead = rpc.update.call(announceArgs(''));
	check(firstRead.ok && firstRead.loaded == false && announceRequests == 0 && workerStarts() == 0,
		'首页读公告只读路由器缓存，没有缓存时也不能在 rpcd 里请求面板');
	const announceTask = rpc.update.call(announceArgs('refresh'));
	check(announceTask.ok && announceTask.pending == true && length(announceTask.id) == 16 && announceRequests == 0 && workerStarts() == 1,
		'公告刷新必须立即返回并交给后台任务，面板挂起时 rpcd 的 status 等调用不能排在它后面等');
	check(rpc.update.call(announceArgs('refresh')).id == announceTask.id && workerStarts() == 2, '排队中的公告刷新必须合并成同一个任务');
	check(taskOf(announceTask.id)?.state == 'queued' && !rpc.update.call({ args: { what: 'announcements', path: 'refresh', locale: 'x\r\ny' } }).ok,
		'status 必须带上排队中的公告任务，非法语言不得排进后台队列');
	runUpdates();
	const announceDone = taskOf(announceTask.id);
	const announceView = rpc.update.call(announceArgs(''));
	check(announceDone?.state == 'done' && announceDone.ok && announceRequests == 1 && announceView.loaded && announceView.items[0].title == 'fixture-notice' &&
		announceView.has_unread && announceRequests == 1, '后台任务拉到公告后，界面读缓存即可显示，读取不再请求面板');
	testState.httpStatus = 0;
	const failedTask = rpc.update.call(announceArgs('refresh'));
	runUpdates();
	testState.httpStatus = 200;
	check(taskOf(failedTask.id)?.ok == false && rpc.update.call(announceArgs('')).items[0].title == 'fixture-notice',
		'后台拉取失败时任务报失败，已缓存的公告保留');

	securityFixture('0');
	testState.onRequest = fetchProfile;
	testState.files['/proc/self/status'] = 'Name:\tucode\nPid:\t4242\n';
	delete testState.files[PROFILE_FILE];
	delete testState.files[profile.PENDING_FILE];
	profileFetches = 0;
	testState.commands = [];
	const starting = rpc.start.call({ args: {} });
	check(starting.ok && starting.pending == true && length(starting.id) == 16 && profileFetches == 0 && workerStarts() == 1 &&
		testState.config.enabled == '0', '内核在运行但没有缓存时，启动接口必须把拉配置交给后台任务并立即返回，不能先开启服务');
	runUpdates();
	check(taskOf(starting.id)?.state == 'done' && taskOf(starting.id).ok && profileFetches == 1 && cached(true) != null,
		'启动前的配置刷新必须在后台任务里完成并写回结果');
	testState.commands = [];
	check(rpc.start.call({ args: { refreshed: true } }).ok && testState.config.enabled == '1' && workerStarts() == 0 &&
		length(filter(testState.commands, c => index(c, '/etc/init.d/ecycloud restart') >= 0)) == 1,
		'后台刷新成功后带 refreshed 再次启动必须照原流程开启服务');
	delete testState.files[PROFILE_FILE];
	delete testState.files[profile.PENDING_FILE];
	testState.config.enabled = '0';
	testState.commands = [];
	check(cached(true) == null && rpc.start.call({ args: { refreshed: true } }).ok && profileFetches == 1 && workerStarts() == 0 && testState.config.enabled == '1',
		'带 refreshed 的启动不能再次排队刷新');
	testState.onRequest = null;
}

for (let days in [ 2, 10 ]) {
	securityFixture('0');
	delete testState.files['/proc/41/cmdline'];
	const at = gmtime(now + days * 86400);
	testState.files[CRED_FILE] = sprintf('%J', { ...credentials,
		expires_at: sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', at.year, at.mon, at.mday, at.hour, at.min, at.sec) });
	let expiryRounds = 0;
	global.sleep = () => { now += 3600; if (++expiryRounds == 30) testState.files['/var/run/ecycloud/stopping'] = ''; };
	refresh();
	const warnings = length(filter(testState.commands, c => index(c, 'logger') == 0 && index(c, 'daemon.warning') > 0 && index(c, '登录将于') >= 0));
	check(warnings == (days == 2 ? 2 : 0), days == 2
		? `登录剩余 3 天以内时后台每天写一条到期提醒，30 小时内应 2 条，实际 ${warnings} 条` : '登录剩余超过 3 天时不写到期提醒');
}

printf('OpenWrt 运行逻辑同步回归通过：%d 项断言。\n', assertions);
