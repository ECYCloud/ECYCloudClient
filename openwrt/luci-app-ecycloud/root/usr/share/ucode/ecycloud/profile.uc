'use strict';

import { access, chmod, popen, readfile, stat, unlink, writefile } from 'fs';

import { PROFILE_FILE, ROUTING_MARK, appendNets, creds, ensureDir, mihomoBin, randomHex, readJson, settings,
         shellquote, writePrivateJson } from 'ecycloud.common';

export const SPEED_GROUP = 'ecy-speed';

export function speedPort(mixedPort) {
	return mixedPort < 65535 ? mixedPort + 1 : mixedPort - 1;
};

const EXCLUDED_ROUTES = [
	'127.0.0.0/8',
	'10.0.0.0/8',
	'172.16.0.0/12',
	'192.168.0.0/16',
	'169.254.0.0/16',
	'224.0.0.0/4',
	'::1/128',
	'fc00::/7',
	'fe80::/10',
	'ff00::/8'
];

/* 分组顺序只存在于面板配置里：这份缓存取不到，界面就会退到内核 /proxies 的 map 序
   （json.Marshal 按键名字母序），分组排列整个变样。因此旧版没有 account 标记的缓存
   必须照用——它只可能属于本机登录过的账号，下一次 store 会补上标记 */
export function cached() {
	const saved = readJson(PROFILE_FILE);
	if (type(saved) != 'object')
		return null;

	if (!exists(saved, 'account'))
		return saved;

	const account = lc(trim(creds().email ?? ''));
	return length(account) && saved.account == account ? saved : null;
};

export function store(remote) {
	return writePrivateJson(PROFILE_FILE, {
		account: lc(trim(creds().email ?? '')),
		revision: remote.revision ?? '',
		config: remote.config,
		node_labels: remote.node_labels ?? {},
		fetched_at: time()
	});
};

function tunExcludes(cfg) {
	const extra = [];

	for (let net in (cfg.tunExclude ?? []))
		push(extra, net);
	for (let net in (cfg.bypass ?? []))
		push(extra, net);

	return appendNets(EXCLUDED_ROUTES, extra);
};

function tunSection(cfg) {
	return {
		enable: cfg.enabled && cfg.mode == 'tun',
		stack: cfg.tunStack,
		device: cfg.tunDevice,
		'auto-route': true,
		'auto-detect-interface': true,
		/* strict-route 会一并阻断旁路由与 LAN 直连流量，路由器上必须关闭 */
		'strict-route': false,
		mtu: 9000,
		'dns-hijack': [ 'any:53' ],
		'inet4-address': [ '172.19.0.1/30' ],
		'inet6-address': [ 'fdfe:dcba:9876::1/126' ],
		'route-exclude-address': tunExcludes(cfg)
	};
};

function overrides(cfg, api) {
	return {
		'mixed-port': cfg.mixedPort,
		port: 0,
		'socks-port': 0,
		'redir-port': 0,
		/* 透明代理靠内核这个监听口收流，路由器上必须是实值，不能照桌面端写 0 */
		'tproxy-port': cfg.mode == 'tun' ? 0 : cfg.tproxyPort,
		mode: cfg.routeMode,
		'allow-lan': cfg.allowLan,
		'bind-address': cfg.allowLan ? '*' : '127.0.0.1',
		authentication: [],
		listeners: [],
		tunnels: [],
		'log-level': cfg.logLevel,
		'routing-mark': ROUTING_MARK,
		'external-controller': `127.0.0.1:${api.port}`,
		secret: api.secret,
		'external-controller-unix': '',
		'external-controller-pipe': '',
		'external-controller-tls': '',
		'external-doh-server': '',
		'external-ui': '',
		'external-ui-url': '',
		'external-controller-cors': {
			'allow-origins': [ 'http://127.0.0.1' ],
			'allow-private-network': false
		},
		ipv6: cfg.ipv6,
		tun: tunSection(cfg),
		profile: {
			'store-selected': true,
			'store-fake-ip': true
		}
	};
};

function fallbacks(cfg) {
	return {
		'unified-delay': true,
		'tcp-concurrent': true,
		dns: {
			enable: true,
			ipv6: cfg.ipv6,
			'enhanced-mode': 'fake-ip',
			'fake-ip-range': '198.18.0.1/16',
			'default-nameserver': [ '223.5.5.5' ],
			nameserver: [ 'https://1.1.1.1/dns-query' ],
			'proxy-server-nameserver': [ '223.5.5.5' ]
		}
	};
};

function isBuiltin(name) {
	switch (lc(`${name ?? ''}`)) {
	case 'direct':
	case 'reject':
	case 'reject-drop':
	case 'reject-tinygif':
	case 'pass':
	case 'compatible':
	case 'dns':
		return true;
	}

	return false;
};

function ruleTarget(parts) {
	if (!length(parts))
		return '';

	const last = parts[length(parts) - 1];
	if (lc(last) == 'no-resolve' && length(parts) >= 2)
		return parts[length(parts) - 2];
	if (length(parts) == 1)
		return '';

	return last;
};

function itemLabel(i) {
	return `第 ${i + 1} 个`;
};

function providerTitle(section) {
	return section == 'proxy-providers' ? '节点订阅' : '规则集';
};

function inspectProxies(raw, issues, names) {
	if (type(raw) != 'array') {
		push(issues, raw == null ? '面板未下发任何可用节点' : '节点列表格式不对');
		return;
	}
	if (!length(raw)) {
		push(issues, '面板未下发任何可用节点');
		return;
	}

	const seen = {};
	let i = 0;
	for (let item in raw) {
		if (type(item) != 'object') {
			push(issues, `第 ${i + 1} 个节点不是一条完整配置`);
			i++;
			continue;
		}

		const name = trim(`${item.name ?? ''}`);
		const kind = trim(`${item.type ?? ''}`);
		if (!length(name))
			push(issues, `第 ${i + 1} 个节点没有名称`);
		else if (exists(seen, name))
			push(issues, `节点名重复：${name}`);
		else {
			seen[name] = true;
			names[name] = true;
		}
		if (!length(kind))
			push(issues, `第 ${i + 1} 个节点没有类型`);
		i++;
	}
};

function inspectGroups(raw, issues, names) {
	if (type(raw) != 'array') {
		push(issues, raw == null ? '面板配置缺少策略组' : '策略组列表格式不对');
		return;
	}
	if (!length(raw)) {
		push(issues, '面板配置缺少策略组');
		return;
	}

	const groups = [];
	const seen = {};
	let i = 0;
	for (let item in raw) {
		if (type(item) != 'object') {
			push(issues, `第 ${i + 1} 个策略组不是一条完整配置`);
			i++;
			continue;
		}

		const name = trim(`${item.name ?? ''}`);
		const kind = trim(`${item.type ?? ''}`);
		if (!length(name))
			push(issues, `第 ${i + 1} 个策略组没有名称`);
		else if (exists(names, name) || exists(seen, name))
			push(issues, `策略组名重复：${name}`);
		else {
			seen[name] = true;
			names[name] = true;
		}
		if (!length(kind))
			push(issues, `第 ${i + 1} 个策略组没有类型`);

		if (type(item.proxies) != 'array' || !length(item.proxies))
			push(issues, `策略组「${length(name) ? name : itemLabel(i)}」没有成员`);
		else
			push(groups, { index: i, name, members: item.proxies });
		i++;
	}

	for (let group in groups) {
		for (let member in group.members) {
			const ref = trim(`${member ?? ''}`);
			if (!length(ref) || exists(names, ref) || isBuiltin(ref))
				continue;
			push(issues, `策略组「${length(group.name) ? group.name : itemLabel(group.index)}」的成员「${ref}」不存在`);
		}
	}
};

function inspectProviders(raw, section, issues, names) {
	if (raw == null)
		return;
	if (type(raw) != 'object') {
		push(issues, `${providerTitle(section)}这一段不是一组完整设置`);
		return;
	}

	for (let name in raw) {
		const label = trim(`${name ?? ''}`);
		if (!length(label))
			continue;
		if (names)
			names[label] = true;

		const spec = raw[name];
		if (type(spec) != 'object') {
			push(issues, `${providerTitle(section)}「${label}」不是一条完整配置`);
			continue;
		}

		const kind = trim(`${spec.type ?? ''}`);
		if (!length(kind))
			push(issues, `${providerTitle(section)}「${label}」没有类型`);
		if (section == 'rule-providers' && !length(trim(`${spec.path ?? ''}`)))
			push(issues, `规则集「${label}」没有保存路径`);
		if (kind == 'http' && !length(trim(`${spec.url ?? ''}`)))
			push(issues, `${providerTitle(section)}「${label}」是在线下载，但没有地址`);
		if (lc(trim(`${spec.format ?? ''}`)) == 'mrs' && lc(trim(`${spec.behavior ?? ''}`)) == 'classical')
			push(issues, `「${label}」把逐条规则存成了 mrs 格式，这样无法使用`);
	}
};

function inspectRules(raw, issues, names, providers) {
	if (type(raw) != 'array') {
		push(issues, raw == null ? '面板配置缺少分流规则' : '分流规则列表格式不对');
		return;
	}
	if (!length(raw)) {
		push(issues, '面板配置缺少分流规则');
		return;
	}

	let hasMatch = false;
	let i = 0;
	for (let item in raw) {
		if (type(item) != 'string') {
			push(issues, `第 ${i + 1} 条分流规则不是一行文字`);
			i++;
			continue;
		}

		const line = trim(item);
		if (!length(line) || index(line, '#') == 0) {
			i++;
			continue;
		}

		const parts = [];
		for (let part in split(line, ',')) {
			const token = trim(part);
			if (length(token))
				push(parts, token);
		}
		if (!length(parts)) {
			push(issues, `第 ${i + 1} 条分流规则写错了：${line}`);
			i++;
			continue;
		}

		const kind = uc(parts[0]);
		if (kind == 'MATCH' || kind == 'FINAL')
			hasMatch = true;
		if (kind == 'RULE-SET') {
			if (length(parts) < 2) {
				push(issues, `第 ${i + 1} 条分流规则写错了：${line}`);
				i++;
				continue;
			}
			if (!exists(providers, parts[1]))
				push(issues, `第 ${i + 1} 条分流规则用到了规则集「${parts[1]}」，但配置里没有这份规则集`);
		}

		switch (lc(kind)) {
		case 'and':
		case 'or':
		case 'not':
		case 'sub-rule':
			i++;
			continue;
		}

		const target = ruleTarget(parts);
		if (!length(target)) {
			push(issues, `第 ${i + 1} 条分流规则写错了：${line}`);
			i++;
			continue;
		}
		if (!exists(names, target) && !isBuiltin(target))
			push(issues, `规则「${line}」指向了不存在的策略：${target}`);
		i++;
	}

	if (!hasMatch)
		push(issues, '分流规则缺少最后一条兜底规则');
};

export function inspect(remote) {
	if (type(remote) != 'object')
		return { ok: false, error: '面板配置不规范：\n面板下发的不是一份完整配置' };

	const issues = [];
	const names = {};
	const providers = {};

	inspectProxies(remote.proxies, issues, names);
	inspectGroups(remote['proxy-groups'], issues, names);
	if (exists(names, SPEED_GROUP))
		push(issues, `名称「${SPEED_GROUP}」保留给客户端测速，请修改面板中的同名节点或策略组`);
	inspectProviders(remote['rule-providers'], 'rule-providers', issues, providers);
	inspectProviders(remote['proxy-providers'], 'proxy-providers', issues, null);
	inspectRules(remote.rules, issues, names, providers);
	if (exists(remote, 'dns') && type(remote.dns) != 'object')
		push(issues, 'DNS 设置不是一组完整配置');

	if (!length(issues))
		return { ok: true };

	const shown = [];
	let i = 0;
	for (let item in issues) {
		if (i >= 20) {
			push(shown, `另有 ${length(issues) - 20} 项问题未列出`);
			break;
		}
		push(shown, item);
		i++;
	}

	return { ok: false, error: `面板配置不规范：\n${join('\n', shown)}` };
};

export function assemble(remote, cfg, api) {
	const checked = inspect(remote);
	if (!checked.ok)
		return checked;

	const config = { ...remote };

	for (let key, value in fallbacks(cfg))
		if (!exists(config, key))
			config[key] = value;

	const merged = { ...config, ...overrides(cfg, api) };
	merged['proxy-groups'] = [ ...config['proxy-groups'], {
		name: SPEED_GROUP,
		type: 'select',
		hidden: true,
		proxies: map(config.proxies, proxy => proxy.name)
	} ];
	merged.listeners = [{
		name: SPEED_GROUP,
		type: 'mixed',
		listen: '127.0.0.1',
		port: speedPort(cfg.mixedPort),
		udp: false,
		users: [],
		proxy: SPEED_GROUP
	}];

	/* dns 整段归面板，但 listen 会让内核对外开 DNS 口；路由器上改成只监听回环供 dnsmasq 转发。
	   ipv6 跟 LuCI 开关走，不盖掉就落不到配置上 */
	merged.dns = { ...(type(merged.dns) == 'object' ? merged.dns : {}) };
	merged.dns.enable = true;
	merged.dns.listen = `127.0.0.1:${cfg.dnsPort}`;
	merged.dns.ipv6 = cfg.ipv6;

	/* 面板下发的 geox-url 指向 github，而路由器没有随包 geodata，首次启动全靠它下载。
	   只改镜像实际托管的这两个键：geoip / asn 镜像上没有，改过去就是 404 */
	if (length(cfg.geoxBase)) {
		merged['geox-url'] = { ...(type(merged['geox-url']) == 'object' ? merged['geox-url'] : {}) };
		merged['geox-url'].mmdb = `${cfg.geoxBase}/geoip.metadb`;
		merged['geox-url'].geosite = `${cfg.geoxBase}/GeoSite.dat`;
	}

	return { ok: true, config: merged };
};

export function write(runDir, config) {
	ensureDir(runDir);

	const path = `${runDir}/config.json`;
	const previous = readfile(path);

	if (previous != null)
		writefile(`${path}.bak`, previous);

	if (writefile(path, sprintf('%J', config)) == null)
		return { ok: false, error: `无法写入 ${path}` };

	chmod(path, int('600', 8));

	return { ok: true, path };
};

export function rollback(runDir) {
	const previous = readfile(`${runDir}/config.json.bak`);
	return previous != null && writefile(`${runDir}/config.json`, previous) != null;
};

/* procd respawn 不重跑 prepare，切模式只 PATCH 控制面会让内核按磁盘上的旧 mode 起来 */
export function setRunMode(runDir, mode) {
	const config = readJson(`${runDir}/config.json`);
	if (type(config) != 'object' || config.mode == mode)
		return false;

	config.mode = mode;
	return write(runDir, config).ok == true;
};

export function geodataMissing(runDir) {
	return !access(`${runDir}/geoip.metadb`) || !access(`${runDir}/GeoSite.dat`);
};

export function validate(runDir) {
	const config = readJson(`${runDir}/config.json`);
	if (type(config) != 'object')
		return { ok: false, error: '无法读取待校验配置' };

	const path = `${runDir}/.validate-${randomHex(6)}.json`;
	config.profile = { ...config.profile, 'store-fake-ip': false };
	if (!writePrivateJson(path, config))
		return { ok: false, error: '无法写入待校验配置' };

	const cmd = sprintf('%s -t -f %s -d %s 2>&1', shellquote(mihomoBin()), shellquote(path), shellquote(runDir));
	const proc = popen(cmd);

	if (!proc) {
		unlink(path);
		return { ok: false, error: '无法执行 mihomo' };
	}

	const out = proc.read('all') ?? '';
	const code = proc.close();
	unlink(path);

	if (code == 0)
		return { ok: true };

	let reason = '';
	for (let line in split(out, '\n'))
		if (length(trim(line)))
			reason = trim(line);

	return { ok: false, error: length(reason) ? reason : `mihomo -t 退出码 ${code}` };
};

function runRelative(path) {
	let normalized = replace(trim(`${path ?? ''}`), '\\', '/');

	while (index(normalized, '//') >= 0)
		normalized = replace(normalized, '//', '/');

	while (index(normalized, './') == 0)
		normalized = substr(normalized, 2);

	while (index(normalized, '/') == 0)
		normalized = substr(normalized, 1);

	if (!length(normalized) || index(normalized, '..') >= 0)
		return '';

	return normalized;
};

export function runtimeConfig() {
	const cfg = settings();
	const raw = readfile(`${cfg.runDir}/config.json`);
	if (raw != null)
		return { ok: true, text: raw };

	const cache = cached();
	if (cache?.config)
		return { ok: true, text: sprintf('%J', cache.config) };

	return { ok: false, error: '还没有运行配置' };
};

export function ruleProviders() {
	const items = [];
	const providers = cached()?.config?.['rule-providers'];

	if (type(providers) != 'object')
		return items;

	for (let name in providers) {
		const spec = providers[name];
		const rel = runRelative(spec?.path);
		if (!rel)
			continue;
		push(items, {
			name,
			path: rel,
			format: spec.format ?? ''
		});
	}

	return items;
};

export function readRunFile(rel) {
	const safe = runRelative(rel);
	if (!safe)
		return { ok: false, error: '无效路径' };

	const path = `${settings().runDir}/${safe}`;
	if (!access(path))
		return { ok: false, error: '文件不存在' };

	const raw = readfile(path);
	if (raw == null)
		return { ok: false, error: '无法读取' };
	if (index(raw, '\0') >= 0)
		return { ok: false, error: '该文件为二进制规则集，无法以文本查看' };

	return { ok: true, text: raw };
};

export function geoFingerprint(runDir) {
	let out = '';

	for (let name in [ 'geoip.metadb', 'GeoSite.dat', 'ASN.mmdb' ]) {
		const info = stat(`${runDir}/${name}`);
		if (info)
			out += `${name}:${info.size}:${info.mtime};`;
	}

	return out;
};
