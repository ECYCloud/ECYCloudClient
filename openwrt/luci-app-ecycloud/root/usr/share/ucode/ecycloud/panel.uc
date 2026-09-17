'use strict';

import { open, unlink } from 'fs';

import { ACCOUNT_FILE, ANNOUNCE_CACHE, ANNOUNCE_FILE, CONF_DIR, creds, device,
         ensurePrivateDir, httpRequest, log, origins, readJson, saveCreds, saveOrigins,
         STATE_DIR, urlencode, userAgent, writeJson, writePrivateJson } from 'ecycloud.common';

const API_PATH = '/api/client/v1';

/* 面板按路径滑动窗口限流，窗口 60 秒（Website 的 ClientApiRateLimit）：撞上就整窗退避，别连打 */
const RATE_WINDOW = 60;
const COOLDOWN_FILE = `${STATE_DIR}/cooldown.json`;

function routeKey(path) {
	return split(`${path}`, '?')[0];
};

function cooldownLeft(path) {
	const until = +(readJson(COOLDOWN_FILE)?.[routeKey(path)] ?? 0);
	return until > time() ? until - time() : 0;
};

function noteCooldown(path) {
	const saved = readJson(COOLDOWN_FILE) ?? {};
	saved[routeKey(path)] = time() + RATE_WINDOW;
	ensurePrivateDir(STATE_DIR);
	writeJson(COOLDOWN_FILE, saved);
};

export function session() {
	const saved = creds();
	if (!length(saved.token))
		return { email: '', expires_at: '', logged_in: false };

	return {
		email: saved.email ?? '',
		expires_at: saved.expires_at ?? '',
		logged_in: true,
		device_id: saved.device_id ?? ''
	};
};

export function clearToken() {
	log('notice', 'session cleared');
	saveCreds({ device_id: creds().device_id });
	unlink(ACCOUNT_FILE);
	unlink(COOLDOWN_FILE);
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

	const token = opts?.anonymous ? '' : creds().token;
	if (!opts?.anonymous && !length(token))
		return { ok: false, ret: 0, status: 401, msg: '尚未登录', data: null };

	const waiting = cooldownLeft(path);
	if (waiting > 0)
		return { ok: false, ret: 0, status: 429, msg: `面板繁忙，请约 ${waiting} 秒后再试`, data: null };

	const body = opts?.body != null ? sprintf('%J', opts.body) : null;
	const res = httpRequest({
		url: `${origin}${API_PATH}${path}`,
		method: opts?.method,
		headers: headers(token, body != null, opts?.connected == true, opts?.node_used == true),
		body,
		timeout: opts?.timeout
	});

	const payload = res.data;
	const ret = +(payload?.ret ?? 0);

	if (res.status == 429)
		noteCooldown(path);

	if (res.status == 401 && ret != 2 && !opts?.anonymous && creds().token == token &&
	    payload?.msg == '登录已失效，请重新登录') {
		log('notice', `session cleared: ${path} HTTP 401`);
		clearToken();
	}

	if (ret != 1)
		return {
			ok: false,
			ret,
			status: res.status,
			msg: payload?.msg ?? res.error ?? `面板返回 HTTP ${res.status}`,
			data: payload?.data
		};

	return { ok: true, ret, status: res.status, msg: payload?.msg ?? '', data: payload?.data ?? {} };
};

function storeSession(email, data, deviceId) {
	saveCreds({
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

	storeSession(email, res.data, info.device_id);
	if (!length(creds().token))
		return { ok: false, msg: '登录成功但未能保存会话' };

	return { ok: true, msg: res.msg };
};

export function logout() {
	const res = call('/auth/logout', { method: 'POST', timeout: 8 });
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

export function refreshAccount(connected, nodeUsed) {
	while (true) {
		const revision = writeAccount();
		const res = call('/user/profile', { connected: connected == true, node_used: nodeUsed == true });
		if (!res.ok)
			return res;

		if (!writeAccount((current) => current == revision ? res.data : null))
			continue;
		saveOrigins(res.data.site_origin, res.data.api_origin);

		return res;
	}
};

export function clashProfile() {
	return call('/config/clash', { origin: origins().sub, timeout: 90 });
};

export function touchIdentity() {
	return call('/config/revision', { origin: origins().sub, timeout: 8, connected: true });
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

export function devices(page, length) {
	page = page > 0 ? +page : 1;
	length = +length;
	if (length != 10 && length != 25 && length != 50 && length != 100)
		length = 100;
	const res = call(`/user/devices?page=${page}&length=${length}`);
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

function announceCache() {
	return readJson(ANNOUNCE_CACHE);
};

export function announcements(path) {
	const action = `${path ?? ''}`;
	let state = readJson(ANNOUNCE_FILE) ?? {};
	const cache = announceCache();
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

	const res = call('/announcements');
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
	writeJson(ANNOUNCE_CACHE, { items, popup });

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
