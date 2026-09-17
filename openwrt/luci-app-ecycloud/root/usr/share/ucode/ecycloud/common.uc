'use strict';

import { access, chmod, lsdir, open, popen, readfile, unlink, writefile } from 'fs';
import { cursor } from 'uci';

export const CONF_DIR = '/etc/ecycloud';
export const STATE_DIR = '/var/run/ecycloud';
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

export const NFT_DIR = '/usr/share/nftables.d';
export const NFT_TABLE = 'ecycloud';
export const TPROXY_MARK = 502;
export const ROUTING_MARK = 503;
export const ROUTE_TABLE = 1936;
export const CONTROLLER_PORT = 19090;

const FILE_MODE = int('600', 8);
const DIR_MODE = int('700', 8);

export function shellquote(value) {
	return `'${replace(`${value}`, "'", "'\\''")}'`;
};

export function log(level, message) {
	system(`logger -t ecycloud -p daemon.${level} ${shellquote(message)}`);
};

export function ensureDir(path) {
	if (!access(path))
		system(`mkdir -p ${shellquote(path)}`);
};

export function ensurePrivateDir(path) {
	ensureDir(path);
	chmod(path, DIR_MODE);
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

export function writeJson(path, value) {
	return writefile(path, sprintf('%J', value)) != null;
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

	return {
		enabled: raw.enabled == '1',
		mode: raw.mode == 'tun' ? 'tun' : 'tproxy',
		routeMode: raw.route_mode ?? 'rule',
		logLevel: raw.log_level ?? 'warning',
		tproxyPort: +(raw.tproxy_port ?? 10202),
		mixedPort: +(raw.mixed_port ?? 10203),
		dnsPort: +(raw.dns_port ?? 10201),
		allowLan: (raw.allow_lan ?? '1') == '1',
		ipv6: (raw.ipv6 ?? '1') == '1',
		dnsHijack: (raw.dns_hijack ?? '1') == '1',
		routerProxy: raw.router_proxy == '1',
		tunDevice: raw.tun_device || 'ECYCloud',
		tunStack: raw.tun_stack ?? 'mixed',
		tunExclude: uciList(raw.tun_exclude),
		bypass: uciList(raw.bypass),
		runDir: raw.run_dir ?? `${CONF_DIR}/run`,
		geoxBase: replace(trim(raw.geox_base ?? ''), /\/+$/, ''),
		refreshInterval: +(raw.refresh_interval ?? 5),
		autoConnect: raw.auto_connect == '1',
		lanInterfaces: length(uciList(raw.lan_interface)) ? uciList(raw.lan_interface) : [ 'lan' ]
	};
};

export function build() {
	return readJson(BUILD_FILE) ?? {};
};

export function creds() {
	return readJson(CRED_FILE) ?? {};
};

export function saveCreds(next) {
	ensurePrivateDir(CONF_DIR);
	return writePrivateJson(CRED_FILE, next);
};

function originOf(url) {
	const m = match(trim(`${url ?? ''}`), /^(https?):\/\/([^\/?#]+)/);
	return m ? `${m[1]}://${m[2]}` : '';
};

export function origins() {
	const seed = build();
	const uci = cursor();
	const site = originOf(uci.get('ecycloud', 'config', 'site_url') ?? seed.site_url);
	const sub = originOf(uci.get('ecycloud', 'config', 'sub_url') ?? seed.sub_url);

	return { site, sub: length(sub) ? sub : site };
};

/* 面板下发的 origin 必须是 https，http 一律丢弃：落盘后此后带 token 的请求都打这里 */
export function saveOrigins(site, sub) {
	const uci = cursor();
	const current = origins();
	let changed = false;

	for (let entry in [ [ 'site_url', site, current.site ], [ 'sub_url', sub, current.sub ] ]) {
		const next = originOf(entry[1]);
		if (!length(next) || substr(next, 0, 8) != 'https://' || next == entry[2])
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

export function randomHex(bytes) {
	const fd = open('/dev/urandom', 'r');
	let out = '';

	if (fd) {
		const raw = fd.read(bytes) ?? '';
		fd.close();
		for (let i = 0; i < length(raw); i++)
			out += sprintf('%02x', ord(raw, i));
	}

	return out;
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

export function setState(stage, message, error) {
	ensurePrivateDir(STATE_DIR);
	writeJson(STATE_FILE, {
		stage,
		message: message ?? '',
		error: error ?? '',
		updated: time()
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
	ensurePrivateDir(STATE_DIR);

	const tag = randomHex(6);
	const confFile = `${STATE_DIR}/req-${tag}.conf`;
	const bodyFile = `${STATE_DIR}/req-${tag}.json`;
	const respFile = `${STATE_DIR}/resp-${tag}.json`;
	const errFile = `${STATE_DIR}/resp-${tag}.err`;

	const conf = [
		'silent',
		'show-error',
		`url = "${opts.url}"`,
		`max-time = ${opts.timeout ?? 20}`,
		`connect-timeout = ${opts.connectTimeout ?? 10}`,
		`output = "${respFile}"`,
		'write-out = "%{http_code}"'
	];

	if (length(opts.proxy))
		push(conf, `proxy = "${opts.proxy}"`);

	if (length(opts.method))
		push(conf, `request = "${opts.method}"`);

	for (let header in (opts.headers ?? []))
		push(conf, `header = "${header}"`);

	if (opts.body != null) {
		writefile(bodyFile, opts.body);
		push(conf, `data-binary = "@${bodyFile}"`);
	}

	writefile(confFile, `${join('\n', conf)}\n`);

	let written = '';
	const proc = popen(`curl -K ${shellquote(confFile)} 2>${shellquote(errFile)}`);
	if (proc) {
		written = proc.read('all') ?? '';
		proc.close();
	}

	const status = +trim(written) || 0;
	const text = readfile(respFile) ?? '';
	const failure = trim(readfile(errFile) ?? '');

	for (let path in [ confFile, bodyFile, respFile, errFile ])
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
		if (length(device) && !(device in devices))
			push(devices, device);
	}

	return devices;
};
