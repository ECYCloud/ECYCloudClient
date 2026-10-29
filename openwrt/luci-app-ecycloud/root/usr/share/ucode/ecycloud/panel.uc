'use strict';

import { access, open, unlink } from 'fs';

import { ACCOUNT_FILE, ANNOUNCE_CACHE, ANNOUNCE_FILE, CONF_DIR, PROFILE_FILE, creds, device,
		 ensurePrivateDir, httpRequest, log, origins, panelDirectHosts, randomHex, readJson, saveCreds, saveOrigins,
		 STATE_DIR, coreRunning, sessionBinding, sessionValid, settings, urlencode, userAgent, writeJson, writePrivateJson } from 'ecycloud.common';
import { PENDING_FILE, cached } from 'ecycloud.profile';

const API_PATH = '/api/client/v1';

const RATE_WINDOW = 60;
const COOLDOWN_FILE = `${STATE_DIR}/cooldown.json`;
const NODE_USED_FILE = `${STATE_DIR}/node-used.json`;

function routeKey(path) {
	return split(`${path}`, '?')[0];
};

function cooldownLeft(path) {
	const until = +(readJson(COOLDOWN_FILE)?.[routeKey(path)] ?? 0);
	return until > time() ? until - time() : 0;
};

function noteCooldown(path, retryAfter) {
	const saved = readJson(COOLDOWN_FILE) ?? {};
	const limit = path in [ '/config/clash', '/config/revision' ] && cached() != null ? 86400 : RATE_WINDOW;
	saved[routeKey(path)] = time() + min(limit, max(1, retryAfter ?? 6));
	ensurePrivateDir(STATE_DIR);
	writeJson(COOLDOWN_FILE, saved);
};

export function session() {
	const saved = creds();
	if (!sessionValid())
		return { email: '', expires_at: '', logged_in: false, expired: length(saved.token) > 0 };

	return {
		id: saved.session_id ?? `legacy:${saved.email ?? ''}:${saved.expires_at ?? ''}`,
		email: saved.email ?? '',
		expires_at: saved.expires_at ?? '',
		logged_in: true,
		device_id: saved.device_id ?? ''
	};
};

export function clearCache() {
	for (let path in [ ACCOUNT_FILE, COOLDOWN_FILE, ANNOUNCE_CACHE, PROFILE_FILE, PENDING_FILE, NODE_USED_FILE ])
		if (access(path) && !unlink(path))
			die('无法清除旧账户缓存');
};

export function clearToken() {
	log('notice', 'session cleared');
	if (!saveCreds({ device_id: creds().device_id }))
		die('无法清除旧账户凭据');
	clearCache();
};

function headers(token, hasBody, connected, nodeUsed) {
	const info = device();
	const list = [
		'Accept: application/json',
		`User-Agent: ${userAgent()}`,
		`X-Device-Model: ${urlencode(info.device_model)}`,
		`X-Device-OS: ${urlencode(info.os_version)}`,
		`X-App-Version: ${urlencode(info.app_version)}`
	];

	if (hasBody)
		push(list, 'Content-Type: application/json; charset=utf-8');

	if (length(token))
		push(list, `Authorization: Bearer ${token}`);

	if (connected)
		push(list, 'X-ECY-Connected: 1');

	if (nodeUsed)
		push(list, 'X-ECY-Node-Used: 1');

	return list;
};

export function call(path, opts) {
	const origin = opts?.origin ?? origins().site;
	if (!length(origin))
		return { ok: false, ret: 0, status: 0, msg: '面板地址缺失，请重装插件或在设置里填写', data: null };

	const sessionToken = creds().token ?? '';
	const token = opts?.anonymous ? '' : sessionToken;
	if (!opts?.anonymous && !sessionValid())
		return { ok: false, ret: 0, status: 401, msg: length(token) ? '登录已失效，请重新登录' : '尚未登录', data: null };

	const waiting = cooldownLeft(path);
	if (waiting > 0)
		return { ok: false, ret: 0, status: 429, msg: `面板繁忙，请约 ${waiting} 秒后再试`, data: null };

	const body = opts?.body != null ? sprintf('%J', opts.body) : null;
	const pending = !opts?.anonymous ? readJson(NODE_USED_FILE) : null;
	const nodeUsed = pending?.binding == sessionBinding();
	const direct = panelDirectHosts(true)[origin];
	const addresses = direct?.addresses ?? [];
	const address = filter(addresses, ip => index(ip, ':') < 0)[0] ?? addresses[0];
	const request = {
		url: `${origin}${API_PATH}${path}`,
		direct: true,
		resolve: length(address) && direct.host != address && direct.host != `[${address}]`
			? `${direct.host}:${direct.port}:${index(address, ':') >= 0 ? `[${address}]` : address}` : null,
		method: opts?.method,
		headers: [ ...headers(token, body != null, opts?.connected == true,
			opts?.connected == true || opts?.node_used == true || nodeUsed), ...(opts?.headers ?? []) ],
		body,
		timeout: opts?.timeout
	};
	let res = httpRequest(request);
	const repeatable = (opts?.method ?? 'GET') in [ 'GET', 'HEAD' ];
	if (res.status == 0 && coreRunning() && (opts?.anonymous || sessionValid()) && (creds().token ?? '') == sessionToken &&
	    (repeatable || res.exit_code in [ 5, 6, 7 ]))
		res = httpRequest({ ...request, proxy: `http://127.0.0.1:${settings().mixedPort}` });

	if ((creds().token ?? '') != sessionToken)
		return { ok: false, ret: 0, status: 409, msg: '账户会话已改变，请重新操作', data: null };
	if (!opts?.anonymous && !sessionValid())
		return { ok: false, ret: 0, status: 401, msg: '登录已失效，请重新登录', data: null };

	const payload = res.data;
	const ret = +(payload?.ret ?? 0);

	if (res.status == 429)
		noteCooldown(path, res.retry_after);

	if (res.status == 401 && ret != 2 && !opts?.anonymous && creds().token == token) {
		log('notice', `session cleared: ${path} HTTP 401`);
		clearToken();
	}

	if (ret != 1 || res.status < 200 || res.status >= 300)
		return {
			ok: false,
			ret,
			status: res.status,
			msg: payload?.msg ?? res.error ?? `面板返回 HTTP ${res.status}`,
			data: payload?.data
		};

	if (nodeUsed && pending.id == readJson(NODE_USED_FILE)?.id)
		unlink(NODE_USED_FILE);
	return { ok: true, ret, status: res.status, msg: payload?.msg ?? '', data: payload?.data ?? {} };
};

/* 面板对封禁（enable=0）与待删除（enable=-1）账号同样签发 token，只放行状态、资料与工单接口，
   /config/clash 会被拒；路由端没有账户状态页，存下这种会话只会让拉配置反复失败 */
export function restrictedReason(data) {
	const status = data?.account_status;
	if (type(status) != 'object')
		return '';

	const enable = +(status.enable ?? 1);
	if (enable == 1)
		return '';
	if (enable == -1)
		return '账号正在等待删除，请先到网站取消删除再登录';

	const reason = trim(`${status.ban_reason ?? ''}`);
	return length(reason) ? `账号已被封禁：${reason}` : '账号已被封禁，请到网站查看详情';
};

function storeSession(email, data, deviceId) {
	saveCreds({
		session_id: randomHex(16),
		device_id: deviceId,
		email,
		token: data.token,
		expires_at: data.expires_at ?? ''
	});

	if (data.user)
		writeJson(ACCOUNT_FILE, data.user);

	log('notice', length(creds().token) ? 'session stored' : 'session store failed');
};

export function login(email, password, code) {
	const info = device();
	const body = { email, passwd: password, ...info };

	if (length(code))
		body.code = code;

	const res = call('/auth/login', { anonymous: true, method: 'POST', body });

	if (!res.ok)
		return { ...res, need_code: res.ret == 2 };

	if (!length(res.data?.token))
		return { ok: false, msg: '面板未返回登录令牌' };

	const restricted = restrictedReason(res.data);
	if (length(restricted))
		return { ok: false, msg: restricted };

	storeSession(email, res.data, info.device_id);
	if (!length(creds().token))
		return { ok: false, msg: '登录成功但未能保存会话' };

	return { ok: true, msg: res.msg };
};

export function sendLoginVerify(email) {
	return call('/auth/send-login-verify', {
		anonymous: true,
		method: 'POST',
		body: { email }
	});
};

export function loginWithVerifyCode(email, code) {
	const info = device();
	const res = call('/auth/login-with-verify-code', {
		anonymous: true,
		method: 'POST',
		body: { email, code, ...info }
	});

	if (!res.ok)
		return res;

	if (!length(res.data?.token))
		return { ok: false, msg: '面板未返回登录令牌' };

	const restricted = restrictedReason(res.data);
	if (length(restricted))
		return { ok: false, msg: restricted };

	storeSession(email, res.data, info.device_id);
	if (!length(creds().token))
		return { ok: false, msg: '登录成功但未能保存会话' };

	return { ok: true, msg: res.msg };
};

export function logout() {
	const token = creds().token ?? '';
	const res = call('/auth/logout', { method: 'POST', timeout: 8 });
	if ((creds().token ?? '') == token)
		clearToken();
	return res;
};

export function account() {
	return readJson(ACCOUNT_FILE);
};

function writeAccount(update) {
	ensurePrivateDir(STATE_DIR);
	const path = ACCOUNT_FILE + '.lock';
	const lock = open(path, 'a', 0600);
	if (!lock)
		die('无法打开账户缓存锁');
	if (!lock.lock('x')) {
		lock.close();
		die('无法锁定账户缓存');
	}

	let result;
	try {
		const revision = +(readJson(path) ?? 0);
		result = revision;
		if (update) {
			const data = update(revision);
			result = data != null;
			if (result && (!writeJson(ACCOUNT_FILE, data) || !writeJson(path, revision + 1)))
				die('无法保存账户缓存');
		}
	} catch (e) {
		lock.close();
		die(e.message);
	}
	lock.close();
	return result;
};

export function reportNodeUsed() {
	if (!sessionValid())
		return call('/user/account-status');
	ensurePrivateDir(STATE_DIR);
	if (!writePrivateJson(NODE_USED_FILE, { binding: sessionBinding(), id: randomHex(6) }))
		die('无法保存节点使用记录');
	return call('/user/account-status', { node_used: true });
};

export function reserveSpeedTest(names) {
	return call('/user/speed-test', {
		method: 'POST',
		body: { proxy_names: names },
		timeout: 20
	});
};

export function reportSpeedTest(name, bytesPerSecond) {
	return call('/user/speed-test', {
		method: 'POST',
		body: {
			results: [ { proxy_name: name, bytes_per_second: +bytesPerSecond } ]
		},
		timeout: 20
	});
};

export function checkin() {
	const res = call('/user/checkin', { method: 'POST', body: {} });
	if (!res.ok || type(res.data) != 'object')
		return res;

	writeAccount(() => res.data);
	saveOrigins(res.data.site_origin, res.data.api_origin);
	return res;
};

export function contentLanguage(locale) {
	const language = locale in [ 'zh-CN', 'zh-TW', 'en-US', 'en' ] ? locale : (cached()?.locale ?? 'zh-CN');
	return language == 'en' ? 'en-US' : language;
};

export function refreshAccount(connected, nodeUsed, locale) {
	const headers = [ `Accept-Language: ${contentLanguage(locale)}` ];
	const status = call('/user/account-status', { connected: connected == true, node_used: nodeUsed == true, headers });
	if (!status.ok)
		return status;
	const reason = restrictedReason({ account_status: status.data });
	if (length(reason))
		return { ok: false, status: 403, restricted: true, msg: reason, data: null };
	while (true) {
		const revision = writeAccount();
		const res = call('/user/profile', { connected: connected == true, node_used: nodeUsed == true, headers });
		if (!res.ok)
			return res;

		if (!writeAccount((current) => current == revision ? res.data : null))
			continue;
		saveOrigins(res.data.site_origin, res.data.api_origin);

		return res;
	}
};

export function clashProfile(locale) {
	return call('/config/clash', { origin: origins().sub, timeout: 90, headers: [ 'X-ECY-Node-Providers: 1', `Accept-Language: ${contentLanguage(locale)}` ] });
};

export function touchIdentity(connected) {
	return call('/config/revision', { origin: origins().sub, timeout: 8, connected: connected == true, headers: [ `Accept-Language: ${contentLanguage()}` ] });
};

export function onlineDevices() {
	const res = call('/user/online-devices');
	const devices = [];

	if (res.ok && type(res.data) == 'array') {
		for (let item in res.data)
			push(devices, {
				ip: item.ip ?? '',
				device_id: item.device_id ?? '',
				device: item.device ?? '',
				location: item.location ?? '',
				datetime: item.datetime ?? ''
			});
	}

	return { ok: res.ok == true, msg: res.msg ?? '', devices };
};

export function devices(page, length, search) {
	page = page > 0 ? +page : 1;
	length = +length;
	if (length != 10 && length != 25 && length != 50 && length != 100)
		length = 100;
	const res = call(`/user/devices?page=${page}&length=${length}&search=${urlencode(substr(trim(`${search ?? ''}`), 0, 256))}`);
	const items = [];
	const data = res.data ?? {};

	if (res.ok && type(data.items) == 'array') {
		for (let item in data.items)
			push(items, {
				ip: item.ip ?? '',
				device: item.device ?? '',
				device_id: item.device_id ?? '',
				location: item.location ?? '',
				datetime: item.datetime ?? '',
				app_version: item.app_version ?? '',
				online: item.online == true
			});
	}

	return {
		ok: res.ok == true,
		msg: res.msg ?? '',
		items,
		log_keep_days: +(data.log_keep_days ?? 1),
		current_page: +(data.current_page ?? 1),
		last_page: +(data.last_page ?? 1),
		total: +(data.total ?? 0),
		per_page: +(data.per_page ?? length)
	};
};

function clearDeviceKickNotice() {
	writeAccount(() => {
		const acct = account();
		if (acct) {
			acct.device_kick_notice = false;
			acct.device_kick_reason = '';
		}
		return acct;
	});
};

export function reclaimDeviceSlot(targetDeviceId) {
	const res = call('/user/device-reclaim', {
		method: 'POST',
		body: { target_device_id: targetDeviceId ?? '' }
	});
	if (res.ok)
		clearDeviceKickNotice();
	return res;
};

export function ackDeviceKick() {
	const res = call('/user/device-kick-ack', { method: 'POST', body: {} });
	if (res.ok)
		clearDeviceKickNotice();
	return res;
};

export function kickDevice(deviceId) {
	return call('/user/kick-device', {
		method: 'POST',
		body: { device_id: deviceId }
	});
};

function announceItem(raw) {
	return {
		id: +(raw.id ?? 0),
		title: raw.title ?? '',
		date: raw.date ?? '',
		updated_at: raw.updated_at ?? raw.date ?? '',
		content: raw.content ?? ''
	};
};

function announceRevised(item) {
	return length(item.updated_at) ? item.updated_at : item.date;
};

function announceSeen(state) {
	return type(state.seen_revisions) == 'object' ? state.seen_revisions : {};
};

function announceUnreadIndex(items, seen) {
	let best = -1;
	let bestAt = '';

	for (let i = 0; i < length(items); i++) {
		const item = items[i];
		if (item.id == 1 || seen[`${item.id}`] == item.updated_at)
			continue;
		const at = announceRevised(item);
		if (best < 0 || (length(at) && at > bestAt)) {
			best = i;
			bestAt = at;
		}
	}

	return best;
};

function announceLatestIndex(items) {
	if (!length(items))
		return 0;

	let best = 0;
	let bestAt = '';

	for (let i = 0; i < length(items); i++) {
		if (items[i].id == 1 && length(items) > 1)
			continue;
		const at = announceRevised(items[i]);
		if (length(at) && at > bestAt) {
			best = i;
			bestAt = at;
		}
	}

	return best;
};

function announcePending(popup, state) {
	if (!popup)
		return null;
	if (+(state.dismissed_popup_id ?? 0) != popup.id)
		return popup;
	if ((state.dismissed_popup_updated_at ?? '') != popup.updated_at)
		return popup;
	return null;
};

function saveAnnounceState(state) {
	const next = { seen_revisions: announceSeen(state) };

	if (state.dismissed_popup_id != null) {
		next.dismissed_popup_id = +state.dismissed_popup_id;
		next.dismissed_popup_updated_at = state.dismissed_popup_updated_at ?? '';
	}

	ensurePrivateDir(CONF_DIR);
	return writePrivateJson(ANNOUNCE_FILE, next);
};

function announceView(items, popup, state, extra) {
	const unread = announceUnreadIndex(items, announceSeen(state));

	return {
		ok: extra.ok != false,
		loaded: extra.loaded == true,
		items,
		popup,
		pending_popup: announcePending(popup, state),
		has_unread: unread >= 0,
		open_index: unread >= 0 ? unread : announceLatestIndex(items),
		error: extra.error ?? '',
		msg: extra.msg ?? ''
	};
};

function announceCache(locale) {
	const cached = readJson(ANNOUNCE_CACHE);
	return (cached?.locale ?? 'zh-CN') == locale ? cached : null;
};

export function announcements(path, locale) {
	let language = locale == null || locale == '' ? 'zh-CN' : locale;
	if (!(language in [ 'zh-CN', 'zh-TW', 'en-US', 'en' ]))
		return { ok: false, msg: '语言不合法' };
	language = contentLanguage(language);
	const action = `${path ?? ''}`;
	let state = readJson(ANNOUNCE_FILE) ?? {};
	const cache = announceCache(language);
	const cachedItems = cache?.items ?? [];
	const cachedPopup = cache?.popup ?? null;

	if (action == 'seen' || action == 'popup' || match(action, /^seen:/)) {
		if (action == 'seen') {
			if (!length(cachedItems))
				return announceView(cachedItems, cachedPopup, state, {
					ok: true,
					loaded: cache != null
				});

			const seen = {};
			for (let item in cachedItems)
				seen[`${item.id}`] = item.updated_at;
			state.seen_revisions = seen;
		} else if (action == 'popup') {
			if (cachedPopup) {
				state.dismissed_popup_id = cachedPopup.id;
				state.dismissed_popup_updated_at = cachedPopup.updated_at;
			}
		} else {
			const id = +substr(action, 5);
			const seen = announceSeen(state);
			for (let item in cachedItems)
				if (item.id == id)
					seen[`${item.id}`] = item.updated_at;
			state.seen_revisions = seen;
		}

		saveAnnounceState(state);
		return announceView(cachedItems, cachedPopup, state, { ok: true, loaded: true });
	}

	/* 点铃铛只读缓存；60 秒轮询传 refresh 才打面板。每次都 curl 会卡 1～2 秒。 */
	if (action != 'refresh' && cache != null)
		return announceView(cachedItems, cachedPopup, state, { ok: true, loaded: true });

	const res = call('/announcements', { headers: [ `Accept-Language: ${language}` ] });
	if (res.status == 429)
		return announceView(cachedItems, cachedPopup, state, {
			ok: true,
			loaded: cache != null
		});

	if (!res.ok)
		return announceView(cachedItems, cachedPopup, state, {
			ok: false,
			loaded: cache != null,
			error: res.msg ?? '',
			msg: res.msg ?? ''
		});

	const items = [];
	if (type(res.data?.announcements) == 'array') {
		for (let raw in res.data.announcements)
			push(items, announceItem(raw));
	}

	const popup = res.data?.popup ? announceItem(res.data.popup) : null;
	ensurePrivateDir(STATE_DIR);
	writeJson(ANNOUNCE_CACHE, { locale: language, items, popup });

	if (type(state.seen_revisions) != 'object') {
		const maxId = +(state.read_max_id ?? 0);
		if (maxId > 0) {
			const seen = {};
			for (let item in items)
				if (item.id <= maxId)
					seen[`${item.id}`] = item.updated_at;
			state.seen_revisions = seen;
			saveAnnounceState(state);
		}
	}

	if (state.dismissed_popup_id != null && state.dismissed_popup_updated_at == null) {
		for (let item in items) {
			if (item.id == +state.dismissed_popup_id) {
				state.dismissed_popup_updated_at = item.updated_at;
				saveAnnounceState(state);
				break;
			}
		}
	}

	return announceView(items, popup, state, { ok: true, loaded: true });
};
