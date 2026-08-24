'use strict';

import { access, unlink, writefile } from 'fs';

import * as clash from 'ecycloud.clash';
import * as network from 'ecycloud.network';
import * as panel from 'ecycloud.panel';
import * as profile from 'ecycloud.profile';

import { STATE_DIR, coreRunning, ensurePrivateDir, log, setError, setState,
         settings } from 'ecycloud.common';

/* procd 先跑 stop_service 再杀实例，看门狗因此可能在撤规则之后又把规则铺回去 */
const STOP_FILE = `${STATE_DIR}/stopping`;

function stopping() {
	return access(STOP_FILE);
}

function build(remote, cfg, api) {
	const assembled = profile.assemble(remote, cfg, api);
	if (!assembled.ok)
		return assembled;

	const written = profile.write(cfg.runDir, assembled.config);
	if (!written.ok)
		return written;

	setState('validating', profile.geodataMissing(cfg.runDir)
		? '正在校验配置：首次启动需由内核下载 GeoIP / GeoSite 数据，可能耗时数分钟'
		: '正在校验配置');

	const valid = profile.validate(cfg.runDir);
	if (!valid.ok) {
		profile.rollback(cfg.runDir);
		return valid;
	}

	return { ok: true, json: sprintf('%J', assembled.config) };
}

export function prepare() {
	const cfg = settings();

	unlink(STOP_FILE);

	if (!panel.session().logged_in) {
		setError('尚未登录面板，请先在 LuCI 的「概览」页登录');
		return false;
	}

	setState('preparing', '正在准备内核配置');

	let cached = profile.cached();

	if (!cached?.config) {
		const fetched = panel.clashProfile();
		if (!fetched.ok) {
			setError(`拉取配置失败：${fetched.msg}`);
			return false;
		}
		profile.store(fetched.data);
		cached = profile.cached();
	}

	const built = build(cached.config, cfg, clash.reserve());
	if (!built.ok) {
		setError(`配置未通过内核校验：${built.error}`);
		return false;
	}

	setState('starting', '正在启动内核');

	return true;
}

export function activate(config) {
	const cfg = config ?? settings();
	const applied = network.apply(cfg);

	if (!applied.ok) {
		setError(`透明代理规则未生效：${applied.error}`);
		return false;
	}

	panel.refreshAccount();
	setState('running', cfg.mode == 'tun' ? 'TUN 模式已接管转发' : 'TPROXY 模式已接管转发');

	return true;
}

export function cleanup() {
	ensurePrivateDir(STATE_DIR);
	writefile(STOP_FILE, '');

	network.revert();
	clash.release();
	setState('stopped', '');

	return true;
}

export function update(force) {
	const cfg = settings();

	if (!panel.session().logged_in)
		return { ok: false, error: '尚未登录面板' };

	const cached = profile.cached();
	const account = panel.refreshAccount();

	if (!account.ok && !force)
		return { ok: false, error: account.msg };

	if (!force && length(account.data?.config_revision) && account.data.config_revision == cached?.revision)
		return { ok: true, changed: false };

	const fetched = panel.clashProfile();
	if (!fetched.ok)
		return { ok: false, error: fetched.msg };

	if (!force && length(fetched.data.revision) && fetched.data.revision == cached?.revision)
		return { ok: true, changed: false };

	profile.store(fetched.data);

	const built = build(fetched.data.config, cfg, clash.endpoint() ?? clash.reserve());
	if (!built.ok)
		return { ok: false, error: built.error };

	if (!coreRunning())
		return { ok: true, changed: true, reloaded: false };

	const reloaded = clash.applyPayload(built.json);
	if (!reloaded.ok)
		return { ok: false, error: reloaded.error };

	setState('running', '面板配置已热载');

	return { ok: true, changed: true, reloaded: true };
}

export function watchdog() {
	const cfg = settings();
	let active = network.applied() != null;
	let refreshed = time();
	let waited = 0;

	while (!stopping()) {
		const alive = coreRunning() && clash.ready();

		if (alive && !active) {
			active = activate(cfg);
			refreshed = time();
			waited = 0;

			if (active && stopping()) {
				network.revert();
				break;
			}
		} else if (!alive && active) {
			network.revert();
			active = false;
			setState('recovering', '内核未响应，已撤下透明代理规则以保证局域网可用');
			log('err', 'core unreachable, transparent proxy rules reverted');
		} else if (!alive) {
			waited += 5;
			if (waited == 300)
				setError('内核 300 秒内未就绪，请查看「日志」页');
		}

		if (alive && active && cfg.refreshInterval > 0 && time() - refreshed >= cfg.refreshInterval * 60) {
			const res = update(false);
			if (!res.ok)
				log('warning', `panel refresh failed: ${res.error}`);
			refreshed = time();
		}

		sleep(5000);
	}
}
