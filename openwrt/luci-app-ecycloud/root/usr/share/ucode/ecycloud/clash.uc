'use strict';

import { unlink } from 'fs';

import { API_FILE, CONTROLLER_PORT, freePort, httpRequest, randomHex, readJson,
         urlencode, writePrivateJson } from 'ecycloud.common';

/* unified-delay 下内核连打两次 HEAD 并从第二次计时，明文 HTTP 会被内核警告劫持，用 https */
const DELAY_URL = 'https://cp.cloudflare.com/generate_204';

export function endpoint() {
	return readJson(API_FILE);
}

export function reserve() {
	const api = { port: freePort(CONTROLLER_PORT), secret: randomHex(16) };
	writePrivateJson(API_FILE, api);
	return api;
}

export function release() {
	unlink(API_FILE);
}

function request(path, opts) {
	const api = endpoint();
	if (!api)
		return { ok: false, status: 0, data: null, error: '内核控制面未就绪' };

	const body = opts?.body != null ? sprintf('%J', opts.body) : null;
	const headers = [ 'Accept: application/json', `Authorization: Bearer ${api.secret}` ];

	if (body != null)
		push(headers, 'Content-Type: application/json');

	const res = httpRequest({
		url: `http://127.0.0.1:${api.port}${path}`,
		method: opts?.method,
		headers,
		body,
		timeout: opts?.timeout ?? 10,
		connectTimeout: 3
	});

	const ok = res.status >= 200 && res.status < 300;

	return {
		ok,
		status: res.status,
		data: res.data,
		error: ok ? null : (res.data?.message ?? res.error ?? `控制面返回 HTTP ${res.status}`)
	};
}

export function version() {
	return request('/version', { timeout: 3 });
}

export function ready() {
	return version().ok;
}

export function proxies() {
	return request('/proxies');
}

export function connections() {
	return request('/connections');
}

export function select(group, member) {
	return request(`/proxies/${urlencode(group)}`, { method: 'PUT', body: { name: member } });
}

export function delay(name, timeout) {
	const ms = timeout ?? 5000;
	return request(`/proxies/${urlencode(name)}/delay?url=${urlencode(DELAY_URL)}&timeout=${ms}`,
		{ timeout: (ms / 1000) + 3 });
}

export function reselect(group) {
	return request(`/group/${urlencode(group)}/delay?url=${urlencode(DELAY_URL)}&timeout=5000`,
		{ timeout: 20 });
}

export function setMode(mode) {
	return request('/configs', { method: 'PATCH', body: { mode } });
}

/* PUT /proxies 只改选中项，存量连接仍走旧出站；按 chains 逐条断，勿全量 DELETE /connections */
export function closeVia(outbound) {
	const snapshot = connections();
	if (!snapshot.ok || type(snapshot.data?.connections) != 'array')
		return 0;

	let closed = 0;

	for (let conn in snapshot.data.connections) {
		if (!(outbound in (conn.chains ?? [])))
			continue;
		request(`/connections/${urlencode(conn.id)}`, { method: 'DELETE', timeout: 5 });
		closed++;
	}

	return closed;
}

export function applyPayload(configJson) {
	return request('/configs?force=true', { method: 'PUT', body: { payload: configJson }, timeout: 120 });
}
