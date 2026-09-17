'use strict';

import { access, mkdir, open, readfile, rename, rmdir, unlink, writefile } from 'fs';
import { cursor } from 'uci';

import * as clash from 'ecycloud.clash';
import * as network from 'ecycloud.network';
import * as panel from 'ecycloud.panel';
import * as profile from 'ecycloud.profile';

import { CONF_DIR, DELAY_FILE, SPEED_FILE, STATE_DIR, coreRunning, creds, ensurePrivateDir, log,
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

function stopping() {
	return access(STOP_FILE);
};

function build(remote, cfg, api) {
	const assembled = profile.assemble(remote, cfg, api);
	if (!assembled.ok)
		return assembled;

	const json = sprintf('%J', assembled.config);
	if (readfile(`${cfg.runDir}/config.json`) == json && !profile.geodataMissing(cfg.runDir))
		return { ok: true, json };

	const written = profile.write(cfg.runDir, assembled.config);
	if (!written.ok)
		return written;

	const valid = profile.validate(cfg.runDir);
	if (!valid.ok) {
		profile.rollback(cfg.runDir);
		return { ok: false, error: `配置未通过内核校验：${valid.error}` };
	}

	return { ok: true, json };
};

/* 新格式是 { account, selected }；旧版是扁平的 { 组名: 成员 }，没有账号标记就照用，
   下一次保存补上标记——丢掉它等于把用户存过的手动选择静默清零 */
export function selectors() {
	const saved = readJson(SELECTOR_FILE);
	if (type(saved) != 'object')
		return {};

	if (type(saved.selected) != 'object')
		return saved;

	const account = lc(trim(creds().email ?? ''));
	return length(account) && saved.account == account ? saved.selected : {};
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

export function rememberSelectors(next) {
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
		if (+stamp > now - SPEED_WINDOW)
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

export function runCloseVia(outbound) {
	clash.closeVia(outbound);
};

export function closeViaLater(outbound) {
	if (!length(outbound))
		return;

	system(`${shellquote('/usr/libexec/ecycloud-ctl')} close-via ${shellquote(outbound)} >/dev/null 2>&1 &`);
};

export function prepare() {
	const cfg = settings();

	unlink(STOP_FILE);

	if (!panel.session().logged_in) {
		setError('尚未登录面板，请先在 LuCI 的「概览」页登录');
		return false;
	}

	setState('preparing', '正在准备内核配置');

	let cached = profile.cached();
	if (cached?.config) {
		const checked = profile.inspect(cached.config);
		if (!checked.ok)
			cached = null;
	}

	if (!cached?.config) {
		const fetched = panel.clashProfile();
		if (!fetched.ok) {
			/* 401 是面板把账号/会话拒了（账号被禁用、令牌失效），原文照搬比「拉取配置失败」有指导性 */
			setError(fetched.status == 401 ? fetched.msg : `拉取配置失败：${fetched.msg}`);
			return false;
		}
		const checked = profile.inspect(fetched.data.config);
		if (!checked.ok) {
			setError(checked.error);
			return false;
		}
		/* 缓存在结构检查过关时就落盘：校验失败（首启拉不到 geodata）时不写，
		   每次重试都要重打限流的 /config/clash */
		profile.store(fetched.data);
		cached = fetched.data;
	}

	setState('validating', profile.geodataMissing(cfg.runDir)
		? '正在校验配置：首次启动需由内核下载 GeoIP / GeoSite 数据，可能耗时数分钟'
		: '正在校验配置');

	const built = build(cached.config, cfg, clash.reserve());
	if (!built.ok) {
		setError(built.error);
		return false;
	}

	setState('starting', '正在启动内核');

	return true;
};

function applyKick(account) {
	const uci = cursor();
	uci.set('ecycloud', 'config', 'enabled', '0');
	uci.commit('ecycloud');
	const reason = account?.data?.device_kick_reason ?? 'limit';
	markKicked(reason);
	panel.ackDeviceKick();
	log('notice', reason == 'remove' ? 'kicked by device remove' : 'kicked by online device limit');
	system(`${INIT} stop >/dev/null 2>&1 &`);
};

function kickedByNotice(account) {
	return account.ok && account.data?.device_kick_notice == true &&
		account.data?.device_kick_reason != 'limit_denied';
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

export function standby() {
	setState('stopped', '');
	system(`/usr/libexec/ecycloud-ctl revert >/dev/null 2>&1 &`);
};

export function activate(config) {
	const cfg = config ?? settings();
	const applied = network.apply(cfg);

	if (!applied.ok) {
		setError(`透明代理规则未生效：${applied.error}`);
		return false;
	}

	applySelectors();
	setState('running', cfg.mode == 'tun' ? 'TUN 模式已接管转发' : 'TPROXY 模式已接管转发');
	const account = panel.refreshAccount(true, true);
	if (kickedByNotice(account))
		applyKick(account);

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

	network.revert();
	setState('stopped', '');

	return true;
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
			/* 面板可能就在这一刻判超限：那这次不算成功，并按它给的 reset_at 回写本地配额 */
			const written = panel.reportSpeedTest(name, bps);
			const denied = written.data?.denied ?? [];
			if (length(denied) && !length(written.data?.allowed ?? [])) {
				noteSpeedDenied(name, +(denied[0]?.reset_at ?? 0));
				ok = false;
			} else {
				noteSpeedSuccess(name);
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

export function update(force) {
	const cfg = settings();

	if (!panel.session().logged_in)
		return { ok: false, error: '尚未登录面板' };

	const cached = profile.cached();
	const account = panel.refreshAccount();

	if (!account.ok && !force)
		return { ok: false, error: account.msg };

	if (kickedByNotice(account)) {
		applyKick(account);
		return { ok: true, changed: false };
	}

	/* config_revision 与 /config/revision 同值，profile 已经拿过，手动刷新也用这道闸门：
	   /config/clash 是 90 秒超时、60 秒内只给 20 次的重接口，戳没变就别去打 */
	if (length(account.data?.config_revision) && account.data.config_revision == cached?.revision) {
		if (force && coreRunning())
			detachCtl('rules');
		return { ok: true, changed: false };
	}

	const fetched = panel.clashProfile();
	if (!fetched.ok)
		return { ok: false, error: fetched.msg };

	const checked = profile.inspect(fetched.data.config);
	if (!checked.ok)
		return { ok: false, error: checked.error };

	if (sprintf('%J', fetched.data.config) == sprintf('%J', cached?.config)) {
		profile.store(fetched.data);
		if (force && coreRunning())
			detachCtl('rules');
		return { ok: true, changed: false };
	}

	const previous = readJson(`${cfg.runDir}/config.json`);
	const built = build(fetched.data.config, cfg, clash.endpoint() ?? clash.reserve());
	if (!built.ok)
		return { ok: false, error: built.error };

	if (!coreRunning()) {
		profile.store(fetched.data);
		const st = state();
		if (st.stage == 'validating' || st.stage == 'preparing' || st.stage == 'starting')
			setState('stopped', '');

		return { ok: true, changed: true, reloaded: false };
	}

	const nextDns = json(built.json).dns;
	if ((previous?.dns?.enable == true && lc(previous.dns['enhanced-mode'] ?? '') == 'fake-ip') ||
		(nextDns?.enable == true && lc(nextDns['enhanced-mode'] ?? '') == 'fake-ip')) {
		profile.store(fetched.data);
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

	setState('running', '面板配置已热载');

	return { ok: true, changed: true, reloaded: true };
};

export function watchdog() {
	let active = network.applied() != null;
	let refreshed = time();
	let identityAt = 0;
	let accountAt = 0;
	let waited = 0;

	while (!stopping()) {
		if (!panel.session().logged_in) {
			const uci = cursor();
			uci.set('ecycloud', 'config', 'enabled', '0');
			uci.commit('ecycloud');
			network.revert();
			system(`${INIT} stop >/dev/null 2>&1 &`);
			break;
		}
		const cfg = settings();
		const alive = coreRunning() && clash.ready();
		const wait = (alive && active && cfg.enabled) ? 5 : 1;

		if (alive && cfg.enabled && !active) {
			active = activate(cfg);
			refreshed = time();
			identityAt = time();
			accountAt = identityAt;
			waited = 0;

			if (active && stopping()) {
				network.revert();
				break;
			}
		} else if (alive && !cfg.enabled) {
			if (active) {
				network.revert();
				active = false;
			}
			waited = 0;
			identityAt = 0;
			accountAt = 0;
			if (state().stage == 'starting' || state().stage == 'preparing' ||
				state().stage == 'validating' || state().stage == 'recovering') {
				applySelectors();
				setState('stopped', '');
			}
		} else if (!alive && active) {
			network.revert();
			active = false;
			identityAt = 0;
			accountAt = 0;
			setState('recovering', '内核未响应，已撤下透明代理规则以保证局域网可用');
			log('err', 'core unreachable, transparent proxy rules reverted');
		} else if (!alive) {
			identityAt = 0;
			accountAt = 0;
			waited += wait;
			if (waited >= 300)
				setError('内核 300 秒内未就绪，请查看「日志」页');
		}

		if (alive && active && (identityAt == 0 || time() - identityAt >= 60)) {
			panel.touchIdentity();
			identityAt = time();
		}

		if (alive && active) {
			const cached = panel.account();
			const interval = +(cached?.node_connector ?? 0) > 0 &&
				cached?.online_client_self != true ? 5 : 60;
			if (accountAt == 0 || time() - accountAt >= interval) {
				const account = panel.refreshAccount(true, true);
				accountAt = time();
				if (kickedByNotice(account))
					applyKick(account);
			}
		}

		if (alive && active && cfg.refreshInterval > 0 && time() - refreshed >= cfg.refreshInterval * 60) {
			const res = update(false);
			if (!res.ok)
				log('warning', `panel refresh failed: ${res.error}`);
			refreshed = time();
		}

		if (alive) {
			ensureDelayWorker();
			ensureSpeedWorker();
		}

		sleep(wait * 1000);
	}
};
