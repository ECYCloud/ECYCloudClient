'use strict';

import { popen, readfile, unlink, writefile } from 'fs';

import { API_FILE, CONTROLLER_PORT, STATE_DIR, ensurePrivateDir, freePort, httpRequest,
         instances, randomHex, readJson, settings, shellquote, urlencode,
         writePrivateJson } from 'ecycloud.common';
import { NODE_PROVIDER, SPEED_GROUP, nodeProviderNames, nodesOf, speedPort } from 'ecycloud.profile';

/* unified-delay 下内核连打两次 HEAD 并从第二次计时，明文 HTTP 会被内核警告劫持，用 https */
const DELAY_URL = 'https://cp.cloudflare.com/generate_204';

export function endpoint() {
	const api = readJson(API_FILE);
	if (api?.port && length(api.secret) && !length(api.speed)) {
		api.speed = randomHex(16);
		if (!writePrivateJson(API_FILE, api))
			die('无法保存测速入站口令');
	}
	return api;
};

export function reserve() {
	const prev = endpoint();
	if (prev?.port && length(prev.secret) && freePort(prev.port) == prev.port) {
		return prev;
	}

	const api = { port: freePort(CONTROLLER_PORT), secret: randomHex(16), speed: randomHex(16) };
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
	const snapshot = request('/proxies');
	if (!snapshot.ok)
		return snapshot;
	const config = readJson(`${settings().runDir}/config.json`);
	if (config?.['proxy-providers']?.[NODE_PROVIDER] != null) {
		const provider = request(`/providers/proxies/${NODE_PROVIDER}`);
		if (!provider.ok)
			return provider;
		for (let node in (provider.data?.proxies ?? []))
			if (length(node?.name))
				snapshot.data.proxies[node.name] = node;
	}
	return snapshot;
};

export function proxy(name) {
	return request(`/proxies/${urlencode(name)}`);
};

export function connections() {
	return request('/connections');
};

export function providerProgress() {
	const config = readJson(`${settings().runDir}/config.json`);
	const names = keys(config?.['rule-providers'] ?? {});
	if (!length(names))
		return { ready: 0, total: 0 };
	const res = request('/providers/rules', { timeout: 3 });
	if (!res.ok)
		return { ready: 0, total: length(names) };
	return { ready: length(filter(names, name => +(res.data?.providers?.[name]?.ruleCount ?? 0) > 0 ||
		match(`${res.data?.providers?.[name]?.updatedAt ?? ''}`, /^[2-9]\d{3}-/))), total: length(names) };
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
	const config = readJson(`${settings().runDir}/config.json`);
	const providerNodes = config?.['proxy-providers']?.[NODE_PROVIDER] != null ? map(nodesOf(config), node => node.name) : [];
	for (let name in names) {
		const idx = length(order);
		push(order, name);
		const path = name in providerNodes ? `/providers/proxies/${NODE_PROVIDER}/${urlencode(name)}/healthcheck` : `/proxies/${urlencode(name)}/delay`;
		writefile(`${dir}/${idx}.conf`, join('\n', [
			'silent',
			`url = "http://127.0.0.1:${api.port}${path}?url=${urlencode(DELAY_URL)}&timeout=${ms}"`,
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

export function setTunEnabled(enabled) {
	return request('/configs', { method: 'PATCH', body: { tun: { enable: enabled } }, timeout: 5 });
};

export function updateRuleProvider(name) {
	return request(`/providers/rules/${urlencode(name)}`, { method: 'PUT', timeout: 30 });
};

export function updateProxyProviders(config) {
	for (let name in nodeProviderNames(config)) {
		const updated = request(`/providers/proxies/${urlencode(name)}`, { method: 'PUT', timeout: 30 });
		if (!updated.ok)
			return updated;
	}
	return { ok: true };
};

export function closeConnection(id) {
	if (!match(`${id ?? ''}`, /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/))
		return { ok: false, status: 0, data: null, error: 'invalid connection id' };
	return request(`/connections/${id}`, { method: 'DELETE', timeout: 5 });
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

		closeConnection(conn.id);
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
	const headerFile = `${STATE_DIR}/spd-${tag}.headers`;

	const conf = [
		'silent',
		'show-error',
		`url = "${SPEED_URL}"`,
		'header = "Referer: https://speed.cloudflare.com/"',
		'header = "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"',
		'max-time = 10',
		'connect-timeout = 2',
		'max-filesize = 100000000',
		'output = "-"',
		`dump-header = "${headerFile}"`,
		`proxy = "http://127.0.0.1:${port}"`
	];
	// 测速入站要口令：ecy-speed 只接受带此口令的本机 curl（值为 randomHex，无需转义）
	const speed = endpoint()?.speed;
	if (length(speed))
		push(conf, `proxy-user = "${SPEED_GROUP}:${speed}"`);

	writefile(confFile, join('\n', conf) + '\n');

	const micros = () => { const stamp = clock(true); return stamp[0] * 1000000 + int(stamp[1] / 1000); };
	let bytes = 0;
	let bps = 0;
	let transfer = 0;
	let exitCode = -1;
	let failed = false;
	let status = 0;
	let proc = popen(`curl -K ${shellquote(confFile)} 2>${shellquote(errFile)}`);
	try {
		if (proc) {
			let chunk = proc.read(1);
			const started = micros();
			let checkpoint = 0;
			let windowBytes = 0;
			while (length(chunk)) {
				bytes += length(chunk);
				windowBytes += length(chunk);
				const elapsed = int((micros() - started) / 1000) - checkpoint + 1;
				if (elapsed > 1000) {
					bps = max(bps, int(windowBytes * 1000 / elapsed + 0.5));
					windowBytes = 0;
					checkpoint += elapsed - 1;
				}
				chunk = proc.read(16384);
			}
			transfer = micros() - started;
			const elapsed = int(transfer / 1000) - checkpoint + 1;
			if (elapsed > 1000)
				bps = max(bps, int(windowBytes * 1000 / elapsed + 0.5));
			exitCode = proc.close();
			proc = null;
		}
		for (let line in split(readfile(headerFile, 8192) ?? '', '\n')) {
			const head = match(line, /^HTTP\/\S+\s+([0-9]+)/);
			if (head)
				status = +head[1];
		}
	} catch (e) {
		failed = true;
	}
	if (proc)
		exitCode = proc.close();
	for (let path in [ confFile, errFile, headerFile ])
		unlink(path);
	if (failed || status < 200 || status >= 300 || !(exitCode in [ 0, 28 ]) || bytes < SPEED_MIN_BYTES || bytes > 100000000)
		return { ok: false, error: `speed HTTP ${status}`, bytes_per_second: 0 };
	if (bps <= 0 && transfer > 0)
		bps = int(bytes * 1000000 / transfer + 0.5);
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
