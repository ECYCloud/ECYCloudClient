'use strict';

import { access, lsdir, mkdir, open, readfile, rename, rmdir, unlink, writefile } from 'fs';
import { cursor } from 'uci';

import * as clash from 'ecycloud.clash';
import * as network from 'ecycloud.network';
import * as panel from 'ecycloud.panel';
import * as icons from 'ecycloud.icons';
import * as profile from 'ecycloud.profile';
import * as statistics from 'ecycloud.statistics';
import * as release from 'ecycloud.release';

import { API_FILE, CONF_DIR, DELAY_FILE, KICK_FILE, PROFILE_FILE, SESSION_CHANGE, SPEED_FILE, STATE_DIR,
		 coreRunning, creds, ensurePrivateDir, instances, log, panelDirectHosts, randomHex, sessionBinding,
		 markKicked, readJson, setError, setState, settings, shellquote, state,
		 writeJson, writePrivateJson } from 'ecycloud.common';

const SELECTOR_FILE = `${CONF_DIR}/selectors.json`;
const SPEED_QUOTA_FILE = `${CONF_DIR}/speed_quota.json`;
const DELAY_LOCK = `${STATE_DIR}/delay.lock`;
const SPEED_LOCK = `${STATE_DIR}/speed.lock`;
const INIT = '/etc/init.d/ecycloud';

/* 与面板 /user/speed-test 同一口径：同账号同节点 1 小时 5 次成功，超级管理员（id=1）不限 */
const SPEED_LIMIT = 5;
const SPEED_WINDOW = 3600;
/* 内核自己按 10 并发分批测整组，客户端取 8：再高就互相抢带宽把延迟测虚高 */
const DELAY_CONCURRENCY = 8;

/* procd 先跑 stop_service 再杀实例，看门狗因此可能在撤规则之后又把规则铺回去 */
const STOP_FILE = `${STATE_DIR}/stopping`;
const BLOCK_FILE = `${STATE_DIR}/blocked.json`;

function stopping() {
	return access(STOP_FILE);
};

export function selectors() {
	const saved = readJson(SELECTOR_FILE);
	if (type(saved) != 'object' || type(saved.selected) != 'object')
		return {};

	const account = lc(trim(creds().email ?? ''));
	return length(account) && saved.account == account ? saved.selected : {};
};

function build(remote, cfg, api) {
	panelDirectHosts(true);
	const assembled = profile.assemble(remote, cfg, api, selectors());
	if (!assembled.ok)
		return assembled;

	const json = sprintf('%J', assembled.config);
	if (readfile(`${cfg.runDir}/config.json`) == json && !profile.geodataMissing(cfg.runDir))
		return { ...profile.writeNodeProviders(cfg.runDir, assembled.config), json };

	const written = profile.write(cfg.runDir, assembled.config);
	if (!written.ok)
		return written;

	const valid = profile.validate(cfg.runDir);
	const providers = valid.ok ? profile.writeNodeProviders(cfg.runDir, assembled.config) : valid;
	if (!providers.ok) {
		const restored = profile.rollback(cfg.runDir);
		return { ok: false, error: `${valid.ok ? providers.error : '配置未通过内核校验：' + valid.error}${restored ? '' : '；恢复旧配置失败'}` };
	}

	return { ok: true, json };
};

function saveSelectors(next) {
	if (type(next) != 'object')
		return;

	const snap = selectors();
	let dirty = false;

	for (let group, name in next) {
		if (!length(group) || !length(name) || snap[group] == name)
			continue;
		snap[group] = name;
		dirty = true;
	}

	if (dirty)
		writePrivateJson(SELECTOR_FILE, { account: lc(trim(creds().email ?? '')), selected: snap });
};

export function rememberSelector(group, name) {
	if (!length(group) || !length(name))
		return;

	const next = {};
	next[group] = name;
	saveSelectors(next);
};

export function applySelectors() {
	const snap = selectors();
	const current = clash.proxies();
	if (!current.ok)
		return;

	for (let group, name in snap) {
		const entry = current.data?.proxies?.[group];
		if (entry?.type != 'Selector' || !(name in (entry.all ?? [])) || entry.now == name)
			continue;
		const res = clash.select(group, name);
		if (res.ok && length(entry.now))
			clash.closeVia(entry.now);
	}
};

function speedUnlimited() {
	return +(panel.account()?.id ?? 0) == 1;
};

function speedStamps() {
	const saved = readJson(SPEED_QUOTA_FILE);
	const account = lc(trim(creds().email ?? ''));
	return length(account) && saved?.account == account && type(saved.nodes) == 'object'
		? saved.nodes : {};
};

function saveSpeedStamps(nodes) {
	const kept = {};

	for (let name, stamps in nodes)
		if (length(stamps))
			kept[name] = stamps;

	writePrivateJson(SPEED_QUOTA_FILE, { account: lc(trim(creds().email ?? '')), nodes: kept });
};

function freshStamps(list, now) {
	const out = [];

	for (let stamp in (type(list) == 'array' ? list : []))
		if (+stamp >= now - SPEED_WINDOW)
			push(out, +stamp);

	return out;
};

/* 本地先按同一口径拦一次：面板仍是权威，但已知超限的节点不必再跑一趟 /user/speed-test */
export function speedQuota(names) {
	if (speedUnlimited())
		return { allowed: names, msg: '' };

	const now = time();
	const nodes = speedStamps();
	const allowed = [];
	let reset = 0;

	for (let name in names) {
		const stamps = freshStamps(nodes[name], now);
		if (length(stamps) < SPEED_LIMIT) {
			push(allowed, name);
			continue;
		}
		const at = stamps[0] + SPEED_WINDOW;
		if (!reset || at < reset)
			reset = at;
	}

	return {
		allowed,
		msg: length(allowed)
			? ''
			: `测速次数已达上限，请在 ${int((reset - now + 59) / 60)} 分钟后再试`
	};
};

export function noteSpeedSuccess(name) {
	if (speedUnlimited() || !length(name))
		return;

	const now = time();
	const nodes = speedStamps();
	nodes[name] = freshStamps(nodes[name], now);
	push(nodes[name], now);
	saveSpeedStamps(nodes);
};

export function noteSpeedDenied(name, resetAt) {
	if (speedUnlimited() || !length(name))
		return;

	const oldest = (+resetAt > 0 ? +resetAt : time() + SPEED_WINDOW) - SPEED_WINDOW;
	const nodes = speedStamps();
	const stamps = [];

	for (let i = 0; i < SPEED_LIMIT; i++)
		push(stamps, oldest);

	nodes[name] = stamps;
	saveSpeedStamps(nodes);
};

export function syncIcons() {
	icons.sync();
};

export function runCloseVia(outbound) {
	clash.closeVia(outbound);
};

export function closeViaLater(outbound) {
	if (!length(outbound))
		return;

	system(`${shellquote('/usr/libexec/ecycloud-ctl')} close-via ${shellquote(outbound)} >/dev/null 2>&1 &`);
};

export function prepare(retrying) {
	const cfg = settings();

	if (!retrying) {
		unlink(STOP_FILE);
		unlink(BLOCK_FILE);
	} else if (stopping() || !cfg.enabled) {
		return false;
	}

	if (!panel.session().logged_in) {
		setError(panel.session().expired ? '登录已失效，请重新登录' : '尚未登录面板，请先在 LuCI 的「概览」页登录');
		return false;
	}

	setState('preparing', '正在准备内核配置');

	let cached = profile.cached(access(profile.PENDING_FILE));
	let fetchedRemote = null;
	if (cached?.config) {
		const checked = profile.inspect(cached.config);
		if (!checked.ok)
			cached = null;
	}

	if (!cached?.config) {
		const fetched = panel.clashProfile();
		if (!fetched.ok) {
			/* 401 是面板把账号/会话拒了（账号被禁用、令牌失效），原文照搬比「拉取配置失败」有指导性 */
			setState('failed', '', fetched.status == 401 ? fetched.msg : `拉取配置失败：${fetched.msg}`,
				fetched.status == 0 || fetched.status == 429 || fetched.status >= 500);
			return false;
		}
		const checked = profile.inspect(fetched.data.config);
		if (!checked.ok) {
			setError(checked.error);
			return false;
		}
		if (!profile.authorized({ ...fetched.data, binding: sessionBinding() })) {
			setError('配置离线授权无效，请刷新配置');
			return false;
		}
		cached = fetched.data;
		fetchedRemote = fetched.data;
	}

	setState('validating', profile.geodataMissing(cfg.runDir)
		? '正在校验配置：首次启动需由内核下载 GeoIP / GeoSite 数据，可能耗时数分钟'
		: '正在校验配置');

	const built = build(cached.config, { ...cfg, enabled: false }, clash.reserve());
	if (!built.ok) {
		setError(built.error);
		return false;
	}
	if (fetchedRemote != null && !profile.store(fetchedRemote, true)) {
		setError('无法暂存已校验配置，请重试');
		return false;
	}

	setState('starting', '正在启动内核');

	return true;
};

export function retryPrepare() {
	let delay = 1;
	while (!stopping() && settings().enabled && panel.session().logged_in) {
		for (let waited = 0; waited < delay; waited++) {
			if (stopping() || !settings().enabled)
				return;
			sleep(1000);
		}
		if (prepare(true)) {
			if (!stopping() && settings().enabled)
				system(`trap "" HUP; ${INIT} start >/dev/null 2>&1 &`);
			return;
		}
		if (!state().retryable)
			return;
		delay = min(delay * 2, 30);
	}
};

export function standby() {
	setState('stopped', '');
	system('/usr/libexec/ecycloud-ctl revert >/dev/null 2>&1 &');
};

function applyKick(account) {
	const uci = cursor();
	uci.set('ecycloud', 'config', 'enabled', '0');
	uci.commit('ecycloud');
	const reason = account?.data?.device_kick_reason ?? 'limit';
	markKicked(reason);
	standby();
	panel.ackDeviceKick();
	log('notice', 'kicked by device remove');
};

function kickedByNotice(account) {
	return account.ok && account.data?.device_kick_notice == true &&
		account.data?.device_kick_reason == 'remove';
};

export function startStandby() {
	if (coreRunning())
		return;

	const st = state();
	if (st.stage == 'preparing' || st.stage == 'validating' || st.stage == 'starting')
		return;

	/* 起不来的原因一分钟内多半不会变（账号被禁、面板 401、geodata 拉不到）：
	   每开一次节点页都重跑 prepare 会把限流的面板接口反复打满 */
	if (st.stage == 'failed' && time() - +st.updated < 60)
		return;

	if (!panel.session().logged_in)
		return;

	unlink(STOP_FILE);
	system(`${INIT} start >/dev/null 2>&1 &`);
};

export function deactivate() {
	const cfg = settings();
	let tunStopped = true;
	if (coreRunning()) {
		tunStopped = clash.setTunEnabled(false).ok;
		if (tunStopped && readJson(`${cfg.runDir}/config.json`)?.tun?.enable == true)
			tunStopped = profile.setRunTun(cfg.runDir, false);
	}
	const restored = network.revert();
	return restored && tunStopped;
};

export function block(reason) {
	const uci = cursor();
	uci.set('ecycloud', 'config', 'enabled', '0');
	uci.commit('ecycloud');
	writePrivateJson(BLOCK_FILE, { reason });
	unlink(PROFILE_FILE);
	unlink(profile.PENDING_FILE);
	deactivate();
	setError(reason);
	system(`trap "" HUP; ${INIT} stop >/dev/null 2>&1 &`);
};

export function activate(config) {
	const cfg = config ?? settings();
	if (!panel.session().logged_in || !profile.cached(access(profile.PENDING_FILE))) {
		block('配置离线授权或登录已失效，请重新登录或刷新配置');
		return false;
	}
	const providers = clash.providerProgress();
	if (providers.ready < providers.total) {
		setState('starting', `正在加载规则集：${providers.ready}/${providers.total}`);
		return false;
	}
	const applied = network.apply(cfg);

	if (!applied.ok) {
		if (!stopping() && settings().enabled)
			setError(`透明代理规则未生效：${applied.error}`);
		return false;
	}
	if (cfg.mode == 'tun' && (!clash.setTunEnabled(true).ok || !profile.setRunTun(cfg.runDir, true))) {
		deactivate();
		setError('TUN 接管失败，已恢复网络设置');
		return false;
	}

	setState('running', cfg.mode == 'tun' ? 'TUN 模式已接管转发' : 'TPROXY 模式已接管转发');

	return true;
};

function emptyDelayJob() {
	return { queue: [], testing: [], failed: [], reselect: [], groups: {}, pid: 0 };
};

export function delayJob() {
	return readJson(DELAY_FILE) ?? emptyDelayJob();
};

function emptySpeedJob() {
	return { queue: [], testing: [], failed: [], speeds: {}, groups: {}, pid: 0 };
};

export function speedJob() {
	return readJson(SPEED_FILE) ?? emptySpeedJob();
};

function currentPid() {
	const m = match(readfile('/proc/self/status') ?? '', /Pid:\s+(\d+)/);
	return m ? +m[1] : 0;
};

function writeTestJob(path, update, owner) {
	ensurePrivateDir(STATE_DIR);
	const lock = open(path + '.lock', 'a', 0600);
	if (!lock)
		die('无法打开测试任务锁');
	if (!lock.lock('x')) {
		lock.close();
		die('无法锁定测试任务');
	}

	let saved = null;
	try {
		if (update == null) {
			unlink(path);
			rmdir(path == DELAY_FILE ? DELAY_LOCK : SPEED_LOCK);
		} else if (!stopping()) {
			const job = path == DELAY_FILE ? delayJob() : speedJob();
			if ((owner == null || job.pid == owner) && update(job) !== false) {
				const temporary = path + '.' + currentPid() + '.tmp';
				if (!writeJson(temporary, job) || !rename(temporary, path)) {
					unlink(temporary);
					die('无法保存测试任务');
				}
				saved = job;
			}
		}
	} catch (e) {
		lock.close();
		die(e.message);
	}
	lock.close();
	return saved;
};

export function cleanup() {
	ensurePrivateDir(STATE_DIR);
	writefile(STOP_FILE, '');
	writeTestJob(DELAY_FILE, null);
	writeTestJob(SPEED_FILE, null);

	if (!deactivate()) {
		setError('网络设置恢复失败');
		return false;
	}
	const blocked = readJson(BLOCK_FILE);
	if (length(blocked?.reason))
		setError(blocked.reason);
	else
		setState('stopped', '');
	return true;
};

export function changeSession(action, logout) {
	ensurePrivateDir(STATE_DIR);
	const authLock = open(`${STATE_DIR}/account-switch.lock`, 'ae', 0600);
	if (!authLock)
		return { ok: false, msg: '无法打开账户切换锁' };
	if (!authLock.lock('xn')) {
		authLock.close();
		return { ok: false, msg: '账户正在切换，请稍后重试' };
	}
	let lease = null;
	let result;
	try {
		if (!logout && panel.session().logged_in)
			die('请先退出当前账户');
		if (writefile(SESSION_CHANGE, '') == null)
			die('无法阻止新的后台任务');
		const uci = cursor();
		if (!uci.set('ecycloud', 'config', 'enabled', '0') || !uci.commit('ecycloud'))
			die('无法关闭旧账户连接');
		const stopped = `${STATE_DIR}/session-stop-${randomHex(6)}`;
		/* procd 自身的服务锁串行化 start / stop；不在 rpcd 内同步等待 ubus。 */
		if (system(`(${INIT} stop >/dev/null 2>&1; printf '%s' "$?" >${shellquote(stopped)}) &`) != 0)
			die('无法停止旧账户服务');
		lease = open(`${STATE_DIR}/session.lock`, 'ae', 0600);
		if (!lease)
			die('无法打开会话锁');
		let ready = false;
		for (let i = 0; i < 80; i++) {
			const status = readfile(stopped);
			if (length(status) && status != '0')
				die('旧账户服务停止失败');
			const live = instances();
			if (status == '0' && !live.core?.running && !live.watchdog?.running && lease.lock('xn')) {
				ready = true;
				break;
			}
			sleep(100);
		}
		if (!ready)
			die('旧账户任务尚未全部退出，请稍后重试');
		unlink(stopped);
		if (!network.revert())
			die('旧账户网络设置尚未恢复');
		const runDir = settings().runDir;
		if (system(`rm -rf -- ${shellquote(runDir)}`) != 0 || access(runDir))
			die('无法清除旧账户运行目录');
		panel.clearCache();
		statistics.clear(true);
		for (let path in [ API_FILE, DELAY_FILE, SPEED_FILE, KICK_FILE ])
			if (access(path) && !unlink(path))
				die('无法清除旧账户运行数据');
		for (let name in (lsdir(STATE_DIR) ?? []))
			if (match(name, /^(req|resp)-[a-f0-9]+\.(json|conf|err)$/) && !unlink(`${STATE_DIR}/${name}`))
				die('无法清除旧账户请求缓存');
		rmdir(DELAY_LOCK);
		rmdir(SPEED_LOCK);
		setState('stopped', '');
		result = action();
		if (!unlink(SESSION_CHANGE))
			die('无法结束账户切换');
	} catch (e) {
		result = { ok: false, msg: e.message };
	}
	lease?.close();
	authLock.close();
	return result;
};

function withoutName(list, name) {
	const out = [];

	for (let item in (list ?? []))
		if (item != name)
			push(out, item);

	return out;
};

function withName(list, name) {
	for (let item in (list ?? []))
		if (item == name)
			return list;

	const out = [];

	for (let item in (list ?? []))
		push(out, item);

	push(out, name);
	return out;
};

function nameQueued(job, name) {
	for (let item in (job.queue ?? []))
		if (item == name)
			return true;

	for (let item in (job.testing ?? []))
		if (item == name)
			return true;

	return false;
};

function pendingNames(job) {
	const pending = {};

	for (let name in (job.queue ?? []))
		pending[name] = true;
	for (let name in (job.testing ?? []))
		pending[name] = true;

	return pending;
};

function pruneGroups(job) {
	const pending = pendingNames(job);
	const prev = job.groups;
	const next = {};

	if (type(prev) == 'object') {
		for (let group in prev) {
			const leaves = prev[group];
			if (type(leaves) != 'array')
				continue;
			for (let name in leaves) {
				if (pending[name]) {
					next[group] = leaves;
					break;
				}
			}
		}
	}

	job.groups = next;
};

function workerAlive() {
	const job = delayJob();
	return job.pid > 0 && access(`/proc/${job.pid}`);
};

export function delayActive() {
	return workerAlive();
};

function detachCtl(verb) {
	system(`trap "" HUP; /usr/libexec/ecycloud-ctl ${verb} >/dev/null 2>&1 &`);
};

function jobPending(job) {
	return length(job?.queue) || length(job?.testing) || length(job?.reselect);
};

function startDelayWorker() {
	const job = writeTestJob(DELAY_FILE, function(job) {
		if (workerAlive())
			return false;
		rmdir(DELAY_LOCK);

		for (let name in (job.testing ?? [])) {
			if (!length(name) || nameQueued({ queue: job.queue, testing: [] }, name))
				continue;
			push(job.queue, name);
		}

		job.testing = [];
		job.pid = 0;
	});
	if (job)
		detachCtl('delay');
};

export function ensureDelayWorker() {
	if (clash.ready() && jobPending(delayJob()) && !delayActive())
		startDelayWorker();
};

export function enqueueDelay(names, reselectGroup, testGroup) {
	const job = writeTestJob(DELAY_FILE, function(job) {
		pruneGroups(job);

		for (let name in names) {
			if (!length(name))
				continue;
			if (!nameQueued(job, name))
				push(job.queue, name);
			job.failed = withoutName(job.failed, name);
		}

		if (length(reselectGroup))
			job.reselect = withName(job.reselect, reselectGroup);

		if (length(testGroup)) {
			const leaves = [];
			for (let name in names)
				if (length(name))
					push(leaves, name);
			job.groups[testGroup] = leaves;
		}
	});
	if (job)
		startDelayWorker();
	return { ok: job != null };
};

function releaseDelayLock(self, failed) {
	return writeTestJob(DELAY_FILE, function(job) {
		if (failed) {
			for (let name in (job.queue ?? []))
				job.failed = withName(job.failed, name);
			job.queue = [];
			job.reselect = [];
		} else if (length(job.queue) || length(job.reselect)) {
			return false;
		}

		job.pid = 0;
		job.testing = [];
		job.groups = {};
		rmdir(DELAY_LOCK);
	}, self) != null;
};

export function runDelay() {
	const self = currentPid();
	let job = writeTestJob(DELAY_FILE, function(job) {
		if (!mkdir(DELAY_LOCK))
			return false;
		job.pid = self;
	});
	if (!job)
		return;
	let reported = false;

	while (true) {
		job = delayJob();
		if (stopping() || job.pid != self)
			return;

		if (!length(job.queue)) {
			for (let group in job.reselect) {
				if (stopping() || delayJob().pid != self)
					return;
				clash.reselect(group);
				job = writeTestJob(DELAY_FILE, function(job) {
					if (!length(job.queue))
						job.reselect = withoutName(job.reselect, group);
				}, self);
				if (!job)
					return;
			}

			if (releaseDelayLock(self))
				return;
			continue;
		}

		if (!clash.ready()) {
			if (!panel.session().logged_in || stopping() || state().stage == 'failed') {
				releaseDelayLock(self, true);
				return;
			}

			startStandby();
			sleep(1000);
			continue;
		}

		const batch = [];
		job = writeTestJob(DELAY_FILE, function(job) {
			while (length(batch) < DELAY_CONCURRENCY && length(job.queue)) {
				const name = shift(job.queue);
				push(batch, name);
				job.testing = withName(job.testing, name);
			}
		}, self);
		if (!job)
			return;

		const results = clash.delayBatch(batch, 5000);

		let report = false;
		job = writeTestJob(DELAY_FILE, function(job) {
			for (let name in batch) {
				const ok = +(results[name] ?? 0) > 0;
				if (ok && !reported) {
					report = true;
					reported = true;
				}
				job.testing = withoutName(job.testing, name);
				job.queue = withoutName(job.queue, name);
				job.failed = ok ? withoutName(job.failed, name) : withName(job.failed, name);
			}
			pruneGroups(job);
		}, self);
		if (!job)
			return;
		if (report)
			panel.reportNodeUsed();
	}
};

function speedWorkerAlive() {
	const job = speedJob();
	return job.pid > 0 && access(`/proc/${job.pid}`);
};

export function speedActive() {
	return speedWorkerAlive();
};

function startSpeedWorker() {
	const job = writeTestJob(SPEED_FILE, function(job) {
		if (speedWorkerAlive())
			return false;
		rmdir(SPEED_LOCK);

		for (let name in (job.testing ?? [])) {
			if (!length(name) || nameQueued({ queue: job.queue, testing: [] }, name))
				continue;
			push(job.queue, name);
		}
		job.testing = [];
		job.pid = 0;
	});
	if (job)
		detachCtl('speed');
};

export function ensureSpeedWorker() {
	if (clash.ready() && jobPending(speedJob()) && !speedActive())
		startSpeedWorker();
};

export function enqueueSpeed(names, testGroup) {
	const job = writeTestJob(SPEED_FILE, function(job) {
		for (let name in names) {
			if (!length(name))
				continue;
			if (!nameQueued(job, name))
				push(job.queue, name);
			job.failed = withoutName(job.failed, name);
		}

		if (length(testGroup)) {
			const leaves = [];
			for (let name in names)
				if (length(name))
					push(leaves, name);
			job.groups[testGroup] = leaves;
		}
	});
	if (job)
		startSpeedWorker();
	return { ok: job != null };
};

export function runSpeed() {
	const self = currentPid();
	let job = writeTestJob(SPEED_FILE, function(job) {
		if (!mkdir(SPEED_LOCK))
			return false;
		job.pid = self;
	});
	if (!job)
		return;
	let reported = false;

	while (true) {
		job = speedJob();
		if (stopping() || job.pid != self)
			return;

		if (!length(job.queue)) {
			job = writeTestJob(SPEED_FILE, function(job) {
				if (length(job.queue))
					return false;
				job.testing = [];
				job.groups = {};
				job.pid = 0;
				rmdir(SPEED_LOCK);
			}, self);
			if (job)
				return;
			continue;
		}

		if (!clash.ready()) {
			if (!panel.session().logged_in || stopping() || state().stage == 'failed') {
				writeTestJob(SPEED_FILE, function(job) {
					for (let name in (job.queue ?? []))
						job.failed = withName(job.failed, name);
					job.queue = [];
					job.testing = [];
					job.groups = {};
					job.pid = 0;
					rmdir(SPEED_LOCK);
				}, self);
				return;
			}

			startStandby();
			sleep(1000);
			continue;
		}

		let name;
		job = writeTestJob(SPEED_FILE, function(job) {
			name = shift(job.queue);
			if (name != null)
				job.testing = withName(job.testing, name);
		}, self);
		if (!job)
			return;
		if (name == null)
			continue;

		const res = clash.speedOne(name);
		const bps = +(res.bytes_per_second ?? 0);
		let ok = res.ok && bps > 0;
		if (stopping() || speedJob().pid != self)
			return;
		if (ok) {
			noteSpeedSuccess(name);
			const written = panel.reportSpeedTest(name, bps);
			const denied = written.data?.denied ?? [];
			if (length(denied) && !length(written.data?.allowed ?? [])) {
				noteSpeedDenied(name, +(denied[0]?.reset_at ?? 0));
				ok = false;
			}
		}
		if (ok && !reported) {
			panel.reportNodeUsed();
			reported = true;
		}

		job = writeTestJob(SPEED_FILE, function(job) {
			if (type(job.speeds) != 'object')
				job.speeds = {};
			if (ok)
				job.speeds[name] = bps;
			job.testing = withoutName(job.testing, name);
			job.queue = withoutName(job.queue, name);
			job.failed = ok ? withoutName(job.failed, name) : withName(job.failed, name);
		}, self);
		if (!job)
			return;
	}
};

/* 逐个 PUT 最长 30 秒，串在 rpcd 里会把整份 LuCI 堵住，改跟 delay / speed 一样脱开跑 */
export function runRuleProviders() {
	if (!clash.ready())
		return;

	for (let name, provider in (profile.cached()?.config?.['rule-providers'] ?? {})) {
		if (provider?.type != 'http')
			continue;
		const res = clash.updateRuleProvider(name);
		if (!res.ok)
			log('warning', `规则集「${name}」更新失败：${res.error}`);
	}
};

export function update(force, accountResponse, locale) {
	const cfg = settings();

	if (!panel.session().logged_in)
		return { ok: false, error: '尚未登录面板' };

	const cached = profile.cached();
	const account = accountResponse ?? panel.refreshAccount(null, null, locale);
	if (account.restricted) {
		block(account.msg);
		return { ok: false, error: account.msg };
	}

	if (!account.ok && !force)
		return { ok: false, error: account.msg };

	if (kickedByNotice(account)) {
		applyKick(account);
		return { ok: true, changed: false };
	}
	const previous = readJson(`${cfg.runDir}/config.json`);
	const api = clash.endpoint() ?? clash.reserve();
	const speedReady = previous?.listeners?.[0]?.users?.[0]?.password == api.speed;

	/* config_revision 与 /config/revision 同值，profile 已经拿过：
	   /config/clash 是 90 秒超时、60 秒内只给 20 次的重接口，自动刷新时戳没变就别去打 */
	if (!force && speedReady && cached?.config?.['proxy-providers']?.[profile.NODE_PROVIDER] != null &&
	    length(account.data?.config_revision) && account.data.config_revision == cached?.revision && profile.authorized(cached, 3600))
		return { ok: true, changed: false };

	const fetched = panel.clashProfile(locale);
	if (!fetched.ok)
		return { ok: false, error: fetched.msg };

	const checked = profile.inspect(fetched.data.config);
	if (!checked.ok)
		return { ok: false, error: checked.error };
	if (!profile.authorized({ ...fetched.data, binding: cached?.binding ?? sessionBinding() }))
		return { ok: false, error: '配置离线授权无效，请刷新配置' };

	if (speedReady && sprintf('%J', fetched.data.config) == sprintf('%J', cached?.config)) {
		profile.store(fetched.data);
		if (force && coreRunning())
			detachCtl('rules');
		return { ok: true, changed: false };
	}

	const built = build(fetched.data.config, cfg, api);
	if (!built.ok)
		return { ok: false, error: built.error };

	const running = coreRunning();
	const next = json(built.json);
	const nodesOnly = running && profile.canUpdateNodes(previous, next);
	const restart = running && !nodesOnly &&
		((previous?.dns?.enable == true && lc(previous.dns['enhanced-mode'] ?? '') == 'fake-ip') ||
		(next.dns?.enable == true && lc(next.dns['enhanced-mode'] ?? '') == 'fake-ip'));
	if ((!running || restart) && !profile.store(fetched.data, true)) {
		profile.rollback(cfg.runDir);
		return { ok: false, error: '无法暂存已校验配置，请重试' };
	}
	if (!running) {
		const st = state();
		if (st.stage == 'validating' || st.stage == 'preparing' || st.stage == 'starting')
			setState('stopped', '');

		return { ok: true, changed: true, reloaded: false };
	}
	if (nodesOnly) {
		const updated = clash.updateProxyProviders(next);
		if (!updated.ok) {
			const restored = profile.rollback(cfg.runDir) && clash.updateProxyProviders(previous).ok;
			return { ok: false, error: `${updated.error}${restored ? '' : '；恢复旧节点配置失败'}` };
		}
		profile.store(fetched.data);
		if (force)
			detachCtl('rules');
		if (cfg.enabled && network.applied()?.active == true)
			setState('running', '面板节点已更新，连接保持不变');
		return { ok: true, changed: true, reloaded: false };
	}

	if (restart) {
		setState('starting', '配置已更新，正在重启内核以保留 DNS 映射');
		system(`trap "" HUP; ${INIT} restart >/dev/null 2>&1 &`);
		return { ok: true, changed: true, reloaded: false };
	}

	const reloaded = clash.applyPayload(built.json);
	if (!reloaded.ok) {
		profile.rollback(cfg.runDir);
		return { ok: false, error: reloaded.error };
	}

	profile.store(fetched.data);
	applySelectors();
	detachCtl('rules');

	if (cfg.enabled && network.applied()?.active == true)
		setState('running', '面板配置已热载');

	return { ok: true, changed: true, reloaded: true };
};

export function refresh() {
	let refreshed = time();
	let identityAt = 0;
	let accountAt = 0;
	let prepared = false;

	while (!stopping() && panel.session().logged_in) {
		const cfg = settings();
		const alive = coreRunning() && clash.ready();
		if (alive && access(profile.PENDING_FILE)) {
			const pending = profile.cached(true);
			if (pending == null || (+(instances().core?.pid ?? 0) != pending.pending_pid && !profile.store(pending))) {
				block('无法提交已加载配置，请刷新配置');
				break;
			}
		}
		if (alive && !prepared) {
			applySelectors();
			prepared = true;
		} else if (!alive) {
			prepared = false;
		}
		if (!alive) {
			refreshed = time();
			identityAt = 0;
			accountAt = 0;
		} else {
			const connected = cfg.enabled && network.applied()?.active == true;
			if (identityAt == 0 || time() - identityAt >= 60) {
				panel.touchIdentity(connected);
				identityAt = time();
			}
			const cached = panel.account();
			const interval = cfg.enabled && +(cached?.node_connector ?? 0) > 0 &&
				cached?.online_client_self != true ? 5 : 60;
			if (accountAt == 0 || time() - accountAt >= interval) {
				const account = panel.refreshAccount(connected);
				accountAt = time();
				if (account.restricted)
					block(account.msg);
				else if (kickedByNotice(account))
					applyKick(account);
				else if (account.ok && length(account.data?.config_revision) &&
					account.data.config_revision != profile.cached()?.revision) {
					const res = update(false, account);
					if (!res.ok)
						log('warning', `panel refresh failed: ${res.error}`);
					refreshed = time();
				}
			}
			if (cfg.refreshInterval > 0 && time() - refreshed >= cfg.refreshInterval * 60) {
				const res = update(false);
				if (!res.ok)
					log('warning', `panel refresh failed: ${res.error}`);
				refreshed = time();
			}
			if (!profile.authorized(profile.cached(), 3600) && time() - refreshed >= 60) {
				update(false);
				refreshed = time();
			}
		}
		if (alive)
			release.checkPeriodic();
		sleep(alive ? 5000 : 1000);
	}
};

export function collectStatistics() {
	while (!stopping() && panel.session().logged_in) {
		statistics.poll();
		sleep(5000);
	}
};

export function watchdog() {
	let waited = 0;

	while (!stopping()) {
		if (!panel.session().logged_in) {
			block('登录已失效，请重新登录');
			break;
		}
		const cfg = settings();
		const record = network.applied();
		let active = record != null && record.active != false;
		const running = coreRunning();
		const alive = running && clash.ready();
		const wait = (alive && active && cfg.enabled) ? 5 : 1;
		if ((cfg.enabled || running) && !profile.cached(access(profile.PENDING_FILE))) {
			block('配置离线授权已到期，请刷新配置');
			break;
		}

		if (alive && cfg.enabled && !active) {
			active = activate(cfg);
			waited = 0;

			if (active && (stopping() || !settings().enabled)) {
				deactivate();
				break;
			}
		} else if (alive && !cfg.enabled) {
			if (active || network.applied() != null)
				active = !deactivate();
			waited = 0;
			if (state().stage == 'starting' || state().stage == 'preparing' ||
				state().stage == 'validating' || state().stage == 'recovering') {
				setState('stopped', '');
			}
		} else if (!alive && (active || network.applied() != null)) {
			active = !network.revert();
			if (active)
				setError('内核未响应，网络设置恢复失败，将继续重试');
			else {
				setState('recovering', '内核未响应，已撤下透明代理规则以保证局域网可用');
				log('err', 'core unreachable, transparent proxy rules reverted');
			}
		} else if (!alive) {
			waited += wait;
			if (waited == 300)
				setError('内核 300 秒内未就绪，请查看「日志」页');
		}

		if (alive) {
			ensureDelayWorker();
			ensureSpeedWorker();
		}
		icons.ensure();

		sleep(wait * 1000);
	}
};
