'use strict';

import { popen } from 'fs';
import { cursor } from 'uci';

import * as clash from 'ecycloud.clash';
import * as network from 'ecycloud.network';
import * as panel from 'ecycloud.panel';
import * as profile from 'ecycloud.profile';

import { build, coreRunning, lanDevices, origins, settings, state } from 'ecycloud.common';

const CTL = '/usr/libexec/ecycloud-ctl';
const INIT = '/etc/init.d/ecycloud';

function background(command) {
	return system(`${command} >/dev/null 2>&1 &`) == 0;
}

function toggle(enabled) {
	const uci = cursor();
	uci.set('ecycloud', 'config', 'enabled', enabled ? '1' : '0');
	uci.commit('ecycloud');
}

function accountView() {
	const acct = panel.account();
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
		plan_days: +(acct.plan?.remaining_days ?? 0)
	};
}

function statusView() {
	const cfg = settings();
	const st = state();
	const cache = profile.cached();
	const running = coreRunning();
	const snapshot = running ? clash.connections() : { ok: false };
	const version = running ? clash.version() : { ok: false };
	const record = network.applied();

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
		kernel_version: version.ok ? (version.data?.version ?? '') : '',
		site: origins().site,
		session: panel.session(),
		account: accountView(),
		profile: {
			revision: cache?.revision ?? '',
			fetched_at: +(cache?.fetched_at ?? 0),
			nodes: length(cache?.config?.proxies ?? [])
		},
		traffic: {
			connections: length(snapshot.data?.connections ?? []),
			upload: +(snapshot.data?.uploadTotal ?? 0),
			download: +(snapshot.data?.downloadTotal ?? 0)
		},
		lan: lanDevices(),
		network_applied: record != null,
		dns_applied: length(record?.dnsmasq) > 0
	};
}

function groupsView() {
	const snapshot = clash.proxies();
	if (!snapshot.ok)
		return { groups: [], error: snapshot.error };

	const proxies = snapshot.data?.proxies ?? {};
	const cache = profile.cached();
	const labels = cache?.node_labels ?? {};
	const ordered = [];

	for (let group in (cache?.config?.['proxy-groups'] ?? []))
		if (length(group?.name) && exists(proxies, group.name))
			push(ordered, group.name);

	for (let name, entry in proxies)
		if (type(entry?.all) == 'array' && !(name in ordered))
			push(ordered, name);

	const groups = [];

	for (let name in ordered) {
		const entry = proxies[name];
		const members = [];

		for (let member in entry.all) {
			const node = proxies[member] ?? {};
			const history = node.history ?? [];

			push(members, {
				name: member,
				label: labels[member] ?? member,
				type: node.type ?? '',
				delay: +(history[-1]?.delay ?? 0)
			});
		}

		push(groups, {
			name,
			type: entry.type ?? '',
			now: entry.now ?? '',
			now_label: labels[entry.now] ?? (entry.now ?? ''),
			members
		});
	}

	return { groups };
}

const methods = {
	status: {
		call: function() {
			return statusView();
		}
	},

	groups: {
		call: function() {
			return groupsView();
		}
	},

	logs: {
		args: { lines: 200 },
		call: function(request) {
			const lines = request.args?.lines > 0 ? request.args.lines : 200;
			const proc = popen(`logread -e ecycloud 2>/dev/null | tail -n ${lines}`);

			if (!proc)
				return { log: '' };

			const out = proc.read('all') ?? '';
			proc.close();

			return { log: out };
		}
	},

	login: {
		args: { email: '', password: '', code: '' },
		call: function(request) {
			const res = panel.login(request.args.email, request.args.password, request.args.code);

			if (res.ok) {
				toggle(true);
				background(`${INIT} restart`);
			}

			return { ok: res.ok == true, msg: res.msg ?? '', need_code: res.need_code == true };
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
			toggle(true);
			return { ok: background(`${INIT} restart`) };
		}
	},

	stop: {
		call: function() {
			toggle(false);
			return { ok: background(`${INIT} stop`) };
		}
	},

	update: {
		call: function() {
			return { ok: background(`${CTL} update force`) };
		}
	},

	select: {
		args: { group: '', name: '' },
		call: function(request) {
			const current = clash.proxies();
			const previous = current.data?.proxies?.[request.args.group]?.now ?? '';
			const res = clash.select(request.args.group, request.args.name);

			if (res.ok && length(previous) && previous != request.args.name)
				clash.closeVia(previous);

			return { ok: res.ok, msg: res.error ?? '' };
		}
	},

	delay: {
		args: { name: '' },
		call: function(request) {
			const res = clash.delay(request.args.name, 5000);

			return {
				ok: res.ok,
				delay: +(res.data?.delay ?? 0),
				msg: res.ok ? '' : (res.error ?? '')
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

			const uci = cursor();
			uci.set('ecycloud', 'config', 'route_mode', mode);
			uci.commit('ecycloud');

			if (!coreRunning())
				return { ok: true, msg: '' };

			const res = clash.setMode(mode);

			return { ok: res.ok, msg: res.error ?? '' };
		}
	}
};

return { 'luci.ecycloud': methods };
