'use strict';

import { access, lstat, popen, readfile, realpath, stat, unlink } from 'fs';

import { PROFILE_FILE, STATE_DIR, ROUTING_MARK, TUN_ROUTE_TABLE, TUN_RULE_INDEX, appendNets, creds, ensureDir, mihomoBin, panelDirectNets, randomHex, readJson, settings, sessionBinding, timestamp,
		 ensurePrivateDir, instances, shellquote, writeAtomic, writePrivateJson } from 'ecycloud.common';

export const SPEED_GROUP = 'ecy-speed';
export const NODE_PROVIDER = 'ecy-panel-nodes';
export const PENDING_FILE = `${STATE_DIR}/profile-pending.json`;

export function nodeProviderNames(config) {
	return filter(keys(config?.['proxy-providers'] ?? {}), name => index(name, 'ecy-panel-') == 0);
};

export function nodesOf(config) {
	return config?.['proxy-providers']?.[NODE_PROVIDER]?.payload ?? config?.proxies ?? [];
};

export function membersOf(config, group) {
	const members = [ ...(group.proxies ?? []) ];
	for (let name in (group.use ?? []))
		for (let node in (config?.['proxy-providers']?.[name]?.payload ?? []))
			if (length(node?.name) && node.name != 'ecy-panel-empty')
				push(members, node.name);
	if (type(group.filter) != 'string' || index(group.filter, '`') < 0)
		return members;
	const ordered = [];
	const patterns = map(split(group.filter, '`'), pattern => {
		const exact = substr(pattern, 0, 1) == '^' && substr(pattern, -1) == '$'
			? replace(replace(substr(pattern, 1, length(pattern) - 2), '\\x60', '`'), /\\(.)/g, '$1') : null;
		const nodeFilter = index(pattern, '^(?!(?:') == 0;
		return { exact, nodeFilter, re: exact != null || nodeFilter ? null : regexp(pattern) };
	});
	const fixed = filter(map(patterns, pattern => pattern.exact), name => name != null);
	for (let pattern in patterns) {
		for (let member in members)
			if (!(member in ordered) && (pattern.exact != null ? member == pattern.exact :
			    pattern.nodeFilter ? !(member in fixed) : match(member, pattern.re)))
				push(ordered, member);
	}
	for (let member in members)
		if (!(member in ordered))
			push(ordered, member);
	return ordered;
};

function nodeSignature(config) {
	const copy = { ...config, 'proxy-providers': { ...config['proxy-providers'] } };
	for (let name in nodeProviderNames(config)) {
		copy['proxy-providers'][name] = { ...config['proxy-providers'][name] };
		delete copy['proxy-providers'][name].payload;
	}
	copy['proxy-groups'] = map(config['proxy-groups'], group => {
		const next = { ...group };
		delete next['default-selected'];
		return next;
	});
	return sprintf('%J', copy);
};

export function canUpdateNodes(before, after) {
	return before?.['proxy-providers']?.[NODE_PROVIDER] != null &&
		after?.['proxy-providers']?.[NODE_PROVIDER] != null && nodeSignature(before) == nodeSignature(after);
};

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

export function authorized(saved, margin) {
	const issued = timestamp(saved?.offline_authorization?.issued_at);
	const until = timestamp(saved?.offline_authorization?.valid_until);
	const binding = sessionBinding();
	return length(binding) > 0 && saved?.binding == binding && issued > 0 &&
		issued <= time() && until > issued && until > time() + +(margin ?? 0);
};

export function cached(pending) {
	const saved = readJson(pending ? PENDING_FILE : PROFILE_FILE);
	if (type(saved) != 'object')
		return null;

	const account = lc(trim(creds().email ?? ''));
	return length(account) && saved.account == account && authorized(saved) ? saved : null;
};

export function store(remote, pending) {
	const binding = sessionBinding();
	if (!length(binding) || !authorized({ ...remote, binding }))
		return false;
	const ok = writePrivateJson(pending ? PENDING_FILE : PROFILE_FILE, {
		...(pending ? { pending_pid: +(instances().core?.pid ?? 0) } : {}),
		account: lc(trim(creds().email ?? '')),
		binding,
		offline_authorization: remote.offline_authorization,
		revision: remote.revision ?? '',
		locale: remote.locale ?? 'zh-CN',
		config: remote.config,
		node_labels: remote.node_labels ?? {},
		group_labels: remote.group_labels ?? {},
		group_icons: type(remote.group_icons) == 'object' ? remote.group_icons : null,
		flag_regex: type(remote.flag_regex) == 'string' ? remote.flag_regex : '',
		fetched_at: time()
	});
	if (ok && !pending) {
		unlink(PENDING_FILE);
		system('trap "" HUP; /usr/libexec/ecycloud-ctl icons >/dev/null 2>&1 &');
	}
	return ok;
};

function tunExcludes(cfg) {
	const extra = [];

	for (let net in (cfg.tunExclude ?? []))
		push(extra, net);
	for (let net in (cfg.bypass ?? []))
		push(extra, net);

	return appendNets(EXCLUDED_ROUTES, [ ...extra, ...panelDirectNets() ]);
};

function tunSection(cfg) {
	return {
		enable: cfg.enabled && cfg.mode == 'tun',
		stack: cfg.tunStack,
		device: cfg.tunDevice,
		'auto-route': true,
		'iproute2-table-index': TUN_ROUTE_TABLE,
		'iproute2-rule-index': TUN_RULE_INDEX,
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
		'ss-config': '',
		'vmess-config': '',
		'tuic-server': { enable: false },
		'iptables': { enable: false },
		listeners: [],
		tunnels: [],
		'log-level': 'info',
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

function inspectGroups(raw, issues, names, providers) {
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

		if (item.proxies != null && type(item.proxies) != 'array')
			push(issues, `策略组「${name}」的成员格式不对`);
		if (item.use != null && type(item.use) != 'array')
			push(issues, `策略组「${name}」的节点订阅格式不对`);
		if (!length(item.proxies) && !length(item.use))
			push(issues, `策略组「${length(name) ? name : itemLabel(i)}」没有成员`);
		else if (type(item.proxies) == 'array')
			push(groups, { index: i, name, members: item.proxies });
		for (let provider in (type(item.use) == 'array' ? item.use : []))
			if (type(provider) != 'string' || !exists(providers, provider))
				push(issues, `策略组「${name}」的节点订阅「${provider}」不存在`);
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

function runRelative(path) {
	if (type(path) != 'string' || !length(path) || index(path, '\0') >= 0 || substr(path, 0, 1) == '/' || match(path, /[\\:[:cntrl:]]/))
		return '';
	const parts = [];
	for (let part in split(path, '/')) {
		if (part == '.')
			continue;
		if (!length(part) || part == '..' || match(part, /[. ]$/) || match(lc(part), /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)/))
			return '';
		push(parts, part);
	}
	return join('/', parts);
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
		if (section == 'proxy-providers' && index(name, 'ecy-panel-') == 0 &&
		    ((name != NODE_PROVIDER && !match(name, /^ecy-panel-[a-f0-9]{64}$/)) ||
		     kind != 'file' || spec.path != `${name}.json` || type(spec.payload) != 'array' || !length(spec.payload)))
			push(issues, `节点订阅「${label}」必须使用有效的客户端本地文件格式`);
		if (!length(kind))
			push(issues, `${providerTitle(section)}「${label}」没有类型`);
		if (section == 'rule-providers' && !length(trim(`${spec.path ?? ''}`)))
			push(issues, `规则集「${label}」没有保存路径`);
		if (exists(spec, 'path')) {
			const path = runRelative(spec.path);
			if (!length(path) || match(lc(split(path, '/')[0]), /^(config\.json|config\.check\.json|cache\.db|proxy-snapshot\.json|geoip\.metadb|geosite\.dat|geoip\.dat|asn\.mmdb|bundlemrs\.7z)(\.|$)|^\.validate-/))
				push(issues, `「${label}」的保存路径必须位于运行目录内，且不能覆盖客户端文件`);
		}
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

	const nodeProviders = {};
	inspectProxies(nodesOf(remote), issues, names);
	inspectProviders(remote['proxy-providers'], 'proxy-providers', issues, nodeProviders);
	inspectGroups(remote['proxy-groups'], issues, names, nodeProviders);
	if (exists(names, SPEED_GROUP))
		push(issues, `名称「${SPEED_GROUP}」保留给客户端测速，请修改面板中的同名节点或策略组`);
	inspectProviders(remote['rule-providers'], 'rule-providers', issues, providers);
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

export function assemble(remote, cfg, api, selectorDefaults) {
	const checked = inspect(remote);
	if (!checked.ok)
		return checked;
	if (!length(api?.speed))
		return { ok: false, error: '测速入站口令缺失，不能生成配置' };

	const config = { ...remote };

	for (let key, value in fallbacks(cfg))
		if (!exists(config, key))
			config[key] = value;

	const merged = { ...config, ...overrides(cfg, api) };
	if (type(merged.ntp) == 'object' && exists(merged.ntp, 'write-to-system'))
		merged.ntp = { ...merged.ntp, 'write-to-system': false };
	merged['proxy-groups'] = [ ...config['proxy-groups'], {
		name: SPEED_GROUP,
		type: 'select',
		hidden: true,
		...(config['proxy-providers']?.[NODE_PROVIDER] != null
			? { use: [ NODE_PROVIDER ] } : { proxies: map(config.proxies, proxy => proxy.name) })
	} ];
	let restored = false;
	merged['proxy-groups'] = map(merged['proxy-groups'], group => {
		const name = selectorDefaults?.[group.name];
		if (group.type != 'select' || !length(name) || !(name in membersOf(config, group)))
			return group;
		restored = true;
		return { ...group, 'default-selected': name };
	});
	if (restored)
		merged.profile['store-selected'] = false;
	merged.listeners = [{
		name: SPEED_GROUP,
		type: 'mixed',
		listen: '127.0.0.1',
		port: speedPort(cfg.mixedPort),
		udp: false,
		// 该入站界面上不存在却常驻回环，proxy 字段绕开 rules；口令随 api.speed 随机
		users: [ { username: SPEED_GROUP, password: api.speed } ],
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

	if (previous != null && !writeAtomic(`${path}.bak`, previous))
		return { ok: false, error: `无法备份 ${path}` };

	if (!writePrivateJson(path, config))
		return { ok: false, error: `无法写入 ${path}` };

	return { ok: true, path };
};

export function writeNodeProviders(runDir, config) {
	const names = nodeProviderNames(config);
	if (!length(names))
		return { ok: true };
	ensureDir(runDir);
	if (lstat(runDir)?.type != 'directory')
		return { ok: false, error: '节点保存目录必须是普通目录' };
	ensurePrivateDir(runDir);
	for (let name in names) {
		const spec = config['proxy-providers'][name];
		if ((name != NODE_PROVIDER && !match(name, /^ecy-panel-[a-f0-9]{64}$/)) ||
		    spec?.type != 'file' || spec.path != `${name}.json` || type(spec.payload) != 'array' || !length(spec.payload))
			return { ok: false, error: `节点订阅「${name}」的本地文件格式无效` };
		const path = `${runDir}/${spec.path}`;
		const info = lstat(path);
		if (info != null && (info.type != 'file' || info.nlink != 1))
			return { ok: false, error: `节点订阅「${name}」的保存路径不是独立普通文件` };
		const text = sprintf('%J', { proxies: spec.payload });
		if (length(text) > 8 * 1024 * 1024)
			return { ok: false, error: `节点订阅「${name}」超过 8 MiB` };
		if (readfile(path) != text && !writeAtomic(path, text))
			return { ok: false, error: `无法保存节点订阅「${name}」` };
	}
	return { ok: true };
};

export function rollback(runDir) {
	const previous = readfile(`${runDir}/config.json.bak`);
	return previous != null && writeNodeProviders(runDir, json(previous)).ok && writeAtomic(`${runDir}/config.json`, previous);
};

/* procd respawn 不重跑 prepare，切模式只 PATCH 控制面会让内核按磁盘上的旧 mode 起来 */
export function setRunMode(runDir, mode) {
	const config = readJson(`${runDir}/config.json`);
	if (type(config) != 'object' || config.mode == mode)
		return false;

	config.mode = mode;
	return write(runDir, config).ok == true;
};

export function setRunTun(runDir, enabled) {
	const config = readJson(`${runDir}/config.json`);
	if (type(config?.tun) != 'object')
		return false;
	config.tun.enable = enabled;
	return writeAtomic(`${runDir}/config.json`, sprintf('%J', config));
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
	for (let name in nodeProviderNames(config))
		config['proxy-providers'][name] = { ...config['proxy-providers'][name], type: 'inline' };
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

	const root = realpath(settings().runDir);
	const path = realpath(`${settings().runDir}/${safe}`);
	if (!root || !path)
		return { ok: false, error: '文件不存在' };
	if (index(path, `${root}/`) != 0)
		return { ok: false, error: '无效路径' };
	const info = stat(path);
	if (info?.type != 'file' || info.size > 8 * 1024 * 1024)
		return { ok: false, error: '只能查看不超过 8 MiB 的普通文件' };
	const raw = readfile(path, 8 * 1024 * 1024 + 1);
	if (raw == null)
		return { ok: false, error: '无法读取' };
	if (length(raw) > 8 * 1024 * 1024)
		return { ok: false, error: '文件超过 8 MiB' };
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
