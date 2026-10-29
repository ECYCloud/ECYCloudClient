'use strict';

import { access, open, popen, unlink, writefile } from 'fs';
import { cursor } from 'uci';

import { NETWORK_FILE, NFT_DIR, NFT_TABLE, ROUTE_TABLE, ROUTING_MARK, STATE_DIR, TPROXY_MARK, TUN_ROUTE_TABLE, TUN_RULE_INDEX,
         appendNets, coreRunning, ensureDir, ensurePrivateDir, isIpNet, lanDevices, log, panelDirectNets, readJson, settings,
         uciList, writeJson } from 'ecycloud.common';

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

function bypassNets(cfg, v6) {
	const extra = [];

	for (let net in [ ...(cfg.bypass ?? []), ...panelDirectNets() ]) {
		if (!isIpNet(net))
			continue;
		if ((index(net, ':') >= 0) == v6)
			push(extra, net);
	}

	return extra;
};

function reserved4(cfg) {
	return appendNets(RESERVED4, bypassNets(cfg, false));
};

function reserved6(cfg) {
	return appendNets(RESERVED6, bypassNets(cfg, true));
};

function deviceSet(devices) {
	return `{ ${join(', ', map(devices, d => `"${d}"`))} }`;
};

function ruleset(cfg, devices) {
	const lines = [
		`table inet ${NFT_TABLE}`,
		`flush table inet ${NFT_TABLE}`,
		`table inet ${NFT_TABLE} {`,
		'\tset reserved4 {',
		'\t\ttype ipv4_addr',
		'\t\tflags interval',
		'\t\tauto-merge',
		`\t\telements = { ${join(', ', reserved4(cfg))} }`,
		'\t}'
	];

	if (cfg.ipv6)
		push(lines,
			'',
			'\tset reserved6 {',
			'\t\ttype ipv6_addr',
			'\t\tflags interval',
			'\t\tauto-merge',
			`\t\telements = { ${join(', ', reserved6(cfg))} }`,
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
		push(lines, `\t\tmeta mark ${TPROXY_MARK} jump ecycloud_tproxy`);

	push(lines,
		`\t\tiifname ${deviceSet(devices)} jump ecycloud_tproxy`,
		'\t}',
		'',
		'\tchain ecycloud_tproxy {',
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
};

function routing(cfg, add) {
	const families = cfg.ipv6 ? [ 'ip', 'ip -6' ] : [ 'ip' ];

	for (let ip in families) {
		system(`${ip} rule del fwmark ${TPROXY_MARK} lookup ${ROUTE_TABLE} 2>/dev/null`);
		system(`${ip} route del local default dev lo table ${ROUTE_TABLE} 2>/dev/null`);

		if (add) {
			if (system(`${ip} rule add fwmark ${TPROXY_MARK} lookup ${ROUTE_TABLE}`) != 0 ||
			    system(`${ip} route add local default dev lo table ${ROUTE_TABLE}`) != 0)
				return false;
		}
	}
	return true;
};

function dnsmasqSection() {
	let name = null;

	cursor().foreach('dhcp', 'dnsmasq', s => {
		name ??= s['.name'];
	});

	return name;
};

function dnsmasqConfDir(section) {
	if (!length(section))
		return null;

	const configured = cursor().get('dhcp', section, 'confdir');
	const dir = length(configured) ? split(configured, ',')[0] : `/tmp/dnsmasq.${section}.d`;

	return substr(dir, 0, 1) == '/' ? dir : null;
};

/* conf-dir 在 tmpfs 上：意外重启后自动失效，dnsmasq 回到原本的上游，不留失联状态 */
function applyDnsmasq(cfg, section, dir) {
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

	return system('/etc/init.d/dnsmasq restart >/dev/null 2>&1') == 0 ? path : null;
};

function revertDnsmasq(path) {
	if (!length(path))
		return true;

	if (access(path) && !unlink(path))
		return false;
	return system('/etc/init.d/dnsmasq restart >/dev/null 2>&1') == 0;
};

function query(command) {
	const proc = popen(command);
	if (!proc)
		return { ok: false, text: '' };
	const text = proc.read('all') ?? '';
	return { ok: proc.close() == 0, text };
};

export function applied() {
	return readJson(NETWORK_FILE);
};

function withNetworkLock(action) {
	ensurePrivateDir(STATE_DIR);
	const lock = open(`${STATE_DIR}/network.lock`, 'ae', 0600);
	if (!lock)
		die('无法打开网络操作锁');
	if (!lock.lock('x')) {
		lock.close();
		die('无法锁定网络操作');
	}
	let result;
	try {
		result = action();
	} catch (e) {
		lock.close();
		die(e.message);
	}
	lock.close();
	return result;
};

function revertNetwork() {
	const record = applied();
	let removed = false;
	let ok = true;

	for (let path in [ RULESET_FILE, INPUT_FILE, FORWARD_FILE, DSTNAT_FILE ])
		if (access(path)) {
			if (!unlink(path))
				ok = false;
			else
				removed = true;
		}

	if ((removed || record != null) && system('fw4 reload >/dev/null 2>&1') != 0)
		ok = false;
	const tables = query('nft list tables 2>/dev/null');
	if (!tables.ok || (match(tables.text, /table inet ecycloud([[:space:]]|$)/) &&
	    system(`nft delete table inet ${NFT_TABLE} 2>/dev/null`) != 0))
		ok = false;

	routing({ ipv6: true }, false);
	const tunStopped = !coreRunning() || readJson(`${settings().runDir}/config.json`)?.tun?.enable === false;
	for (let ip in [ 'ip', 'ip -6' ]) {
		if (tunStopped) {
			/* sing-tun 的 auto-route 规则占用起始优先级到起始值 + 10，强杀不会撤销这些规则。 */
			for (let priority = TUN_RULE_INDEX; priority <= TUN_RULE_INDEX + 10; priority++)
				if (system(`${ip} rule flush pref ${priority} 2>/dev/null`) != 0)
					ok = false;
			system(`${ip} route flush table ${TUN_ROUTE_TABLE} 2>/dev/null`);
		}
		const rules = query(`${ip} -N rule show 2>/dev/null`);
		const routes = query(`${ip} -N route show table all 2>/dev/null`);
		if (!rules.ok || !routes.ok || match(rules.text, /lookup 1936([[:space:]]|$)/) ||
		    match(routes.text, /table 1936([[:space:]]|$)/))
			ok = false;
		if (tunStopped) {
			for (let line in split(rules.text, '\n')) {
				const priority = +split(line, ':')[0];
				if (priority >= TUN_RULE_INDEX && priority <= TUN_RULE_INDEX + 10)
					ok = false;
			}
			if (match(routes.text, /table 1937([[:space:]]|$)/))
				ok = false;
		}
	}
	if (!revertDnsmasq(record?.dnsmasq))
		ok = false;
	if (ok && access(NETWORK_FILE) && !unlink(NETWORK_FILE))
		ok = false;
	return ok;
};

export function revert() {
	return withNetworkLock(revertNetwork);
};

function applyNetwork(cfg) {
	if (!settings().enabled)
		return { ok: false, error: '连接已关闭，取消网络接管' };
	const devices = lanDevices();
	if (!length(devices))
		return { ok: false, error: '取不到 LAN 接口设备名，请在设置里确认「LAN 接口」' };

	if (!revertNetwork())
		return { ok: false, error: '旧网络设置恢复失败，未应用新的代理规则' };

	const section = cfg.dnsHijack ? dnsmasqSection() : null;
	const dir = cfg.dnsHijack ? dnsmasqConfDir(section) : null;
	if (cfg.dnsHijack && !length(dir))
		return { ok: false, error: 'dnsmasq 配置目录不可用，DNS 未接入内核' };
	const record = { active: false, dnsmasq: cfg.dnsHijack ? `${dir}/ecycloud.conf` : null };
	if (!writeJson(NETWORK_FILE, record))
		return { ok: false, error: '无法保存网络恢复记录' };

	try {
		if (cfg.mode == 'tproxy') {
			ensureDir(`${NFT_DIR}/ruleset-post`);
			if (writefile(RULESET_FILE, ruleset(cfg, devices)) == null)
				die(`无法写入 ${RULESET_FILE}`);
		} else {
			ensureDir(`${NFT_DIR}/chain-pre/forward`);
			const accept = [
				`\t\tiifname "${cfg.tunDevice}" accept comment "!ecycloud: tun ingress"`,
				`\t\toifname "${cfg.tunDevice}" accept comment "!ecycloud: tun egress"`,
				''
			];
			if (writefile(FORWARD_FILE, join('\n', accept)) == null)
				die(`无法写入 ${FORWARD_FILE}`);
		}
		/* TPROXY 与 TUN system/mixed 的 TCP 均投递到本机内核监听口，不能只放行 forward。 */
		ensureDir(`${NFT_DIR}/chain-pre/input`);
		const input = cfg.mode == 'tproxy'
			? `meta mark ${TPROXY_MARK} accept comment "!ecycloud: tproxy delivery"`
			: `iifname "${cfg.tunDevice}" accept comment "!ecycloud: tun delivery"`;
		if (writefile(INPUT_FILE, `\t\t${input}\n`) == null)
			die(`无法写入 ${INPUT_FILE}`);

		if (cfg.dnsHijack) {
			ensureDir(`${NFT_DIR}/chain-pre/dstnat`);
			const hijack = [
				`\t\tiifname ${deviceSet(devices)} meta l4proto { tcp, udp } th dport 53 redirect to :53 comment "!ecycloud: DNS hijack"`,
				''
			];
			if (writefile(DSTNAT_FILE, join('\n', hijack)) == null)
				die(`无法写入 ${DSTNAT_FILE}`);
		}

		if (system('fw4 check >/dev/null 2>&1') != 0 ||
		    system('fw4 reload >/dev/null 2>&1') != 0)
			die('防火墙规则校验或加载失败，规则未生效');

		if (cfg.mode == 'tproxy' && !routing(cfg, true))
			die('策略路由设置失败');

		if (cfg.dnsHijack && !length(applyDnsmasq(cfg, section, dir)))
			die('dnsmasq 配置或重启失败，DNS 未接入内核');
		record.active = true;
		if (!writeJson(NETWORK_FILE, record))
			die('无法保存网络接管状态');
	} catch (e) {
		const restored = revertNetwork();
		return { ok: false, error: restored ? e.message : `${e.message}；网络恢复失败，将继续重试` };
	}

	return { ok: true };
};

export function apply(cfg) {
	return withNetworkLock(() => applyNetwork(cfg));
};
