'use strict';

import { access, unlink } from 'fs';
import * as clash from 'ecycloud.clash';
import { CONF_DIR, STATE_DIR, coreRunning, creds, ensurePrivateDir, readJson, sessionBinding, settings, writePrivateJson } from 'ecycloud.common';
import { nodesOf } from 'ecycloud.profile';

const SNAPSHOT_FILE = `${STATE_DIR}/connections.json`;
const RANK_FILE = `${CONF_DIR}/traffic_rank.json`;
const CLOSED_LIMIT = 1000;
const HOST_LIMIT = 10000;
const BYPASS = [ 'direct', 'reject', 'reject-drop', 'rejectdrop', 'compatible', 'pass', 'dns' ];
let savedAt = 0;
let ranks;
let dirty = false;

function owned(path, binding) {
	const saved = readJson(path);
	if (path == RANK_FILE) {
		const account = lc(trim(creds().email ?? ''));
		return length(account) ? { rank: saved?.accounts?.[account] ?? (saved?.binding == binding ? saved.rank : {}) } : {};
	}
	return length(binding) && saved?.binding == binding ? saved : {};
};

function persist(days) {
	const account = lc(trim(creds().email ?? ''));
	if (!length(account))
		return false;
	const saved = readJson(RANK_FILE);
	const accounts = type(saved?.accounts) == 'object' ? saved.accounts : {};
	accounts[account] = days;
	ensurePrivateDir(CONF_DIR);
	return writePrivateJson(RANK_FILE, { accounts });
};

function dayKey(parts) {
	return sprintf('%04d-%02d-%02d', parts.year, parts.mon, parts.mday);
};

function trimDays(days) {
	const today = dayKey(localtime(time()));
	const yesterday = dayKey(localtime(time() - 86400));
	for (let day in keys(days))
		if (day != today && day != yesterday) {
			delete days[day];
			dirty = true;
		}
	return today;
};

function view(conn) {
	const meta = conn.metadata ?? {};
	return {
		id: conn.id ?? '', network: meta.network ?? '', inbound: meta.type ?? '',
		host: meta.host ?? '', destination_ip: meta.destinationIP ?? '',
		destination_port: meta.destinationPort ?? '', remote_destination: meta.remoteDestination ?? '',
		source_ip: meta.sourceIP ?? '', source_port: meta.sourcePort ?? '',
		process: meta.process ?? meta.processPath ?? '', process_path: meta.processPath ?? '',
		rule: conn.rule ?? '', rule_payload: conn.rulePayload ?? '', leaf: conn.chains?.[0] ?? '', chains: conn.chains ?? [],
		upload: +(conn.upload ?? 0), download: +(conn.download ?? 0), start: conn.start ?? ''
	};
};

export function clear(preserve) {
	if (preserve) {
		const binding = sessionBinding();
		const days = owned(SNAPSHOT_FILE, binding).rank ?? owned(RANK_FILE, binding).rank;
		if (days != null && !persist(days))
			die('无法保存当前账户流量记录');
	}
	ranks = null;
	savedAt = 0;
	dirty = false;
	for (let path in (preserve ? [ SNAPSHOT_FILE ] : [ SNAPSHOT_FILE, RANK_FILE ]))
		if (access(path) && !unlink(path))
			die('无法清除旧账户流量记录');
};

export function read() {
	const binding = sessionBinding();
	const snapshot = owned(SNAPSHOT_FILE, binding);
	delete snapshot.binding;
	const days = snapshot.rank ?? owned(RANK_FILE, binding).rank ?? {};
	trimDays(days);
	return { ...snapshot, rank: days, today: dayKey(localtime(time())),
		yesterday: dayKey(localtime(time() - 86400)) };
};

export function collect(snapshot) {
	const binding = sessionBinding();
	if (!length(binding))
		return false;
	const previous = owned(SNAPSHOT_FILE, binding);
	if (ranks?.binding != binding)
		ranks = { binding, rank: previous.rank ?? owned(RANK_FILE, binding).rank ?? {} };
	const today = trimDays(ranks.rank);
	const bucket = ranks.rank[today] ?? { groups: {}, hosts: {} };
	let hostCount = length(keys(bucket.hosts));
	let groupCount = length(keys(bucket.groups));
	const config = readJson(`${settings().runDir}/config.json`);
	const types = { DIRECT: 'direct', REJECT: 'reject' };
	const skipped = {};
	for (let node in nodesOf(config)) {
		types[node.name] = lc(node.type);
		if (length(node.server))
			skipped[lc(node.server)] = true;
	}
	const alive = {};
	let upload = 0;
	let download = 0;
	for (let raw in (snapshot?.connections ?? [])) {
		const conn = view(raw);
		if (!length(conn.id))
			continue;
		alive[conn.id] = conn;
		if (!length(conn.leaf) || (types[conn.leaf] ?? lc(conn.leaf)) in BYPASS)
			continue;
		const old = previous.alive?.[conn.id];
		const up = max(0, conn.upload - +(old?.upload ?? 0));
		const down = max(0, conn.download - +(old?.download ?? 0));
		const bytes = up + down;
		upload += up;
		download += down;
		if (previous.at == null || !bytes)
			continue;
		dirty = true;
		for (let group in filter(conn.chains, (name, i) => i > 0)) {
			if (!exists(bucket.groups, group) && groupCount >= 512)
				continue;
			if (!exists(bucket.groups, group))
				groupCount++;
			bucket.groups[group] = +(bucket.groups[group] ?? 0) + bytes;
		}
		const host = trim(conn.host) || trim(conn.destination_ip);
		if (length(host) && !skipped[lc(host)] && (exists(bucket.hosts, host) || hostCount < HOST_LIMIT)) {
			if (!exists(bucket.hosts, host))
				hostCount++;
			bucket.hosts[host] = +(bucket.hosts[host] ?? 0) + bytes;
		}
	}
	const closed = previous.closed ?? [];
	const utc = gmtime(time());
	for (let id, conn in (previous.alive ?? {}))
		if (!exists(alive, id))
			unshift(closed, { ...conn, closed_at: sprintf('%sT%02d:%02d:%02dZ', dayKey(utc), utc.hour, utc.min, utc.sec) });
	const seconds = time() - +(previous.at ?? 0);
	ranks.rank[today] = bucket;
	ensurePrivateDir(STATE_DIR);
	const ok = writePrivateJson(SNAPSHOT_FILE, {
		binding, at: time(), alive, closed: slice(closed, 0, CLOSED_LIMIT), rank: ranks.rank,
		up: seconds > 0 ? int(upload / seconds) : 0, down: seconds > 0 ? int(download / seconds) : 0,
		total_up: +(previous.total_up ?? 0) + upload, total_down: +(previous.total_down ?? 0) + download
	});
	if (ok && dirty && time() - savedAt >= 300) {
		if (persist(ranks.rank)) {
			savedAt = time();
			dirty = false;
		}
	}
	return ok;
};

export function poll() {
	if (!coreRunning())
		return collect({ connections: [] });
	const res = clash.connections();
	return res.ok && type(res.data?.connections) == 'array' ? collect(res.data) : false;
};
