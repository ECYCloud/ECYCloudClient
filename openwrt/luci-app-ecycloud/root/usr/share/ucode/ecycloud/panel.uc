'use strict';

import { unlink } from 'fs';

import { ACCOUNT_FILE, creds, device, httpRequest, origins, readJson, saveCreds,
         saveOrigins, urlencode, userAgent, writeJson } from 'ecycloud.common';

const API_PATH = '/api/client/v1';

export function session() {
	const saved = creds();
	return {
		email: saved.email ?? '',
		expires_at: saved.expires_at ?? '',
		logged_in: length(saved.token) > 0
	};
}

export function clearToken() {
	saveCreds({ device_id: creds().device_id });
	unlink(ACCOUNT_FILE);
}

function headers(token, hasBody) {
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

	return list;
}

export function call(path, opts) {
	const origin = opts?.origin ?? origins().site;
	if (!length(origin))
		return { ok: false, ret: 0, status: 0, msg: '面板地址缺失，请重装插件或在设置里填写', data: null };

	const token = opts?.anonymous ? '' : creds().token;
	if (!opts?.anonymous && !length(token))
		return { ok: false, ret: 0, status: 401, msg: '尚未登录', data: null };

	const body = opts?.body != null ? sprintf('%J', opts.body) : null;
	const res = httpRequest({
		url: `${origin}${API_PATH}${path}`,
		method: opts?.method,
		headers: headers(token, body != null),
		body,
		timeout: opts?.timeout
	});

	const payload = res.data;
	const ret = +(payload?.ret ?? 0);

	if (res.status == 401 && ret != 2 && !opts?.anonymous)
		clearToken();

	if (ret != 1)
		return {
			ok: false,
			ret,
			status: res.status,
			msg: payload?.msg ?? res.error ?? `面板返回 HTTP ${res.status}`,
			data: payload?.data
		};

	return { ok: true, ret, status: res.status, msg: payload?.msg ?? '', data: payload?.data ?? {} };
}

export function login(email, password, code) {
	const info = device();
	const body = { email, passwd: password, ...info };

	if (length(code))
		body.code = code;

	const res = call('/auth/login', { anonymous: true, method: 'POST', body });

	if (!res.ok)
		return { ...res, need_code: res.ret == 2 };

	saveCreds({
		device_id: info.device_id,
		email,
		token: res.data.token,
		expires_at: res.data.expires_at ?? ''
	});

	if (res.data.user)
		writeJson(ACCOUNT_FILE, res.data.user);

	return { ok: true, msg: res.msg };
}

export function logout() {
	const res = call('/auth/logout', { method: 'POST', timeout: 8 });
	clearToken();
	return res;
}

export function account() {
	return readJson(ACCOUNT_FILE);
}

export function refreshAccount() {
	const res = call('/user/profile');
	if (!res.ok)
		return res;

	writeJson(ACCOUNT_FILE, res.data);
	saveOrigins(res.data.site_origin, res.data.api_origin);

	return res;
}

export function clashProfile() {
	return call('/config/clash', { origin: origins().sub, timeout: 90 });
}
