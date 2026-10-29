'use strict';

import { access, chmod, lsdir, open, popen, readfile, rename, unlink, writefile } from 'fs';
import { cursor } from 'uci';

export const CONF_DIR = '/etc/ecycloud';
export const STATE_DIR = '/var/run/ecycloud';
export const SESSION_CHANGE = `${STATE_DIR}/session-changing`;
export const BUILD_FILE = '/usr/share/ecycloud/build.json';
export const CRED_FILE = `${CONF_DIR}/credentials.json`;
export const ANNOUNCE_FILE = `${CONF_DIR}/announcement.json`;
export const PROFILE_FILE = `${CONF_DIR}/profile.json`;
export const STATE_FILE = `${STATE_DIR}/state.json`;
export const API_FILE = `${STATE_DIR}/api.json`;
export const ACCOUNT_FILE = `${STATE_DIR}/account.json`;
export const NETWORK_FILE = `${STATE_DIR}/network.json`;
export const DELAY_FILE = `${STATE_DIR}/delay.json`;
export const SPEED_FILE = `${STATE_DIR}/speed.json`;
export const ANNOUNCE_CACHE = `${STATE_DIR}/announcements.json`;
export const KICK_FILE = `${STATE_DIR}/device_kicked`;
const PANEL_ADDRESS_FILE = `${STATE_DIR}/panel-addresses.json`;

export const NFT_DIR = '/usr/share/nftables.d';
export const NFT_TABLE = 'ecycloud';
export const TPROXY_MARK = 502;
export const ROUTING_MARK = 503;
export const ROUTE_TABLE = 1936;
export const TUN_ROUTE_TABLE = 1937;
export const TUN_RULE_INDEX = 1937;
export const CONTROLLER_PORT = 19090;

const FILE_MODE = int('600', 8);
const DIR_MODE = int('700', 8);

export function shellquote(value) {
	return `'${replace(`${value}`, "'", "'\\''")}'`;
};

function curlquote(value) {
	return '"' + replace(replace(replace(replace(replace(`${value}`, '\\', '\\\\'), '"', '\\"'), '\n', '\\n'), '\r', '\\r'), '\t', '\\t') + '"';
};

export function ensureDir(path) {
	if (!access(path))
		system(`mkdir -p ${shellquote(path)}`);
};

export function ensurePrivateDir(path) {
	ensureDir(path);
	chmod(path, DIR_MODE);
};

export function sessionLease() {
	ensurePrivateDir(STATE_DIR);
	if (access(SESSION_CHANGE))
		return null;
	/* curl 子进程也须持有共享锁，避免父任务退出后仍在写旧会话响应。 */
	const lock = open(`${STATE_DIR}/session.lock`, 'a', 0600);
	if (!lock)
		die('无法打开会话锁');
	if (!lock.lock('sn') || access(SESSION_CHANGE)) {
		lock.close();
		return null;
	}
	return lock;
};

export function readJson(path) {
	const raw = readfile(path);
	if (!length(raw))
		return null;
	try {
		return json(raw);
	} catch (e) {
		return null;
	}
};

export function randomHex(bytes) {
	const fd = open('/dev/urandom', 'r');
	let out = '';

	if (fd) {
		const raw = fd.read(bytes) ?? '';
		fd.close();
		for (let i = 0; i < length(raw); i++)
			out += sprintf('%02x', ord(raw, i));
	}

	if (length(out) != bytes * 2)
		die('无法读取系统安全随机数');
	return out;
};

export function writeAtomic(path, text) {
	const temporary = `${path}.${randomHex(6)}.tmp`;
	if (writefile(temporary, text) == length(text) && chmod(temporary, FILE_MODE) && rename(temporary, path))
		return true;
	unlink(temporary);
	return false;
};

export function writeJson(path, value) {
	return writeAtomic(path, sprintf('%J', value));
};

export function writePrivateJson(path, value) {
	const ok = writeJson(path, value);
	chmod(path, FILE_MODE);
	return ok;
};

export function uciList(value) {
	if (value == null)
		return [];
	return type(value) == 'array' ? value : [ value ];
};

export function isIpNet(value) {
	const item = trim(`${value ?? ''}`);
	if (!length(item) || match(item, /[^0-9A-Fa-f:./]/))
		return false;

	if (index(item, ':') >= 0)
		return match(item, /^[0-9A-Fa-f:]+(\/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8]))?$/) != null
			&& index(item, ':::') < 0;

	const m = match(item, /^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(\/([0-9]|[12][0-9]|3[0-2]))?$/);
	return m != null && +m[1] <= 255 && +m[2] <= 255 && +m[3] <= 255 && +m[4] <= 255;
};

export function appendNets(base, extra) {
	const out = [];
	const seen = {};

	for (let net in (base ?? [])) {
		const item = trim(`${net ?? ''}`);
		if (!length(item) || seen[item])
			continue;
		seen[item] = true;
		push(out, item);
	}

	for (let net in (extra ?? [])) {
		const item = trim(`${net ?? ''}`);
		if (!length(item) || seen[item] || !isIpNet(item))
			continue;
		seen[item] = true;
		push(out, item);
	}

	return out;
};

export function settings() {
	const raw = cursor().get_all('ecycloud', 'config') ?? {};
	const runDir = raw.run_dir ?? `${CONF_DIR}/run`;
	if (runDir != `${CONF_DIR}/run`)
		die(`运行目录必须为 ${CONF_DIR}/run`);
	const tunDevice = raw.tun_device || 'ECYCloud';
	if (index(tunDevice, '\0') >= 0 || match(tunDevice, /[[:cntrl:][:space:]]/) ||
	    !match(tunDevice, /^[A-Za-z0-9_.-]{1,15}$/))
		die('TUN 网卡名只能包含 1 到 15 个字母、数字、下划线、点或连字符');

	return {
		enabled: raw.enabled == '1',
		mode: raw.mode == 'tun' ? 'tun' : 'tproxy',
		routeMode: raw.route_mode ?? 'rule',
		logLevel: raw.log_level ?? 'warning',
		tproxyPort: +(raw.tproxy_port ?? 10202),
		mixedPort: +(raw.mixed_port ?? 10203),
		dnsPort: +(raw.dns_port ?? 10201),
		allowLan: (raw.allow_lan ?? '1') == '1',
		ipv6: raw.ipv6 == '1',
		dnsHijack: (raw.dns_hijack ?? '1') == '1',
		routerProxy: raw.router_proxy == '1',
		tunDevice,
		tunStack: raw.tun_stack ?? 'mixed',
		tunExclude: uciList(raw.tun_exclude),
		bypass: uciList(raw.bypass),
		runDir,
		geoxBase: replace(trim(raw.geox_base ?? ''), /\/+$/, ''),
		refreshInterval: +(raw.refresh_interval ?? 5),
		autoConnect: raw.auto_connect == '1',
		lanInterfaces: length(uciList(raw.lan_interface)) ? uciList(raw.lan_interface) : [ 'lan' ]
	};
};

export function log(level, message) {
	const levels = { debug: 0, info: 1, notice: 1, warning: 2, err: 3, error: 3, silent: 4 };
	if ((levels[level] ?? 2) < (levels[settings().logLevel] ?? 2))
		return;
	system(`logger -t ecycloud -p daemon.${level} ${shellquote(message)}`);
};

export function build() {
	return readJson(BUILD_FILE) ?? {};
};

export function creds() {
	return readJson(CRED_FILE) ?? {};
};

export function timestamp(value) {
	if (type(value) == 'int' || type(value) == 'double')
		return +value > 0 ? +value : 0;
	const m = match(`${value ?? ''}`, /^(\d{4,6})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(Z|([+-])(\d{2}):(\d{2}))$/);
	if (!m)
		return 0;
	const parts = { year: +m[1], mon: +m[2], mday: +m[3], hour: +m[4], min: +m[5], sec: +m[6] };
	const utc = timegm(parts);
	const checked = gmtime(utc);
	for (let key, field in parts)
		if (checked[key] != field)
			return 0;
	if (m[7] != 'Z' && (+m[9] > 23 || +m[10] > 59))
		return 0;
	return utc - (m[7] == 'Z' ? 0 : (m[8] == '+' ? 1 : -1) * (+m[9] * 3600 + +m[10] * 60));
};

export function sessionValid() {
	const saved = creds();
	return length(saved.token) > 0 && timestamp(saved.expires_at) > time();
};

export function saveCreds(next) {
	ensurePrivateDir(CONF_DIR);
	return writePrivateJson(CRED_FILE, next);
};

/* 只认 https：这个 origin 承载此后全部带 token 的面板请求，http 等于把会话交给链路上任何人 */
function originOf(url) {
	const value = `${url ?? ''}`;
	if (index(value, '\0') >= 0 || match(value, /[[:cntrl:][:space:]"'\\]/))
		return '';
	const m = match(value, /^https:\/\/([^\/?#@]+)/);
	if (m && index(value, '@') >= 0)
		return '';
	return m ? `https://${m[1]}` : '';
};

export function origins() {
	const seed = build();
	const uci = cursor();
	const site = originOf(uci.get('ecycloud', 'config', 'site_url') ?? seed.site_url);
	const sub = originOf(uci.get('ecycloud', 'config', 'sub_url') ?? seed.sub_url);

	return { site, sub: length(sub) ? sub : site };
};

function isPanelDirectAddress(address) {
	return type(address) == 'string' && isIpNet(address) && index(address, '/') < 0 && !match(address, /^198\.(18|19)\./);
};

export function panelDirectHosts(refresh) {
	const current = origins();
	const binding = sprintf('%J', current);
	const saved = readJson(PANEL_ADDRESS_FILE);
	const previous = saved?.binding == binding && type(saved.hosts) == 'object' ? saved.hosts : {};
	const expired = saved?.binding != binding || time() - +(saved.resolved_at ?? 0) >= 300;

	const hosts = {};
	for (let origin in [ current.site, current.sub ]) {
		if (hosts[origin] != null)
			continue;
		const target = match(origin, /^https:\/\/(\[[0-9A-Fa-f:]+\]|[^:/?#]+)(:([0-9]+))?$/);
		if (!target)
			continue;
		const host = replace(target[1], /^\[|\]$/g, '');
		const cached = previous[origin]?.addresses;
		let addresses = type(cached) == 'array' ? filter(cached, isPanelDirectAddress) : [];
		if (isPanelDirectAddress(host)) {
			addresses = [ host ];
		} else if (refresh && expired) {
			const next = [];
			const proc = popen(`resolveip -t 3 -- ${shellquote(host)} 2>/dev/null`);
			const text = proc?.read('all') ?? '';
			const status = proc?.close();
			if (status == 0)
				for (let line in split(text, '\n')) {
					const address = trim(line);
					if (isPanelDirectAddress(address) && !(address in next))
						push(next, address);
				}
			if (length(next))
				addresses = next;
		}
		hosts[origin] = { host: target[1], port: +(target[3] ?? 443), addresses };
	}
	if (refresh && expired) {
		ensurePrivateDir(STATE_DIR);
		writeJson(PANEL_ADDRESS_FILE, { binding, hosts, resolved_at: time() });
	}
	return hosts;
};

export function panelDirectNets() {
	const nets = [];
	for (let origin, target in panelDirectHosts(false))
		for (let address in target.addresses) {
			const net = `${address}/${index(address, ':') >= 0 ? 128 : 32}`;
			if (!(net in nets))
				push(nets, net);
		}
	return nets;
};

export function sha256File(path) {
	const proc = popen(`sha256sum ${shellquote(path)} 2>/dev/null`);
	const digest = trim(proc?.read('all') ?? '');
	const status = proc?.close();
	const m = match(digest, /^([a-f0-9]{64})\s/);
	return status == 0 && m ? m[1] : '';
};

export function sessionBinding() {
	const digest = sessionValid() ? sha256File(CRED_FILE) : '';
	return length(digest) ? sprintf('%J', { digest, ...origins() }) : '';
};

export function saveOrigins(site, sub) {
	const uci = cursor();
	const current = origins();
	let changed = false;

	for (let entry in [ [ 'site_url', site, current.site ], [ 'sub_url', sub, current.sub ] ]) {
		const next = originOf(entry[1]);
		if (!length(next) || next == entry[2])
			continue;
		uci.set('ecycloud', 'config', entry[0], next);
		changed = true;
	}

	if (changed) {
		uci.commit('ecycloud');
		log('notice', `panel origin updated: ${origins().site} / ${origins().sub}`);
	}
};

function osRelease() {
	const raw = readfile('/etc/os-release') ?? '';
	const m = match(raw, /OPENWRT_RELEASE="?([^"\n]+)"?/) ?? match(raw, /PRETTY_NAME="?([^"\n]+)"?/);
	return m ? trim(m[1]) : 'OpenWrt';
};

function hostname() {
	const name = cursor().get('system', '@system[0]', 'hostname');
	return length(name) ? name : trim(readfile('/proc/sys/kernel/hostname') ?? 'OpenWrt');
};

export function device() {
	const raw = readfile(CRED_FILE) ?? '';
	let saved = null;

	if (length(raw)) {
		try {
			saved = json(raw);
		} catch (e) {
			saved = null;
		}
	}

	if (type(saved) != 'object' || saved == null) {
		if (access(CRED_FILE))
			saved = { device_id: '' };
		else {
			saved = {
				device_id: trim(readfile('/proc/sys/kernel/random/uuid') ?? '') || randomHex(16)
			};
			saveCreds(saved);
		}
	} else if (!length(saved.device_id)) {
		saved.device_id = trim(readfile('/proc/sys/kernel/random/uuid') ?? '') || randomHex(16);
		saveCreds(saved);
	}

	return {
		device_id: saved.device_id,
		device_name: hostname(),
		device_model: trim(readfile('/tmp/sysinfo/model') ?? '') || 'OpenWrt Router',
		os_version: osRelease(),
		app_version: build().version ?? '0.0.0'
	};
};

export function userAgent() {
	const version = build().version ?? '0.0.0';
	const product = index(version, 'Pre ') == 0 ? `Pre${substr(version, 4)}` : version;
	return `ECYCloud/${product} (OpenWrt)`;
};

/* HTTP 头只保证 ASCII，非 ASCII 须百分号编码，面板侧 rawurldecode 还原 */
export function urlencode(value) {
	const raw = `${value ?? ''}`;
	let out = '';

	for (let i = 0; i < length(raw); i++) {
		const c = substr(raw, i, 1);
		out += match(c, /^[A-Za-z0-9._~-]$/) ? c : sprintf('%%%02X', ord(raw, i));
	}

	return out;
};

export function mihomoBin() {
	return access('/usr/bin/mihomo', 'x') ? '/usr/bin/mihomo' : '/usr/libexec/mihomo';
};

export function freePort(base) {
	const used = {};

	for (let path in [ '/proc/net/tcp', '/proc/net/tcp6' ]) {
		for (let line in split(readfile(path) ?? '', '\n')) {
			const m = match(line, /^\s*[0-9]+:\s+[0-9A-Fa-f]+:([0-9A-Fa-f]{4})\s/);
			if (m)
				used[hex(m[1])] = true;
		}
	}

	for (let port = base; port < base + 200; port++)
		if (!used[port])
			return port;

	return base;
};

export function state() {
	return readJson(STATE_FILE) ?? { stage: 'stopped', message: '', error: '', updated: 0 };
};

export function setState(stage, message, error, retryable) {
	ensurePrivateDir(STATE_DIR);
	const previous = state();
	writeJson(STATE_FILE, {
		stage,
		message: message ?? '',
		error: error ?? '',
		updated: time(),
		connected_at: stage == 'running' ? (+previous.connected_at || time()) : 0,
		retryable: retryable == true
	});
};

export function setError(message) {
	setState('failed', '', message);
	log('err', message);
};

export function markKicked(reason) {
	ensurePrivateDir(STATE_DIR);
	writefile(KICK_FILE, length(reason) ? reason : 'limit');
};

export function clearKicked() {
	unlink(KICK_FILE);
};

export function wasKicked() {
	return access(KICK_FILE);
};

export function kickReason() {
	if (!access(KICK_FILE))
		return '';
	const text = trim(readfile(KICK_FILE) ?? '');
	return length(text) ? text : 'limit';
};

/* 令牌与请求体不进 argv：一律经 0700 目录下的 curl 配置文件传递 */
export function httpRequest(opts) {
	if (!match(`${opts.url ?? ''}`, /^https?:\/\//) || index(opts.url, '\0') >= 0 || match(opts.url, /[[:cntrl:][:space:]]/))
		return { status: 0, text: '', data: null, error: '无效的 HTTP 地址' };
	for (let header in (opts.headers ?? []))
		if (index(`${header}`, '\0') >= 0 || match(`${header}`, /[[:cntrl:]]/))
			return { status: 0, text: '', data: null, error: '无效的 HTTP 请求头' };
	ensurePrivateDir(STATE_DIR);

	const tag = randomHex(6);
	const confFile = `${STATE_DIR}/req-${tag}.conf`;
	const bodyFile = `${STATE_DIR}/req-${tag}.json`;
	const respFile = `${STATE_DIR}/resp-${tag}.json`;
	const errFile = `${STATE_DIR}/resp-${tag}.err`;
	const headerFile = `${STATE_DIR}/resp-${tag}.headers`;

	const conf = [
		'silent',
		'show-error',
		'globoff',
		'proto = "=http,https"',
		'max-filesize = 8388608',
		`url = ${curlquote(opts.url)}`,
		`max-time = ${opts.timeout ?? 20}`,
		`connect-timeout = ${opts.connectTimeout ?? 10}`,
		`output = "${respFile}"`,
		`dump-header = "${headerFile}"`,
		'write-out = "%{http_code}"'
	];

	if (length(opts.proxy)) {
		push(conf, `proxy = ${curlquote(opts.proxy)}`);
		if (opts.direct)
			push(conf, 'noproxy = ""');
	} else if (opts.direct) {
		push(conf, 'proxy = ""', 'noproxy = "*"');
		if (length(opts.resolve))
			push(conf, `resolve = ${curlquote(opts.resolve)}`);
	}

	if (length(opts.method))
		push(conf, `request = ${curlquote(opts.method)}`);

	for (let header in (opts.headers ?? []))
		push(conf, `header = ${curlquote(header)}`);

	if (opts.body != null) {
		writefile(bodyFile, opts.body);
		push(conf, `data-binary = "@${bodyFile}"`);
	}

	writefile(confFile, `${join('\n', conf)}\n`);

	let written = '';
	let exitCode = -1;
	const proc = popen(`curl -q -K ${shellquote(confFile)} 2>${shellquote(errFile)}`);
	if (proc) {
		written = proc.read('all') ?? '';
		exitCode = proc.close();
	}

	const status = +trim(written) || 0;
	const text = readfile(respFile) ?? '';
	const failure = trim(readfile(errFile) ?? '');
	let retryAfter = null;
	let rateRemaining = null;
	let rateReset = null;
	for (let line in split(readfile(headerFile, 8192) ?? '', '\n')) {
		if (match(line, /^HTTP\//i)) {
			retryAfter = null;
			rateRemaining = null;
			rateReset = null;
		}
		const header = match(line, /^Retry-After:\s*([+]?[0-9]+)\s*$/i);
		if (header && +header[1] > 0)
			retryAfter = +header[1];
		const remaining = match(line, /^X-RateLimit-Remaining:\s*([0-9]+)\s*$/i);
		const reset = match(line, /^X-RateLimit-Reset:\s*([0-9]+)\s*$/i);
		if (remaining)
			rateRemaining = +remaining[1];
		if (reset)
			rateReset = +reset[1];
	}

	for (let path in [ confFile, bodyFile, respFile, errFile, headerFile ])
		unlink(path);

	let data = null;
	if (length(text)) {
		try {
			data = json(text);
		} catch (e) {
			data = null;
		}
	}

	return {
		status,
		exit_code: exitCode,
		retry_after: retryAfter,
		rate_limit_reset: rateRemaining == 0 ? rateReset : null,
		rate_limited: rateRemaining == 0,
		text,
		data,
		error: status ? null : (length(failure) ? failure : 'connection failed')
	};
};

/* 禁止在 rpcd / 看门狗里 ubus call service.list：rpcd restart 时 procd 正持着服务锁，
   嵌套这一问会把 ubusd 卡死，LuCI 连 session 都取不到 */
export function instances() {
	const coreBin = mihomoBin();
	const runDir = settings().runDir;
	const names = lsdir('/proc') ?? [];
	let corePid = 0;
	let watchPid = 0;

	for (let name in names) {
		if (!match(name, /^[0-9]+$/))
			continue;

		const cmd = readfile(`/proc/${name}/cmdline`) ?? '';
		if (!length(cmd))
			continue;

		if (!corePid && index(cmd, coreBin) >= 0 && index(cmd, runDir) >= 0)
			corePid = +name;
		else if (!watchPid && index(cmd, 'ecycloud-ctl') >= 0 && index(cmd, 'watchdog') >= 0)
			watchPid = +name;
	}

	const out = {};

	if (corePid)
		out.core = { running: true, pid: corePid };
	if (watchPid)
		out.watchdog = { running: true, pid: watchPid };

	return out;
};

export function coreRunning() {
	return instances()?.core?.running == true;
};

export function lanDevices() {
	const devices = [];
	const uci = cursor();

	for (let name in settings().lanInterfaces) {
		const device = uci.get('network', name, 'device') ?? uci.get('network', name, 'ifname');
		// 设备名会直接拼进 nftables 规则集，仅允许合法网卡名字符，防止被篡改的 network 配置注入 nft
		if (length(device) && index(device, '\0') < 0 && !match(device, /[[:cntrl:][:space:]]/) &&
		    match(device, /^[A-Za-z0-9_.-]{1,15}$/) && !(device in devices))
			push(devices, device);
	}

	return devices;
};
