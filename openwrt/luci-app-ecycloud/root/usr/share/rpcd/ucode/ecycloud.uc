'use strict';

import { popen } from 'fs';
import { cursor } from 'uci';

import * as clash from 'ecycloud.clash';
import * as network from 'ecycloud.network';
import * as panel from 'ecycloud.panel';
import * as profile from 'ecycloud.profile';

import { build, clearKicked, coreRunning, instances, kickReason, lanDevices, log, origins,
         settings, state, wasKicked } from 'ecycloud.common';
import * as release from 'ecycloud.release';
import * as service from 'ecycloud.service';

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
		online_client_count: +(acct.online_client_count ?? 0),
		online_client_self: acct.online_client_self == true,
		device_kick_notice: acct.device_kick_notice == true,
		device_kick_reason: acct.device_kick_reason ?? ''
	};
};

function proxyServers(cache) {
	const seen = {};
	const list = [];

	for (let proxy in (cache?.config?.proxies ?? [])) {
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
				fetched_at: +(cache?.fetched_at ?? 0),
				nodes: length(cache?.config?.proxies ?? []),
				servers: proxyServers(cache)
			},
			memory: running ? clash.memoryUsage() : 0,
			traffic: {
				connections: length(snapshot.data?.connections ?? []),
				upload: +(snapshot.data?.uploadTotal ?? 0),
				download: +(snapshot.data?.downloadTotal ?? 0)
			},
			lan: lanDevices(),
			network_applied: record != null,
			dns_applied: length(record?.dnsmasq) > 0,
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
	const label = labels[name];
	if (length(label) && !isNodeIdTag(label))
		return label;
	return isNodeIdTag(name) ? '' : name;
};

function labeledList(names, labels) {
	const out = [];

	for (let name in names)
		push(out, labeledName(name, labels));

	return out;
};

function annotateLabels(text, labels) {
	if (!length(text))
		return text;

	let out = text;

	if (length(labels)) {
		const keys = [];

		for (let key, value in labels)
			if (length(value) && value != key && !isNodeIdTag(value))
				push(keys, key);

		sort(keys, function(a, b) {
			return length(b) - length(a);
		});

		for (let key in keys) {
			const value = labels[key];
			let next = replace(out, key, value);

			while (next != out) {
				out = next;
				next = replace(out, key, value);
			}
		}
	}

	let redacted = replace(out, /node-[0-9]+/, '');

	while (redacted != out) {
		out = redacted;
		redacted = replace(out, /node-[0-9]+/, '');
	}

	return redacted;
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

	if (clash.ready()) {
		service.ensureDelayWorker();
		service.ensureSpeedWorker();
	}

	return { groups, testing: service.delayActive() || length(pending) > 0 };
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
		membersOf[group.name] = group.proxies ?? [];
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

function groupsFromCache() {
	const cache = profile.cached();
	const labels = cache?.node_labels ?? {};
	const extras = {};
	const nested = {};
	const groups = [];

	for (let proxy in (cache?.config?.proxies ?? []))
		if (length(proxy?.name))
			extras[proxy.name] = proxy;

	for (let group in (cache?.config?.['proxy-groups'] ?? []))
		if (length(group?.name))
			nested[group.name] = proxyType(group.type ?? '');

	for (let group in (cache?.config?.['proxy-groups'] ?? [])) {
		if (!length(group?.name))
			continue;

		const members = [];
		for (let member in (group.proxies ?? [])) {
			const cfg = extras[member] ?? {};
			const isGroup = member in nested;

			push(members, {
				name: member,
				label: labeledName(member, labels),
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

	return { groups };
};

function groupsView() {
	const snapshot = clash.proxies();
	if (!snapshot.ok)
		return coreRunning() ? { error: snapshot.error } : groupsFromCache();

	const proxies = snapshot.data?.proxies ?? {};
	const cache = profile.cached();
	const labels = cache?.node_labels ?? {};
	const extras = {};
	const ordered = [];

	for (let proxy in (cache?.config?.proxies ?? []))
		if (length(proxy?.name))
			extras[proxy.name] = proxy;

	for (let group in (cache?.config?.['proxy-groups'] ?? []))
		if (length(group?.name) && exists(proxies, group.name))
			push(ordered, group.name);

	for (let name, entry in proxies)
		if (name != profile.SPEED_GROUP && type(entry?.all) == 'array' && !(name in ordered))
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
				label: labeledName(member, labels),
				type: node.type ?? '',
				protocol: nested ? '' : proxyType(node.type ?? cfg.type ?? ''),
				network: nested ? '' : (cfg.network ?? ''),
				tls: nested ? '' : proxyTls(cfg),
				udp: udpTag(live, node, cfg, nested),
				is_group: nested,
				group_selectable: nested && proxyType(node.type ?? '') == 'Selector',
				via: target == member ? '' : target,
				via_label: target == member ? '' : labeledName(target, labels),
				delay: +(last?.delay ?? 0)
			});
		}

		push(groups, {
			name,
			type: proxyType(entry.type ?? ''),
			now,
			now_label: labeledName(now, labels),
			now_via_label: leaf == now ? '' : labeledName(leaf, labels),
			members
		});
	}

	const remembered = {};
	const saved = service.selectors();
	for (let group in groups)
		if (group.type == 'Selector' && length(group.now) && !length(saved[group.name]) &&
		    group.now != group.members[0]?.name)
			remembered[group.name] = group.now;
	service.rememberSelectors(remembered);

	return { groups };
};

function connectionsView() {
	const snapshot = clash.connections();
	if (!snapshot.ok)
		return { connections: [], error: snapshot.error };

	const labels = profile.cached()?.node_labels ?? {};
	const connections = [];

	for (let conn in (snapshot.data?.connections ?? [])) {
		const meta = conn.metadata ?? {};

		const raw = conn.chains ?? [];

		push(connections, {
			id: conn.id ?? '',
			network: meta.network ?? '',
			inbound: meta.type ?? '',
			host: meta.host ?? '',
			destination_ip: meta.destinationIP ?? '',
			destination_port: meta.destinationPort ?? '',
			process: meta.process ?? meta.processPath ?? '',
			rule: annotateLabels(conn.rule ?? '', labels),
			leaf: raw[0] ?? '',
			chains: labeledList(raw, labels),
			upload: +(conn.upload ?? 0),
			download: +(conn.download ?? 0),
			start: conn.start ?? ''
		});
	}

	return { connections };
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

	logs: {
		args: { lines: 200 },
		call: function(request) {
			const lines = request.args?.lines > 0 ? request.args.lines : 200;
			const proc = popen(`logread 2>/dev/null | grep -iE 'ecycloud|mihomo|clash' | tail -n ${lines}`);

			if (!proc)
				return { log: '' };

			const out = proc.read('all') ?? '';
			proc.close();

			return { log: annotateLabels(out, profile.cached()?.node_labels ?? {}) };
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
			toggle(false);
			background(`${INIT} stop`);

			const res = panel.logout();

			return { ok: true, msg: res.msg ?? '' };
		}
	},

	start: {
		call: function() {
			const cached = profile.cached();
			if (cached?.config) {
				const checked = profile.inspect(cached.config);
				if (!checked.ok)
					return { ok: false, msg: checked.error };
			}
			const live = instances();
			toggle(true);

			/* TPROXY 下装配结果与 enabled 无关（tun 段恒关、tproxy-port 恒为实值），
			   接管只是铺 nftables，交给看门狗的 activate，别为此重启内核断掉存量连接 */
			if (settings().mode == 'tproxy' && live.core?.running && live.watchdog?.running)
				return { ok: true, msg: '' };

			return { ok: background(`${INIT} restart`) };
		}
	},

	refresh_account: {
		call: function() {
			const res = panel.refreshAccount();
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
		args: { page: 1, length: 100 },
		call: function(request) {
			const res = panel.devices(request.args.page, request.args.length);
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
		args: { what: '', path: '' },
		call: function(request) {
			const what = `${request.args.what ?? ''}`;

			if (what == 'geo') {
				if (!clash.ready())
					return { ok: false, msg: '内核未运行' };

				const runDir = settings().runDir;
				const before = profile.geoFingerprint(runDir);
				const res = clash.updateGeo();
				if (!res.ok)
					return { ok: false, msg: res.error ?? '' };

				const after = profile.geoFingerprint(runDir);
				return { ok: true, changed: before != after, msg: '' };
			}

			if (what == 'runtime') {
				const res = profile.runtimeConfig();
				return {
					ok: res.ok == true,
					msg: res.error ?? '',
					text: res.ok
						? annotateLabels(res.text ?? '', profile.cached()?.node_labels ?? {})
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
				return panel.announcements(request.args.path);

			const res = service.update(true);

			return {
				ok: res.ok == true,
				msg: res.error ?? '',
				changed: res.changed == true,
				reloaded: res.reloaded == true
			};
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
		if (name == 'update') {
			const what = `${request.args.what ?? ''}`;
			if (what == 'check_app' || what == 'check_kernel')
				return inner(request);
		}

		if (!panel.session().logged_in)
			return guestReply();

		return inner(request);
	};
};

for (let name in methods) {
	if (GUEST_OK[name])
		continue;

	methods[name].call = guard(name, methods[name].call);
}

return { 'luci.ecycloud': methods };
