'use strict';

import { access, unlink, writefile } from 'fs';
import { cursor } from 'uci';

import { NETWORK_FILE, NFT_DIR, NFT_TABLE, ROUTE_TABLE, ROUTING_MARK, TPROXY_MARK,
         ensureDir, lanDevices, log, readJson, uciList, writeJson } from 'ecycloud.common';

const RULESET_FILE = `${NFT_DIR}/ruleset-post/${NFT_TABLE}.nft`;
const DSTNAT_FILE = `${NFT_DIR}/chain-pre/dstnat/${NFT_TABLE}.nft`;
const FORWARD_FILE = `${NFT_DIR}/chain-pre/forward/${NFT_TABLE}.nft`;
const INPUT_FILE = `${NFT_DIR}/chain-pre/input/${NFT_TABLE}.nft`;

/* fake-ip 段不能进保留地址表，那正是要送进内核的目标 */
const RESERVED4 = [
	'0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
	'172.16.0.0/12', '192.0.0.0/24', '192.88.99.0/24', '192.168.0.0/16',
	'224.0.0.0/4', '240.0.0.0/4'
];

const RESERVED6 = [ '::1/128', '100::/64', 'fc00::/7', 'fe80::/10', 'ff00::/8' ];

function deviceSet(devices) {
	return `{ ${join(', ', map(devices, d => `"${d}"`))} }`;
}

function ruleset(cfg, devices) {
	const lines = [
		`table inet ${NFT_TABLE}`,
		`flush table inet ${NFT_TABLE}`,
		`table inet ${NFT_TABLE} {`,
		'\tset reserved4 {',
		'\t\ttype ipv4_addr',
		'\t\tflags interval',
		`\t\telements = { ${join(', ', RESERVED4)} }`,
		'\t}'
	];

	if (cfg.ipv6)
		push(lines,
			'',
			'\tset reserved6 {',
			'\t\ttype ipv6_addr',
			'\t\tflags interval',
			`\t\telements = { ${join(', ', RESERVED6)} }`,
			'\t}');

	push(lines,
		'',
		'\tchain prerouting {',
		'\t\ttype filter hook prerouting priority mangle; policy accept;',
		`\t\tmeta l4proto tcp socket transparent 1 meta mark set ${TPROXY_MARK} accept`,
		'\t\tmeta l4proto { tcp, udp } th dport 53 accept',
		'\t\tip daddr @reserved4 accept',
		cfg.ipv6 ? '\t\tip6 daddr @reserved6 accept' : '\t\tmeta nfproto ipv6 accept');

	if (cfg.routerProxy)
		push(lines, `\t\tmeta mark ${TPROXY_MARK} jump tproxy`);

	push(lines,
		`\t\tiifname ${deviceSet(devices)} jump tproxy`,
		'\t}',
		'',
		'\tchain tproxy {',
		`\t\tmeta nfproto ipv4 meta l4proto { tcp, udp } tproxy ip to :${cfg.tproxyPort} meta mark set ${TPROXY_MARK} accept`);

	if (cfg.ipv6)
		push(lines, `\t\tmeta nfproto ipv6 meta l4proto { tcp, udp } tproxy ip6 to :${cfg.tproxyPort} meta mark set ${TPROXY_MARK} accept`);

	push(lines, '\t}');

	if (cfg.routerProxy)
		push(lines,
			'',
			'\tchain output {',
			'\t\ttype route hook output priority mangle; policy accept;',
			`\t\tmeta mark ${ROUTING_MARK} accept`,
			'\t\tmeta l4proto { tcp, udp } th dport 53 accept',
			'\t\tip daddr @reserved4 accept',
			cfg.ipv6 ? '\t\tip6 daddr @reserved6 accept' : '\t\tmeta nfproto ipv6 accept',
			`\t\tmeta l4proto { tcp, udp } meta mark set ${TPROXY_MARK}`,
			'\t}');

	push(lines, '}', '');

	return join('\n', lines);
}

function routing(cfg, add) {
	const families = cfg.ipv6 ? [ 'ip', 'ip -6' ] : [ 'ip' ];

	for (let ip in families) {
		system(`${ip} rule del fwmark ${TPROXY_MARK} lookup ${ROUTE_TABLE} 2>/dev/null`);
		system(`${ip} route del local default dev lo table ${ROUTE_TABLE} 2>/dev/null`);

		if (add) {
			system(`${ip} rule add fwmark ${TPROXY_MARK} lookup ${ROUTE_TABLE}`);
			system(`${ip} route add local default dev lo table ${ROUTE_TABLE}`);
		}
	}
}

function dnsmasqSection() {
	let name = null;

	cursor().foreach('dhcp', 'dnsmasq', s => {
		name ??= s['.name'];
	});

	return name;
}

function dnsmasqConfDir(section) {
	if (!length(section))
		return null;

	const configured = cursor().get('dhcp', section, 'confdir');
	const dir = length(configured) ? split(configured, ',')[0] : `/tmp/dnsmasq.${section}.d`;

	return substr(dir, 0, 1) == '/' ? dir : null;
}

/* conf-dir 在 tmpfs 上：意外重启后自动失效，dnsmasq 回到原本的上游，不留失联状态 */
function applyDnsmasq(cfg) {
	const section = dnsmasqSection();
	const dir = dnsmasqConfDir(section);
	if (!length(dir))
		return null;

	ensureDir(dir);

	const path = `${dir}/ecycloud.conf`;
	if (writefile(path, `no-resolv\nserver=127.0.0.1#${cfg.dnsPort}\n`) == null)
		return null;

	/* no-resolv 只掀掉 resolv-file，UCI 里手填的上游仍与内核并列，查询会绕过分流 */
	const extra = uciList(cursor().get('dhcp', section, 'server'));
	if (length(extra))
		log('warning', `dnsmasq still has upstream servers ${join(', ', extra)}, DNS may bypass the kernel`);

	system('/etc/init.d/dnsmasq restart >/dev/null 2>&1');

	return path;
}

function revertDnsmasq(path) {
	if (!length(path) || !access(path))
		return;

	unlink(path);
	system('/etc/init.d/dnsmasq restart >/dev/null 2>&1');
}

export function applied() {
	return readJson(NETWORK_FILE);
}

export function apply(cfg) {
	const devices = lanDevices();
	if (!length(devices))
		return { ok: false, error: '取不到 LAN 接口设备名，请在设置里确认「LAN 接口」' };

	revert();

	const record = { dnsmasq: null };

	if (cfg.mode == 'tproxy') {
		ensureDir(`${NFT_DIR}/ruleset-post`);
		if (writefile(RULESET_FILE, ruleset(cfg, devices)) == null)
			return { ok: false, error: `无法写入 ${RULESET_FILE}` };

		/* TPROXY 后包目的地仍是外网地址却走本机投递，区域 input 策略是 REJECT 时会被拦掉 */
		ensureDir(`${NFT_DIR}/chain-pre/input`);
		if (writefile(INPUT_FILE, `\t\tmeta mark ${TPROXY_MARK} accept comment "!ecycloud: tproxy delivery"\n`) == null)
			return { ok: false, error: `无法写入 ${INPUT_FILE}` };
	} else {
		ensureDir(`${NFT_DIR}/chain-pre/forward`);
		const accept = [
			`\t\tiifname "${cfg.tunDevice}" accept comment "!ecycloud: tun ingress"`,
			`\t\toifname "${cfg.tunDevice}" accept comment "!ecycloud: tun egress"`,
			''
		];
		if (writefile(FORWARD_FILE, join('\n', accept)) == null)
			return { ok: false, error: `无法写入 ${FORWARD_FILE}` };
	}

	if (cfg.dnsHijack) {
		ensureDir(`${NFT_DIR}/chain-pre/dstnat`);
		const hijack = [
			`\t\tiifname ${deviceSet(devices)} meta l4proto { tcp, udp } th dport 53 redirect to :53 comment "!ecycloud: DNS hijack"`,
			''
		];
		if (writefile(DSTNAT_FILE, join('\n', hijack)) == null)
			return { ok: false, error: `无法写入 ${DSTNAT_FILE}` };
	}

	if (system('fw4 reload >/dev/null 2>&1') != 0)
		return { ok: false, error: 'fw4 reload 失败，防火墙规则未生效' };

	if (cfg.mode == 'tproxy')
		routing(cfg, true);

	if (cfg.dnsHijack)
		record.dnsmasq = applyDnsmasq(cfg);

	writeJson(NETWORK_FILE, record);

	if (cfg.dnsHijack && !length(record.dnsmasq))
		return { ok: false, error: 'dnsmasq 配置目录不可用，DNS 未接入内核' };

	return { ok: true };
}

/* 记录在 tmpfs 上、include 片段在 overlay 上：掉电后前者没了后者还在，
   所以按固定路径无条件清，不能只清记录里列的那几个 */
export function revert() {
	let removed = false;

	for (let path in [ RULESET_FILE, INPUT_FILE, FORWARD_FILE, DSTNAT_FILE ])
		if (access(path)) {
			unlink(path);
			removed = true;
		}

	if (removed) {
		system('fw4 reload >/dev/null 2>&1');
		/* fw4 只 flush 自己那张表，不再被 include 的 ecycloud 表得自己删 */
		system(`nft delete table inet ${NFT_TABLE} 2>/dev/null`);
	}

	routing({ ipv6: true }, false);
	revertDnsmasq(applied()?.dnsmasq);
	unlink(NETWORK_FILE);
}
