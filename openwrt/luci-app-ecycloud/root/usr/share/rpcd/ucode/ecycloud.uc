'use strict';

import { access, popen } from 'fs';
import { cursor } from 'uci';

import * as clash from 'ecycloud.clash';
import * as icons from 'ecycloud.icons';
import * as network from 'ecycloud.network';
import * as panel from 'ecycloud.panel';
import * as profile from 'ecycloud.profile';

import { build, clearKicked, coreRunning, instances, kickReason, lanDevices, log, origins,
		 settings, state, wasKicked } from 'ecycloud.common';
import * as release from 'ecycloud.release';
import * as service from 'ecycloud.service';
import * as statistics from 'ecycloud.statistics';

const INIT = '/etc/init.d/ecycloud';

function background(command) {
	return system(`${command} >/dev/null 2>&1 &`) == 0;
};

function toggle(enabled) {
	const uci = cursor();
	uci.set('ecycloud', 'config', 'enabled', enabled ? '1' : '0');
	uci.commit('ecycloud');
};

function accountView(data) {
	const acct = data ?? panel.account();
	if (!acct)
		return {};

	return {
		email: acct.email ?? '',
		upload: +(acct.upload ?? 0),
		download: +(acct.download ?? 0),
		transfer_enable: +(acct.transfer_enable ?? 0),
		last_day_t: +(acct.last_day_t ?? 0),
		expire_in: acct.expire_in ?? '',
		plan: acct.plan?.name ?? '',
		plan_days: +(acct.plan?.remaining_days ?? 0),
		last_ss_time: acct.last_ss_time ?? '',
		traffic_reset: acct.traffic_reset ?? '',
		node_connector: +(acct.node_connector ?? 0),
		enable_checkin: exists(acct, 'enable_checkin') ? acct.enable_checkin == true : false,
		able_to_checkin: acct.able_to_checkin == true,
		checkin_min: +(acct.checkin_min ?? 1),
		checkin_max: +(acct.checkin_max ?? 300),
		last_check_in_time: acct.last_check_in_time ?? '',
		online_client_count: +(acct.online_client_count ?? 0),
		online_client_self: acct.online_client_self == true,
		device_kick_notice: acct.device_kick_notice == true,
		device_kick_reason: acct.device_kick_reason ?? ''
	};
};

function proxyServers(cache) {
	const seen = {};
	const list = [];

	for (let proxy in profile.nodesOf(cache?.config)) {
		const server = lc(trim(`${proxy?.server ?? ''}`));
		if (!length(server) || seen[server])
			continue;
		seen[server] = true;
		push(list, server);
	}

	return list;
};

function statusView() {
	const session = panel.session();
	const base = {
		version: build().version ?? '',
		site: origins().site,
		error: state().error ?? '',
		session
	};

	if (!session.logged_in)
		return base;

	/* 已登录后的扩展字段失败不得整段 RPC 失败：LuCI expect 会把 ubus 错误收成 {}，界面当成未登录 */
	try {
		const cfg = settings();
		const st = state();
		const cache = profile.cached();
		const running = coreRunning();
		const snapshot = running ? clash.connections() : { ok: false };
		const version = running ? clash.version() : { ok: false };
		const record = network.applied();
		const acct = accountView();
		const stats = statistics.read();
		let mainGroup = '';
		for (let rule in (cache?.config?.rules ?? [])) {
			const parts = split(`${rule}`, ',');
			if (length(parts) >= 2 && uc(trim(parts[0])) == 'MATCH') {
				mainGroup = trim(parts[1]);
				break;
			}
		}

		return {
			enabled: cfg.enabled,
			running,
			mode: cfg.mode,
			route_mode: cfg.routeMode,
			dns_hijack: cfg.dnsHijack,
			stage: st.stage,
			message: st.message,
			error: st.error,
			updated: +st.updated,
			connected_at: +(st.connected_at ?? 0),
			statistics: { at: stats.at, up: stats.up, down: stats.down, total_up: stats.total_up,
				total_down: stats.total_down, rank: stats.rank, today: stats.today, yesterday: stats.yesterday },
			updates: release.cached(),
			update_tasks: service.updateTasks(),
			provider_progress: running && st.stage == 'starting' ? clash.providerProgress() : {},
			version: build().version ?? '',
			kernel_version: version.ok
				? (release.kernelVersion(`${version.data?.version ?? ''}`) || `${version.data?.version ?? ''}`)
				: release.probeKernel(),
			site: origins().site,
			session,
			account: acct,
			device_kicked: wasKicked() == true,
			device_kick_reason: kickReason() || (acct.device_kick_reason ?? ''),
			profile: {
				main_group: mainGroup,
				revision: cache?.revision ?? '',
				locale: cache?.locale ?? 'zh-CN',
				fetched_at: +(cache?.fetched_at ?? 0),
				nodes: length(profile.nodesOf(cache?.config)),
				servers: proxyServers(cache)
			},
			memory: running ? clash.memoryUsage() : 0,
			traffic: {
				connections: length(snapshot.data?.connections ?? []),
				upload: +(snapshot.data?.uploadTotal ?? 0),
				download: +(snapshot.data?.downloadTotal ?? 0)
			},
			lan: lanDevices(),
			network_applied: record != null && record.active != false,
			dns_applied: record?.active != false && length(record?.dnsmasq) > 0,
			auto_connect: cfg.autoConnect == true
		};
	} catch (e) {
		log('err', `status failed: ${e}`);
		return base;
	}
};

function isNodeIdTag(name) {
	return match(`${name ?? ''}`, /^node-[0-9]+$/) != null;
};

function labeledName(name, labels) {
	const label = labels[name] ?? name;
	return isNodeIdTag(label) ? '' : label;
};

/* Dart String.trim() 认的空白：Unicode White_Space 加 BOM */
const SPACES = [ ' ', '\t', '\n', '\v', '\f', '\r', chr(0xC2, 0x85), chr(0xC2, 0xA0), chr(0xE1, 0x9A, 0x80),
	...map([ 0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0xA8, 0xA9, 0xAF ], byte => chr(0xE2, 0x80, byte)),
	chr(0xE2, 0x81, 0x9F), chr(0xE3, 0x80, 0x80), chr(0xEF, 0xBB, 0xBF) ];

function trimSpaces(text) {
	let start = 0;
	let end = length(text);
	for (let moved = true; moved; ) {
		moved = false;
		for (let space in SPACES) {
			const size = length(space);
			if (end - start >= size && substr(text, start, size) == space) {
				start += size;
				moved = true;
			}
			if (end - start >= size && substr(text, end - size, size) == space) {
				end -= size;
				moved = true;
			}
		}
	}
	return substr(text, start, end - start);
};

/* 节点页对齐 node_labels.dart 的 displayName（国旗照常保留）；连接链路、日志与运行配置同 fullName，不去空白 */
function shownName(name, labels) {
	const label = labeledName(name, labels);
	const trimmed = type(label) == 'string' ? trimSpaces(label) : '';
	return length(trimmed) ? trimmed : label;
};

function labeledList(names, labels) {
	const out = [];

	for (let name in names)
		push(out, labeledName(name, labels));

	return out;
};

/* 对齐 node_labels.dart 的 [\p{L}\p{N}_-] 边界：ucode 只能按字节判断，非 ASCII 字符除这些标点、符号与表情区段外都按字母算 */
const SEPARATORS = [ [ 0x80, 0xBF ], [ 0x300, 0x36F ], [ 0x2000, 0x2BFF ], [ 0x3000, 0x303F ], [ 0xFE00, 0xFE6F ],
	[ 0xFF00, 0xFF0F ], [ 0xFF1A, 0xFF20 ], [ 0xFF3B, 0xFF40 ], [ 0xFF5B, 0xFF65 ], [ 0x1F000, 0x1FBFF ] ];

function wordAt(text, at) {
	while (at > 0 && (ord(text, at) & 0xC0) == 0x80)
		at--;
	let code = ord(text, at);
	if (code == null)
		return false;
	if (code < 0x80)
		return match(chr(code), /[A-Za-z0-9_-]/) != null;
	const size = code >= 0xF0 ? 4 : code >= 0xE0 ? 3 : 2;
	code &= 0x7F >> size;
	for (let i = 1; i < size; i++)
		code = code << 6 | ord(text, at + i) & 0x3F;
	return !length(filter(SEPARATORS, range => code >= range[0] && code <= range[1]));
};

function replaceWord(text, key, value) {
	const parts = split(text, key);
	let out = parts[0];
	for (let i = 1; i < length(parts); i++) {
		const before = length(parts[i - 1]) || i == 1 ? parts[i - 1] : key;
		const after = length(parts[i]) || i == length(parts) - 1 ? parts[i] : key;
		out += (wordAt(before, length(before) - 1) || wordAt(after, 0) ? key : value) + parts[i];
	}
	return out;
};

function utf16Length(text) {
	let units = 0;
	for (let i = 0; i < length(text); i++) {
		const byte = ord(text, i);
		units += (byte & 0xC0) == 0x80 ? 0 : byte >= 0xF0 ? 2 : 1;
	}
	return units;
};

function labelEntries(labels) {
	const entries = [];
	for (let key in labels) {
		const label = labeledName(key, labels);
		if (length(key) && label != key)
			push(entries, [ key, label, utf16Length(key), length(entries) ]);
	}
	/* 换上的显示名会被后面的标识接着替换，顺序须与 node_labels.dart 一致：按 Dart 字符串长度（UTF-16）从长到短，同长保持原顺序 */
	return sort(entries, (a, b) => b[2] - a[2] || a[3] - b[3]);
};

/* 等价于 node_labels.dart 的 (?<![\w-])node-\d+(?![\w-])：整段 [A-Za-z0-9_-] 恰好是 node-数字 才删 */
function stripNodeIds(text) {
	return replace(text, /[A-Za-z0-9_-]*node-[0-9]+[A-Za-z0-9_-]*/g, word => match(word, /^node-[0-9]+$/) ? '' : word);
};

function annotateLabels(text, labels) {
	if (!length(text))
		return text;

	let out = text;
	for (let entry in labelEntries(labels))
		if (index(out, entry[0]) >= 0)
			out = replaceWord(out, entry[0], entry[1]);

	return stripNodeIds(out);
};

function annotateRuntime(text, labels) {
	let out = text;
	for (let entry in labelEntries(labels)) {
		const shown = replace(replace(entry[1], '\\', '\\\\'), '"', '\\"');
		for (let edge in [ [ '"', '"' ], [ ',', '"' ], [ ',', ',' ] ])
			out = replace(out, edge[0] + entry[0] + edge[1], () => edge[0] + shown + edge[1]);
	}
	return stripNodeIds(out);
};

/* 键是 mihomo 配置里的类型名（ss / vless），查表前统一小写：内核 Clash API 给的是
   AdapterType.String()（Shadowsocks / Vless），两个来源必须归一，否则未连接与连上后标签会跳 */
const PROXY_TYPES = {
	direct: 'Direct',
	reject: 'Reject',
	rematch: 'Rematch',
	dns: 'DNS',
	ss: 'Shadowsocks',
	ssr: 'ShadowsocksR',
	snell: 'Snell',
	socks5: 'SOCKS5',
	http: 'HTTP',
	vmess: 'VMess',
	vless: 'VLESS',
	trojan: 'Trojan',
	hysteria: 'Hysteria',
	hysteria2: 'Hysteria2',
	wireguard: 'WireGuard',
	tuic: 'TUIC',
	ssh: 'SSH',
	mieru: 'Mieru',
	anytls: 'AnyTLS',
	sudoku: 'Sudoku',
	masque: 'MASQUE',
	trusttunnel: 'TrustTunnel',
	shadowquic: 'ShadowQuic',
	openvpn: 'OpenVPN',
	tailscale: 'Tailscale',
	'gost-relay': 'GostRelay',
	select: 'Selector',
	'url-test': 'URLTest',
	fallback: 'Fallback',
	'load-balance': 'LoadBalance',
	relay: 'Relay'
};

function proxyType(value) {
	return PROXY_TYPES[lc(`${value ?? ''}`)] ?? (value ?? '');
};

function proxyTls(cfg) {
	if (length(cfg['reality-opts']))
		return 'REALITY';
	if (cfg.tls)
		return 'TLS';

	/* clash 段里 hysteria / tuic / anytls 不写 tls: true，但协议本身就是 TLS */
	switch (lc(`${cfg.type ?? ''}`)) {
	case 'hysteria':
	case 'hysteria2':
	case 'tuic':
	case 'anytls':
		return 'TLS';
	}

	return '';
};

function flagOn(value) {
	return value == true || value == 1 || value == '1' || value == 'true';
};

function udpTag(live, node, cfg, nested) {
	if (nested)
		return '';

	live = live ?? {};
	node = node ?? {};
	cfg = cfg ?? {};

	if (flagOn(live.xudp) || flagOn(node.xudp) || flagOn(cfg.xudp) || cfg['packet-encoding'] == 'xudp')
		return 'XUDP';
	if (flagOn(live.udp) || flagOn(node.udp) || flagOn(cfg.udp))
		return 'UDP';

	return '';
};

function resolveLeaf(proxies, name) {
	let current = name;

	for (let hop = 0; hop < 8; hop++) {
		const entry = proxies[current];
		if (type(entry?.all) != 'array' || !length(entry.now))
			break;
		current = entry.now;
	}

	return current;
};

function annotateGroups(view, job, speed) {
	const groups = view.groups ?? [];
	const pending = {};

	for (let name in (job.queue ?? []))
		pending[name] = true;
	for (let name in (job.testing ?? []))
		pending[name] = true;

	const failed = {};
	for (let name in (job.failed ?? []))
		failed[name] = true;

	const testingGroups = type(job.groups) == 'object' ? job.groups : {};
	const speedPending = {};
	const speedFailed = {};
	const speedValues = type(speed.speeds) == 'object' ? speed.speeds : {};
	const speedGroups = type(speed.groups) == 'object' ? speed.groups : {};

	for (let name in (speed.queue ?? []))
		speedPending[name] = true;
	for (let name in (speed.testing ?? []))
		speedPending[name] = true;
	for (let name in (speed.failed ?? []))
		speedFailed[name] = true;

	for (let group in groups) {
		for (let member in (group.members ?? [])) {
			const leaf = length(member.via) ? member.via : member.name;
			member.testing = pending[leaf] == true;
			member.failed = failed[leaf] == true && !(member.delay > 0);
			member.speed = +(speedValues[leaf] ?? 0);
			member.speed_testing = speedPending[leaf] == true;
			member.speed_failed = speedFailed[leaf] == true && !(member.speed > 0);
		}

		let testing = false;
		const leaves = testingGroups[group.name];
		if (type(leaves) == 'array') {
			for (let name in leaves) {
				if (pending[name]) {
					testing = true;
					break;
				}
			}
		}

		let speedTesting = false;
		const speedLeaves = speedGroups[group.name];
		if (type(speedLeaves) == 'array') {
			for (let name in speedLeaves) {
				if (speedPending[name]) {
					speedTesting = true;
					break;
				}
			}
		}

		group.testing = testing || index(job.reselect ?? [], group.name) >= 0;
		group.speed_testing = speedTesting;
	}

	return {
		groups,
		flag_regex: view.flag_regex ?? '',
		testing: service.delayActive() || length(pending) > 0
	};
};

function resolveCacheLeaf(name, membersOf, nested, snap) {
	let current = name;

	for (let hop = 0; hop < 8; hop++) {
		if (!(current in nested))
			return current;
		const now = snap[current];
		if (length(now)) {
			current = now;
			continue;
		}
		const first = (membersOf[current] ?? [])[0];
		if (!length(first) || first == current)
			return current;
		current = first;
	}

	return current;
};

function collectLeavesFromCache(groupName) {
	const cache = profile.cached();
	const nested = {};
	const membersOf = {};
	let groupType = '';

	for (let group in (cache?.config?.['proxy-groups'] ?? [])) {
		if (!length(group?.name))
			continue;
		membersOf[group.name] = profile.membersOf(cache.config, group);
		nested[group.name] = proxyType(group.type ?? '');
		if (group.name == groupName)
			groupType = nested[group.name];
	}

	const snap = service.selectors();
	const names = [];
	const seen = {};

	for (let member in (membersOf[groupName] ?? [])) {
		const leaf = resolveCacheLeaf(member, membersOf, nested, snap);
		if (!leaf || seen[leaf])
			continue;
		seen[leaf] = true;
		push(names, leaf);
	}

	return { names, type: groupType };
};

function collectLeaves(groupName) {
	if (!clash.ready())
		return collectLeavesFromCache(groupName);

	const snapshot = clash.proxies();
	const proxies = snapshot.data?.proxies ?? {};
	const entry = proxies[groupName];
	const names = [];
	const seen = {};

	for (let member in (entry?.all ?? [])) {
		const leaf = resolveLeaf(proxies, member);
		if (!leaf || seen[leaf])
			continue;
		seen[leaf] = true;
		push(names, leaf);
	}

	return { names, type: proxyType(entry?.type ?? '') };
};

function presentGroups(result) {
	const cache = profile.cached();
	const paths = icons.paths(cache);

	for (let group in (result.groups ?? [])) {
		group.icon = paths[group.name] ?? '';
		group.label = shownName(group.name, cache?.group_labels ?? {});
	}

	result.flag_regex = type(cache?.flag_regex) == 'string' ? cache.flag_regex : '';
	return result;
};

function groupsFromCache() {
	const cache = profile.cached();
	const labels = { ...(cache?.node_labels ?? {}), ...(cache?.group_labels ?? {}) };
	const extras = {};
	const nested = {};
	const groups = [];

	for (let proxy in profile.nodesOf(cache?.config))
		if (length(proxy?.name))
			extras[proxy.name] = proxy;

	for (let group in (cache?.config?.['proxy-groups'] ?? []))
		if (length(group?.name))
			nested[group.name] = proxyType(group.type ?? '');

	for (let group in (cache?.config?.['proxy-groups'] ?? [])) {
		if (!length(group?.name) || group.hidden == true)
			continue;

		const members = [];
		for (let member in profile.membersOf(cache.config, group)) {
			const cfg = extras[member] ?? {};
			const isGroup = member in nested;

			push(members, {
				name: member,
				label: shownName(member, labels),
				type: isGroup ? nested[member] : proxyType(cfg.type ?? ''),
				protocol: isGroup ? '' : proxyType(cfg.type ?? ''),
				network: isGroup ? '' : (cfg.network ?? ''),
				tls: isGroup ? '' : proxyTls(cfg),
				udp: udpTag(null, null, cfg, isGroup),
				is_group: isGroup,
				group_selectable: isGroup && nested[member] == 'Selector',
				via: '',
				via_label: '',
				delay: 0
			});
		}

		push(groups, {
			name: group.name,
			type: proxyType(group.type ?? ''),
			now: '',
			now_label: '',
			now_via_label: '',
			members
		});
	}

	return presentGroups({ groups });
};

function groupsView() {
	const snapshot = clash.proxies();
	if (!snapshot.ok)
		return coreRunning() ? { error: snapshot.error } : groupsFromCache();

	const proxies = snapshot.data?.proxies ?? {};
	const cache = profile.cached();
	const labels = { ...(cache?.node_labels ?? {}), ...(cache?.group_labels ?? {}) };
	const extras = {};
	const ordered = [];
	const hidden = { 'ecy-speed': true };
	for (let group in (cache?.config?.['proxy-groups'] ?? []))
		if (group.hidden == true)
			hidden[group.name] = true;

	for (let proxy in profile.nodesOf(cache?.config))
		if (length(proxy?.name))
			extras[proxy.name] = proxy;

	for (let group in (cache?.config?.['proxy-groups'] ?? []))
		if (length(group?.name) && !hidden[group.name] && exists(proxies, group.name))
			push(ordered, group.name);

	for (let name, entry in proxies)
		if (!hidden[name] && type(entry?.all) == 'array' && !(name in ordered))
			push(ordered, name);

	const groups = [];

	for (let name in ordered) {
		const entry = proxies[name];
		const members = [];
		const now = entry.now ?? '';
		const leaf = resolveLeaf(proxies, name);

		for (let member in entry.all) {
			if (member == profile.SPEED_GROUP)
				continue;
			const node = proxies[member] ?? {};
			const nested = type(node.all) == 'array';
			const target = resolveLeaf(proxies, member);
			const live = proxies[target] ?? {};
			const cfg = extras[target] ?? {};
			const history = (nested ? live.history : node.history) ?? [];
			const last = history[-1];

			push(members, {
				name: member,
				label: shownName(member, labels),
				type: node.type ?? '',
				protocol: nested ? '' : proxyType(node.type ?? cfg.type ?? ''),
				network: nested ? '' : (cfg.network ?? ''),
				tls: nested ? '' : proxyTls(cfg),
				udp: udpTag(live, node, cfg, nested),
				is_group: nested,
				group_selectable: nested && proxyType(node.type ?? '') == 'Selector',
				via: target == member ? '' : target,
				via_label: target == member ? '' : shownName(target, labels),
				delay: +(last?.delay ?? 0)
			});
		}

		push(groups, {
			name,
			type: proxyType(entry.type ?? ''),
			now,
			now_label: shownName(now, labels),
			now_via_label: leaf == now ? '' : shownName(leaf, labels),
			members
		});
	}

	return presentGroups({ groups });
};

function connectionsView() {
	const snapshot = statistics.read();
	const cache = profile.cached();
	const labels = { ...(cache?.node_labels ?? {}), ...(cache?.group_labels ?? {}) };
	const label = conn => ({ ...conn, rule: annotateLabels(conn.rule, labels), chains: labeledList(conn.chains, labels) });
	return { at: +(snapshot.at ?? 0), connections: map(values(snapshot.alive ?? {}), label), closed: map(snapshot.closed ?? [], label) };
};

const methods = {
	status: {
		call: function() {
			return statusView();
		}
	},

	groups: {
		call: function() {
			const job = service.delayJob();
			const speed = service.speedJob();
			const view = groupsView();
			return view.error ? view : annotateGroups(view, job, speed);
		}
	},

	connections: {
		call: function() {
			return connectionsView();
		}
	},

	close_connection: {
		args: { id: '' },
		call: function(request) {
			const res = clash.closeConnection(request.args.id);
			return { ok: res.ok == true, msg: res.error ?? '' };
		}
	},

	logs: {
		args: { lines: 200 },
		call: function(request) {
			const lines = min(2000, max(1, int(request.args?.lines) || 200));
			const proc = popen(`logread 2>/dev/null | grep -iE 'ecycloud|mihomo|clash' | tail -n ${lines}`);

			if (!proc)
				return { log: '' };

			const out = proc.read('all') ?? '';
			proc.close();

			const cache = profile.cached();
			return { log: annotateLabels(out, { ...(cache?.node_labels ?? {}), ...(cache?.group_labels ?? {}) }) };
		}
	},

	login: {
		args: { email: '', password: '', code: '' },
		call: function(request) {
			const res = panel.login(request.args.email, request.args.password, request.args.code);

			return { ok: res.ok == true, msg: res.msg ?? '', need_code: res.need_code == true };
		}
	},

	send_login_verify: {
		args: { email: '' },
		call: function(request) {
			const res = panel.sendLoginVerify(request.args.email);
			return { ok: res.ok == true, msg: res.msg ?? '' };
		}
	},

	login_code: {
		args: { email: '', code: '' },
		call: function(request) {
			const res = panel.loginWithVerifyCode(request.args.email, request.args.code);

			return { ok: res.ok == true, msg: res.msg ?? '' };
		}
	},

	logout: {
		call: function() {
			const res = panel.logout();

			return { ok: true, msg: res.msg ?? '' };
		}
	},

	start: {
		args: { refreshed: false },
		call: function(request) {
			const cached = profile.cached(access(profile.PENDING_FILE));
			/* 拉配置可能耗时数分钟，rpcd 不能同步等：交给后台任务，前端等到成功后带 refreshed 再来 */
			if (coreRunning() && !cached && request.args.refreshed != true)
				return service.enqueueUpdate('profile', '');
			if (cached?.config) {
				const checked = profile.inspect(cached.config);
				if (!checked.ok)
					return { ok: false, msg: checked.error };
			}
			const live = instances();
			toggle(true);

			if (live.core?.dir == settings().runDir && live.watchdog?.running)
				return { ok: true, msg: '' };

			return { ok: background(`${INIT} restart`) };
		}
	},

	refresh_account: {
		args: { use_cache: false },
		call: function(request) {
			const account = panel.account();
			if (request.args.use_cache == true && profile.cached() && account && account.device_kick_notice != true)
				return { ok: true, account: accountView(account), msg: '' };
			const res = panel.refreshAccount();
			if (res.restricted)
				service.block(res.msg);
			if (!res.ok && res.status == 0 && profile.cached() && panel.account())
				return { ok: true, offline: true, account: accountView(), msg: '' };
			return { ok: res.ok == true, msg: res.msg ?? '', account: accountView(res.data) };
		}
	},

	checkin: {
		call: function() {
			const res = panel.checkin();
			return { ok: res.ok == true, msg: res.msg ?? '', account: accountView(res.data) };
		}
	},

	online_devices: {
		call: function() {
			const res = panel.onlineDevices();
			return { ok: res.ok == true, msg: res.msg ?? '', devices: res.devices ?? [] };
		}
	},

	devices: {
		args: { page: 1, length: 100, search: '' },
		call: function(request) {
			const res = panel.devices(request.args.page, request.args.length, request.args.search);
			return {
				ok: res.ok == true,
				msg: res.msg ?? '',
				items: res.items ?? [],
				log_keep_days: +(res.log_keep_days ?? 1),
				current_page: +(res.current_page ?? 1),
				last_page: +(res.last_page ?? 1),
				total: +(res.total ?? 0),
				per_page: +(res.per_page ?? 100)
			};
		}
	},

	device_reclaim: {
		args: { target_device_id: '' },
		call: function(request) {
			const res = panel.reclaimDeviceSlot(request.args.target_device_id);
			return { ok: res.ok == true, msg: res.msg ?? '' };
		}
	},

	device_kick_ack: {
		call: function() {
			const res = panel.ackDeviceKick();
			clearKicked();
			return { ok: res.ok == true, msg: res.msg ?? '' };
		}
	},

	kick_device: {
		args: { device_id: '' },
		call: function(request) {
			const res = panel.kickDevice(request.args.device_id);
			return { ok: res.ok == true, msg: res.msg ?? '' };
		}
	},

	stop: {
		call: function() {
			toggle(false);
			service.standby();
			return { ok: true, msg: '' };
		}
	},

	update: {
		args: { what: '', path: '', locale: '' },
		call: function(request) {
			const what = `${request.args.what ?? ''}`;

			if (what == 'geo')
				return clash.ready() ? service.enqueueUpdate('geo', '') : { ok: false, msg: '内核未运行' };

			if (what == 'runtime') {
				const res = profile.runtimeConfig();
				const cache = profile.cached();
				return {
					ok: res.ok == true,
					msg: res.error ?? '',
					text: res.ok
						? annotateRuntime(res.text ?? '', { ...(cache?.node_labels ?? {}), ...(cache?.group_labels ?? {}) })
						: ''
				};
			}

			if (what == 'rules')
				return { ok: true, items: profile.ruleProviders() };

			if (what == 'rule') {
				const res = profile.readRunFile(request.args.path);
				return { ok: res.ok == true, msg: res.error ?? '', text: res.text ?? '' };
			}

			if (what == 'check_app')
				return release.checkApp();

			if (what == 'check_kernel')
				return release.checkKernel('');

			if (what == 'announcements')
				return panel.announcements(request.args.path, request.args.locale);

			return service.enqueueUpdate(what == 'language' ? 'language' : 'profile', `${request.args.locale ?? ''}`);
		}
	},

	select: {
		args: { group: '', name: '' },
		call: function(request) {
			const group = `${request.args.group ?? ''}`;
			const name = `${request.args.name ?? ''}`;

			if (!length(group) || !length(name))
				return { ok: false, msg: 'missing group or name' };

			try {
				/* 控制面不通（status 0）时记下选择并把常驻内核拉起来，启动后由 applySelectors
				   落地，与客户端 selectProxy 先 _ensureControlPlane 同一口径；
				   内核答了但拒了（组已不存在等）要原样报出，不能当成待落地的选择存下来 */
				const current = clash.proxy(group);
				if (!current.ok) {
					if (current.status != 0)
						return { ok: false, msg: current.error ?? '' };

					service.rememberSelector(group, name);
					service.startStandby();
					return { ok: true, msg: '' };
				}

				const previous = current.data?.now ?? '';

				const res = clash.select(group, name);
				if (res.ok)
					service.rememberSelector(group, name);

				if (res.ok && length(previous) && previous != name)
					service.closeViaLater(previous);

				return {
					ok: res.ok == true,
					msg: res.error ?? (res.ok ? '' : `控制面返回 HTTP ${res.status}`)
				};
			} catch (e) {
				return { ok: false, msg: `${e}` };
			}
		}
	},

	ensure_kernel: {
		call: function() {
			service.startStandby();
			return { ok: true, msg: '' };
		}
	},

	delay: {
		args: { name: '' },
		call: function(request) {
			if (!length(request.args.name))
				return { ok: false, msg: 'missing name' };

			service.startStandby();
			return { ok: service.enqueueDelay([ request.args.name ], '').ok, msg: '' };
		}
	},

	test_group: {
		args: { group: '' },
		call: function(request) {
			const group = request.args.group;
			if (!length(group))
				return { ok: false, msg: 'missing group' };

			const collected = collectLeaves(group);
			if (!length(collected.names))
				return { ok: false, msg: 'empty group' };

			service.startStandby();
			const queued = service.enqueueDelay(collected.names,
				collected.type == 'Selector' ? '' : group,
				group);
			return { ok: queued.ok, msg: '' };
		}
	},

	speed_test: {
		args: { name: '' },
		call: function(request) {
			if (!length(request.args.name))
				return { ok: false, msg: 'missing name' };

			const local = service.speedQuota([ request.args.name ]);
			if (!length(local.allowed))
				return { ok: false, msg: local.msg };

			const reserved = panel.reserveSpeedTest(local.allowed);
			if (!reserved.ok)
				return { ok: false, msg: reserved.msg ?? '' };

			const allowed = reserved.data?.allowed ?? [];
			const denied = reserved.data?.denied ?? [];
			for (let item in denied)
				service.noteSpeedDenied(item.proxy_name, item.reset_at);

			if (!length(allowed))
				return { ok: false, msg: denied[0]?.msg ?? '测速次数已达上限' };

			service.startStandby();
			return { ok: service.enqueueSpeed(allowed, '').ok, msg: '' };
		}
	},

	test_group_speed: {
		args: { group: '' },
		call: function(request) {
			const group = request.args.group;
			if (!length(group))
				return { ok: false, msg: 'missing group' };

			const collected = collectLeaves(group);
			const names = [];
			for (let name in collected.names)
				if (match(name, /^node-[0-9]+$/))
					push(names, name);
			if (!length(names))
				return { ok: false, msg: 'empty group' };

			const local = service.speedQuota(names);
			if (!length(local.allowed))
				return { ok: false, msg: local.msg };

			const reserved = panel.reserveSpeedTest(local.allowed);
			if (!reserved.ok)
				return { ok: false, msg: reserved.msg ?? '' };

			const allowed = reserved.data?.allowed ?? [];
			const denied = reserved.data?.denied ?? [];
			for (let item in denied)
				service.noteSpeedDenied(item.proxy_name, item.reset_at);

			if (!length(allowed))
				return { ok: false, msg: denied[0]?.msg ?? '测速次数已达上限' };

			service.startStandby();
			const queued = service.enqueueSpeed(allowed, group);
			const skipped = length(names) - length(allowed);
			return {
				ok: queued.ok,
				msg: queued.ok && skipped > 0 ? `已跳过 ${skipped} 个达到测速次数上限的节点` : ''
			};
		}
	},

	reselect: {
		args: { group: '' },
		call: function(request) {
			const res = clash.reselect(request.args.group);
			return { ok: res.ok, msg: res.error ?? '' };
		}
	},

	mode: {
		args: { mode: 'rule' },
		call: function(request) {
			const mode = request.args.mode;

			if (!(mode in [ 'rule', 'global', 'direct' ]))
				return { ok: false, msg: 'invalid mode' };

			if (clash.ready()) {
				const res = clash.setMode(mode);
				if (!res.ok)
					return { ok: false, msg: res.error ?? '' };
			}

			const uci = cursor();
			uci.set('ecycloud', 'config', 'route_mode', mode);
			uci.commit('ecycloud');
			profile.setRunMode(settings().runDir, mode);
			return { ok: true, msg: '' };
		}
	},

	set: {
		args: { name: '', value: '' },
		call: function(request) {
			const allowed = {
				mode: [ 'tproxy', 'tun' ],
				dns_hijack: [ '0', '1' ]
			};
			const name = request.args.name;
			const value = `${request.args.value}`;

			if (!(name in allowed) || !(value in allowed[name]))
				return { ok: false, msg: 'invalid option' };

			const uci = cursor();
			uci.set('ecycloud', 'config', name, value);
			uci.commit('ecycloud');
			background(`${INIT} restart`);

			return { ok: true, msg: '' };
		}
	},

};

const GUEST_OK = {
	status: true,
	login: true,
	send_login_verify: true,
	login_code: true,
	logout: true
};

function guestReply() {
	return {
		ok: false,
		msg: '尚未登录面板'
	};
};

function guard(name, inner) {
	return function(request) {
		if (name == 'login' || name == 'login_code' || name == 'logout') {
			const result = service.changeSession(() => ({ ...inner(request), session: panel.session() }), name == 'logout');
			return { ...result, session: result.session ?? panel.session() };
		}
		const checkUpdate = name == 'update' &&
			(request.args.what == 'check_app' || request.args.what == 'check_kernel');
		const result = GUEST_OK[name] || checkUpdate || panel.session().logged_in
			? inner(request) : guestReply();
		result.session = panel.session();
		return result;
	};
};

for (let name in methods)
	methods[name].call = guard(name, methods[name].call);

return { 'luci.ecycloud': methods };
