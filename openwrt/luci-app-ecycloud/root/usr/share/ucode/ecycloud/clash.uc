'use strict';

import { popen, readfile, unlink, writefile } from 'fs';

import { API_FILE, CONTROLLER_PORT, STATE_DIR, ensurePrivateDir, freePort, httpRequest,
         instances, randomHex, readJson, settings, shellquote, urlencode,
         writePrivateJson } from 'ecycloud.common';
import { SPEED_GROUP, speedPort } from 'ecycloud.profile';

/* unified-delay 下内核连打两次 HEAD 并从第二次计时，明文 HTTP 会被内核警告劫持，用 https */
const DELAY_URL = 'https://cp.cloudflare.com/generate_204';

export function endpoint() {
	return readJson(API_FILE);
};

export function reserve() {
	const prev = readJson(API_FILE);
	if (prev?.port && length(prev.secret) && freePort(prev.port) == prev.port)
		return prev;

	const api = { port: freePort(CONTROLLER_PORT), secret: randomHex(16) };
	writePrivateJson(API_FILE, api);
	return api;
};

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
};

export function version() {
	return request('/version', { timeout: 3 });
};

export function ready() {
	return version().ok;
};

export function proxies() {
	return request('/proxies');
};

export function proxy(name) {
	return request(`/proxies/${urlencode(name)}`);
};

export function connections() {
	return request('/connections');
};

/* inuse 是进程 RSS；/memory 流首帧故意为 0 且至少等 1s，rpcd 不能堵。Linux 上读 core 的 VmRSS */
export function memoryUsage() {
	const pid = +(instances()?.core?.pid ?? 0);
	if (pid <= 0)
		return 0;

	const m = match(readfile(`/proc/${pid}/status`) ?? '', /VmRSS:\s+(\d+)\s+kB/);
	return m ? +m[1] * 1024 : 0;
};

export function select(group, member) {
	return request(`/proxies/${urlencode(group)}`, { method: 'PUT', body: { name: member } });
};

/* httpRequest 一次 popen 一个 curl，天生串行；整组测延迟要并发只能另起这个批量原语。
   成败只看内核返回体里的 delay，不必再取状态码：失败时返回的是 { message } */
export function delayBatch(names, timeout) {
	const api = endpoint();
	const out = {};
	if (!api || !length(names))
		return out;

	ensurePrivateDir(STATE_DIR);
	const ms = timeout ?? 5000;
	const dir = `${STATE_DIR}/dly-${randomHex(6)}`;
	system(`mkdir -p ${shellquote(dir)}`);

	const order = [];
	for (let name in names) {
		const idx = length(order);
		push(order, name);
		writefile(`${dir}/${idx}.conf`, join('\n', [
			'silent',
			`url = "http://127.0.0.1:${api.port}/proxies/${urlencode(name)}/delay?url=${urlencode(DELAY_URL)}&timeout=${ms}"`,
			'header = "Accept: application/json"',
			`header = "Authorization: Bearer ${api.secret}"`,
			`max-time = ${int(ms / 1000) + 3}`,
			'connect-timeout = 3',
			`output = "${dir}/${idx}.json"`
		]) + '\n');
	}

	system(`cd ${shellquote(dir)} && for f in *.conf; do curl -K "$f" & done; wait`);

	for (let idx = 0; idx < length(order); idx++)
		out[order[idx]] = +(readJson(`${dir}/${idx}.json`)?.delay ?? 0);

	system(`rm -rf ${shellquote(dir)}`);
	return out;
};

export function reselect(group) {
	return request(`/group/${urlencode(group)}/delay?url=${urlencode(DELAY_URL)}&timeout=5000`,
		{ timeout: 20 });
};

export function setMode(mode) {
	return request('/configs', { method: 'PATCH', body: { mode } });
};

export function updateRuleProvider(name) {
	return request(`/providers/rules/${urlencode(name)}`, { method: 'PUT', timeout: 30 });
};

/* PUT /proxies 只改选中项，存量连接仍走旧出站；按 chains 逐条断，勿全量 DELETE /connections */
export function closeVia(outbound) {
	if (!length(outbound))
		return 0;

	const snapshot = connections();
	if (!snapshot.ok || type(snapshot.data?.connections) != 'array')
		return 0;

	let closed = 0;

	for (let conn in snapshot.data.connections) {
		let hit = false;

		for (let hop in (conn.chains ?? [])) {
			if (hop == outbound) {
				hit = true;
				break;
			}
		}

		if (!hit || !length(conn.id))
			continue;

		request(`/connections/${urlencode(conn.id)}`, { method: 'DELETE', timeout: 5 });
		closed++;
	}

	return closed;
};

const SPEED_URL = 'https://speed.cloudflare.com/__down?bytes=100000000';
const SPEED_MIN_BYTES = 32768;

function downloadViaMixed(port) {
	ensurePrivateDir(STATE_DIR);
	const tag = randomHex(6);
	const confFile = `${STATE_DIR}/spd-${tag}.conf`;
	const errFile = `${STATE_DIR}/spd-${tag}.err`;

	writefile(confFile, join('\n', [
		'silent',
		'show-error',
		`url = "${SPEED_URL}"`,
		'header = "Referer: https://speed.cloudflare.com/"',
		'header = "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"',
		'max-time = 10',
		'connect-timeout = 2',
		'output = "/dev/null"',
		'write-out = "%{size_download} %{time_total} %{time_starttransfer} %{http_code}"',
		`proxy = "http://127.0.0.1:${port}"`
	]) + '\n');

	let written = '';
	const proc = popen(`curl -K ${shellquote(confFile)} 2>${shellquote(errFile)}`);
	if (proc) {
		written = proc.read('all') ?? '';
		proc.close();
	}

	for (let path in [ confFile, errFile ])
		unlink(path);

	const parts = split(trim(written), /[ \t]+/);
	const bytes = +parts[0];
	const seconds = +parts[1];
	const starttransfer = +parts[2];
	const status = +parts[3];
	const transfer = seconds > starttransfer ? seconds - starttransfer : seconds;
	if (status < 200 || status >= 300 || bytes < SPEED_MIN_BYTES || transfer <= 0)
		return { ok: false, error: `speed HTTP ${status}`, bytes_per_second: 0 };

	const bps = int(bytes / transfer);
	if (bps <= 0)
		return { ok: false, error: 'speed failed', bytes_per_second: 0 };

	return { ok: true, error: null, bytes_per_second: bps };
};

export function applyPayload(configJson) {
	return request('/configs?force=true', { method: 'PUT', body: { payload: configJson }, timeout: 120 });
};

export function speedOne(name) {
	const selected = select(SPEED_GROUP, name);
	if (!selected.ok)
		return { ok: false, error: selected.error, bytes_per_second: 0 };

	const res = downloadViaMixed(speedPort(settings().mixedPort));
	closeVia(SPEED_GROUP);
	return res;
};

export function updateGeo() {
	return request('/configs/geo', { method: 'POST', timeout: 180 });
};
