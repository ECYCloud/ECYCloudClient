'use strict';

import { access, lstat, popen, readfile, realpath, stat, unlink } from 'fs';

import { PROFILE_FILE, STATE_DIR, ROUTING_MARK, TUN_ROUTE_TABLE, TUN_RULE_INDEX, appendNets, creds, ensureDir, lanDevices, mihomoBin, randomHex, readJson, settings, sessionBinding, timestamp,
		 ensurePrivateDir, instances, shellquote, writeAtomic, writePrivateJson } from 'ecycloud.common';

export const SPEED_GROUP = 'ecy-speed';
export const NODE_PROVIDER = 'ecy-panel-nodes';
export const PENDING_FILE = `${STATE_DIR}/profile-pending.json`;

export function nodeProviderNames(config) {
	return filter(keys(config?.['proxy-providers'] ?? {}), name => index(name, 'ecy-panel-') == 0);
};

/* config.json 保留 payload 供校验、回滚与节点列表使用；内核启动读 kernel.json：节点已写成各自的文件，
   payload 留给内核只会被当作后备节点再解析一遍 */
export function kernelConfig(config) {
	if (type(config) != 'object' || type(config['proxy-providers']) != 'object')
		return config;
	const providers = { ...config['proxy-providers'] };
	for (let name in nodeProviderNames(config)) {
		if (type(providers[name]) != 'object')
			continue;
		const spec = {};
		for (let key, value in providers[name])
			if (lc(key) != 'payload')
				spec[key] = value;
		providers[name] = spec;
	}
	return { ...config, 'proxy-providers': providers };
};

export function writeKernel(runDir, config) {
	const path = `${runDir}/kernel.json`;
	const text = sprintf('%J', kernelConfig(config));
	if (readfile(path) != text && !writeAtomic(path, text))
		return { ok: false, error: `无法写入 ${path}` };
	return { ok: true };
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
		// filter 是 mihomo 的 regexp2 语法（常带 (?i) 前缀）：解析不了的写法只放弃排序，不能让分组列表报错
		const ignoreCase = substr(pattern, 0, 4) == '(?i)';
		let re = null;
		if (exact == null && !nodeFilter)
			try { re = regexp(ignoreCase ? substr(pattern, 4) : pattern, ignoreCase ? 'i' : ''); } catch (e) {}
		return { exact, nodeFilter, re };
	});
	const fixed = filter(map(patterns, pattern => pattern.exact), name => name != null);
	for (let pattern in patterns) {
		for (let member in members)
			if (!(member in ordered) && (pattern.exact != null ? member == pattern.exact :
			    pattern.nodeFilter ? !(member in fixed) : pattern.re != null && match(member, pattern.re)))
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

/* 面板签发时间取整到秒，本机校时也有误差：只对签发一侧留 10 秒，到期一侧不放宽（三端同值） */
const ISSUED_SKEW = 10;

export function authorized(saved, margin) {
	const issued = timestamp(saved?.offline_authorization?.issued_at);
	const until = timestamp(saved?.offline_authorization?.valid_until);
	const binding = sessionBinding();
	return length(binding) > 0 && saved?.binding == binding && issued > 0 &&
		issued <= time() + ISSUED_SKEW && until > issued && until > time() + +(margin ?? 0);
};

/* 响应头 profile-update-interval：1～8760 的正整数小时，其余视为未下发 */
function updateIntervalHours(value) {
	const m = match(`${value ?? ''}`, /^\s*[+]?([0-9]+)\s*$/);
	const hours = m ? +m[1] : 0;
	return hours >= 1 && hours <= 8760 ? hours : null;
};

/* 距面板签发本份缓存满更新间隔（未下发按 24 小时）即到期 */
export function updateDue(saved) {
	const issued = timestamp(saved?.offline_authorization?.issued_at);
	return !issued || time() - issued >= (updateIntervalHours(saved?.update_interval_hours) ?? 24) * 3600;
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
		update_interval_hours: updateIntervalHours(remote.update_interval_hours),
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

	return appendNets(EXCLUDED_ROUTES, extra);
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
		/* 列表为空时 sing-tun 接管全部入站接口（含 WAN 侧）；lo 即路由器自身流量，未列入时 sing-tun 在其 iif lo 规则之前就交回主表 */
		'include-interface': cfg.routerProxy ? [ ...lanDevices(), 'lo' ] : lanDevices(),
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

// 组网类出站会让内核加入外部 P2P 网络、开监听口或充当出口节点，等于替用户开了看不见的入站
const MESH_TYPES = { easytier: true, tailscale: true, zerotier: true };

function inspectMeshNodes(remote, issues) {
	const lists = [ remote.proxies ];
	for (let name, spec in (type(remote['proxy-providers']) == 'object' ? remote['proxy-providers'] : {}))
		push(lists, spec?.payload);
	for (let list in lists) {
		if (type(list) != 'array')
			continue;
		for (let item in list) {
			const kind = lc(trim(`${item?.type ?? ''}`));
			if (type(item) == 'object' && MESH_TYPES[kind])
				push(issues, `节点「${item.name ?? ''}」是组网类型（${kind}），会让内核加入外部网络，客户端不支持`);
		}
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

/* 客户端自己的运行文件：规则集不得覆盖，规则文件查看也不得读出（config.json 含控制密钥） */
function clientFile(path) {
	return match(lc(split(path, '/')[0]), /^(config\.json|kernel\.json|config\.check\.json|cache\.db|proxy-snapshot\.json|geoip\.metadb|geosite\.dat|geoip\.dat|asn\.mmdb|bundlemrs\.7z)(\.|$)|^\.validate-/);
};

function httpsUrl(value) {
	const url = trim(`${value ?? ''}`);
	return !length(url) || match(lc(url), /^https:\/\//) != null;
};

/* mihomo 解码 provider 时找不到同名键就按不分大小写匹配（common/structure/structure.go），安全检查须覆盖每种写法 */
function fieldValues(spec, name) {
	return map(filter(keys(spec), key => lc(key) == name), key => spec[key]);
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
		if (length(filter(fieldValues(spec, 'path'), value => {
			const path = runRelative(value);
			return !length(path) || clientFile(path);
		})))
			push(issues, `「${label}」的保存路径必须位于运行目录内，且不能覆盖客户端文件`);
		if (kind == 'http' && !length(trim(`${spec.url ?? ''}`)))
			push(issues, `${providerTitle(section)}「${label}」是在线下载，但没有地址`);
		else if (length(filter(fieldValues(spec, 'url'), value => !httpsUrl(value))))
			push(issues, `${providerTitle(section)}「${label}」的下载地址必须使用 https`);
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
	inspectMeshNodes(remote, issues);
	inspectGroups(remote['proxy-groups'], issues, names, nodeProviders);
	if (exists(names, SPEED_GROUP))
		push(issues, `名称「${SPEED_GROUP}」保留给客户端测速，请修改面板中的同名节点或策略组`);
	inspectProviders(remote['rule-providers'], 'rule-providers', issues, providers);
	inspectRules(remote.rules, issues, names, providers);
	if (exists(remote, 'dns') && type(remote.dns) != 'object')
		push(issues, 'DNS 设置不是一组完整配置');
	for (let key, url in (type(remote['geox-url']) == 'object' ? remote['geox-url'] : {}))
		if (!httpsUrl(url))
			push(issues, `geox-url「${key}」必须使用 https`);

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

function proxyChinaRules(rules) {
	let target = null;
	for (let rule in rules) {
		const fields = split(rule, ',');
		if (length(fields) >= 2 && uc(trim(fields[0])) == 'MATCH') {
			target = trim(fields[1]);
			break;
		}
	}
	if (target == null || uc(target) == 'DIRECT')
		return rules;
	return map(rules, rule => {
		const fields = map(split(rule, ','), field => trim(field));
		if (length(fields) < 3 || !(uc(fields[0]) in [ 'GEOIP', 'GEOSITE' ]) || lc(fields[1]) != 'cn' || uc(fields[2]) != 'DIRECT')
			return rule;
		fields[2] = target;
		return join(',', fields);
	});
}

export function assemble(remote, cfg, api, selectorDefaults) {
	const checked = inspect(remote);
	if (!checked.ok)
		return checked;
	if (!length(api?.speed))
		return { ok: false, error: '测速入站口令缺失，不能生成配置' };
	if (!httpsUrl(cfg.geoxBase))
		return { ok: false, error: 'GeoData 镜像地址必须使用 https' };

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
	/* allow-lan 关闭时内核的 tproxy-port 只绑 127.0.0.1，没有 IPv6 监听：
	   不补这一口，LAN 的 IPv6 流量会整段绕过代理直连出去 */
	if (cfg.mode != 'tun' && cfg.ipv6 && !cfg.allowLan)
		push(merged.listeners, { name: 'ecy-tproxy6', type: 'tproxy', listen: '::1', port: cfg.tproxyPort, udp: true });

	/* dns 整段归面板，但 listen 会让内核对外开 DNS 口；路由器上改成只监听回环供 dnsmasq 转发。
	   ipv6 跟 LuCI 开关走，不盖掉就落不到配置上 */
	merged.dns = { ...(type(merged.dns) == 'object' ? merged.dns : {}) };
	merged.dns.enable = true;
	merged.dns.listen = `127.0.0.1:${cfg.dnsPort}`;
	merged.dns.ipv6 = cfg.ipv6;
	if (cfg.region == 'overseas')
		merged.rules = proxyChinaRules(merged.rules);

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

	const kernel = writeKernel(runDir, config);
	return kernel.ok ? { ok: true, path } : kernel;
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
	return previous != null && writeNodeProviders(runDir, json(previous)).ok && writeAtomic(`${runDir}/config.json`, previous) &&
		writeKernel(runDir, json(previous)).ok;
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
	return writeAtomic(`${runDir}/config.json`, sprintf('%J', config)) && writeKernel(runDir, config).ok;
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

function maskCredentials(value) {
	if (type(value) == 'array')
		for (let item in value)
			maskCredentials(item);
	else if (type(value) == 'object')
		for (let key in value) {
			if (key in [ 'uuid', 'password', 'auth', 'auth-str', 'obfs-password', 'private-key', 'pre-shared-key', 'public-key', 'short-id', 'psk', 'token' ] && type(value[key]) == 'string' && length(value[key]))
				value[key] = '******';
			else
				maskCredentials(value[key]);
		}
};

/* 运行配置只供查看：控制面 secret、本设备的节点凭据与测速入站口令都不得出现在界面上 */
export function maskRuntime(config) {
	if (type(config) != 'object')
		return null;
	if (exists(config, 'secret'))
		config.secret = '******';
	maskCredentials(config.proxies);
	maskCredentials(config.listeners);
	for (let name in (type(config['proxy-providers']) == 'object' ? config['proxy-providers'] : {}))
		maskCredentials(config['proxy-providers'][name]?.payload);
	return sprintf('%J', config);
};

export function runtimeConfig() {
	const cfg = settings();
	const config = readJson(`${cfg.runDir}/config.json`) ?? cached()?.config;
	/* 节点只在 ecy-panel-nodes 下列一次，各组节点订阅不再重复列出 */
	const view = kernelConfig(config);
	if (type(view?.['proxy-providers']?.[NODE_PROVIDER]) == 'object')
		view['proxy-providers'][NODE_PROVIDER] = config['proxy-providers'][NODE_PROVIDER];
	const text = maskRuntime(view);
	if (text != null)
		return { ok: true, text };

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
	// ecy-panel-*.json 是插件写入的节点文件，含本设备节点凭据原文，只供内核读取
	if (!safe || clientFile(safe) || index(lc(split(safe, '/')[0]), 'ecy-panel-') == 0)
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

	return { ok: true, text: raw, info };
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
