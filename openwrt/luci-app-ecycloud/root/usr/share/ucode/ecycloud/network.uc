'use strict';

import { access, lsdir, open, popen, readfile, unlink, writefile } from 'fs';
import { cursor } from 'uci';

import { NETWORK_FILE, NFT_DIR, NFT_TABLE, ROUTE_TABLE, ROUTING_MARK, STATE_DIR, TPROXY_MARK, TUN_ROUTE_TABLE, TUN_RULE_INDEX,
         appendNets, coreRunning, ensureDir, ensurePrivateDir, isIpNet, lanDevices, log, panelDirectNets, readJson, settings,
         uciList, writeJson } from 'ecycloud.common';

const RULESET_FILE = `${NFT_DIR}/ruleset-post/${NFT_TABLE}.nft`;
const DSTNAT_FILE = `${NFT_DIR}/chain-pre/dstnat/${NFT_TABLE}.nft`;
const FORWARD_FILE = `${NFT_DIR}/chain-pre/forward/${NFT_TABLE}.nft`;
const INPUT_FILE = `${NFT_DIR}/chain-pre/input/${NFT_TABLE}.nft`;
/* 须排在 sing-tun 规则之前，并与 TUN 规则同时清除：内核卡死而 TUN 仍在时，本机仍要能直连面板 */
const PANEL_RULE_INDEX = TUN_RULE_INDEX - 1;
const ROUTER_DNS_CONF = `${STATE_DIR}/router-dns.conf`;
const ROUTER_DNS_RULESET = `${STATE_DIR}/router-dns.nft`;
const ROUTER_DNS_TABLE = `${NFT_TABLE}_dns`;

/* fake-ip 段不能进保留地址表，那正是要送进内核的目标 */
const RESERVED4 = [
	'0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
	'172.16.0.0/12', '192.0.0.0/24', '192.88.99.0/24', '192.168.0.0/16',
	'224.0.0.0/4', '240.0.0.0/4'
];

const RESERVED6 = [ '::1/128', '100::/64', 'fc00::/7', 'fe80::/10', 'ff00::/8' ];

function bypassNets(nets, v6) {
	const extra = [];

	for (let net in nets) {
		if (!isIpNet(net))
			continue;
		if ((index(net, ':') >= 0) == v6)
			push(extra, net);
	}

	return extra;
};

function reserved4(cfg) {
	return appendNets(RESERVED4, bypassNets(cfg.bypass ?? [], false));
};

function reserved6(cfg) {
	return appendNets(RESERVED6, bypassNets(cfg.bypass ?? [], true));
};

/* 面板直连只给路由器自身：并进保留网段或 route-exclude-address 会让整个 LAN 访问这些地址时绕过内核 */
function panelNets(cfg, v6) {
	return !cfg.routerProxy || (v6 && !cfg.ipv6) ? [] : bypassNets(panelDirectNets(), v6);
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
		/* 回包（端口转发到 LAN 服务器的应答）与发往路由器自身地址的流量不是要代理的新连接 */
		'\t\tct direction reply accept',
		'\t\tfib daddr type local accept',
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
		`\t\tmeta nfproto ipv4 meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:${cfg.tproxyPort} meta mark set ${TPROXY_MARK} accept`);

	if (cfg.ipv6)
		push(lines, `\t\tmeta nfproto ipv6 meta l4proto { tcp, udp } tproxy ip6 to [::1]:${cfg.tproxyPort} meta mark set ${TPROXY_MARK} accept`);

	push(lines, '\t}');

	if (cfg.routerProxy) {
		push(lines,
			'',
			'\tchain output {',
			'\t\ttype route hook output priority mangle; policy accept;',
			`\t\tmeta mark ${ROUTING_MARK} accept`,
			'\t\tct direction reply accept',
			'\t\tmeta l4proto { tcp, udp } th dport 53 accept',
			'\t\tip daddr @reserved4 accept',
			cfg.ipv6 ? '\t\tip6 daddr @reserved6 accept' : '\t\tmeta nfproto ipv6 accept');
		for (let v6 in [ false, true ]) {
			const panel = panelNets(cfg, v6);
			if (length(panel))
				push(lines, `\t\t${v6 ? 'ip6' : 'ip'} daddr { ${join(', ', panel)} } accept`);
		}
		push(lines,
			`\t\tmeta l4proto { tcp, udp } meta mark set ${TPROXY_MARK}`,
			'\t}');
	}

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

function panelRouting(cfg) {
	for (let v6 in [ false, true ]) {
		const ip = v6 ? 'ip -6' : 'ip';
		if (system(`${ip} rule flush pref ${PANEL_RULE_INDEX} 2>/dev/null`) != 0)
			return false;
		for (let net in panelNets(cfg, v6))
			if (system(`${ip} rule add pref ${PANEL_RULE_INDEX} iif lo to ${net} lookup main`) != 0)
				return false;
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
	/* 默认目录随系统版本不同（23.05 为 /tmp/dnsmasq.d，24.10 起按实例名区分），未配置时只认 dnsmasq 启动脚本实际写下的那一个 */
	const dir = length(configured) ? split(configured, ',')[0]
		: match(readfile(`/var/etc/dnsmasq.conf.${section}`) ?? '', /(^|\n)conf-dir=([^,\n]+)/)?.[2];

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

function routerDnsPort(cfg) {
	return cfg.dnsPort > 1 ? cfg.dnsPort - 1 : cfg.dnsPort + 1;
};

function plainOption(value) {
	return type(value) == 'string' && length(value) > 0 && !match(value, /[[:cntrl:][:space:]]/);
};

/* 主 dnsmasq 已转给内核且缓存各客户端共用，无法只给路由器自身返回真实地址，只能另起实例 */
function routerDnsConf(cfg, section) {
	const uci = cursor();
	const resolv = uci.get('dhcp', section, 'resolvfile') ?? '/tmp/resolv.conf.d/resolv.conf.auto';
	const local = uci.get('dhcp', section, 'local');
	const port = +(uci.get('dhcp', section, 'port') ?? 53);
	const lines = [
		`port=${routerDnsPort(cfg)}`, 'interface=lo', 'bind-interfaces', 'user=dnsmasq', 'group=dnsmasq', 'pid-file=',
		'domain-needed', 'bogus-priv',
		uci.get('dhcp', section, 'noresolv') != '1' && plainOption(resolv) ? `resolv-file=${resolv}` : 'no-resolv',
		...map(filter(uciList(uci.get('dhcp', section, 'server')), plainOption), server => `server=${server}`)
	];
	if (plainOption(local) && match(local, /^\/.+\/$/) && port > 0)
		push(lines, `server=${local}127.0.0.1#${port}`);
	return `${join('\n', lines)}\n`;
};

/* 不走 fw4 include（断电重启后实例已不在，规则须一起消失），也不放进 inet ecycloud（TPROXY 的 include 每次 fw4 reload 都会清空它）。
   转回主实例的本地域查询以 dnsmasq 身份发出，不能再被引回本实例 */
function routerDnsRuleset(cfg) {
	const redirect = `meta l4proto { tcp, udp } th dport 53 redirect to :${routerDnsPort(cfg)}`;
	return join('\n', [
		`table inet ${ROUTER_DNS_TABLE}`,
		`flush table inet ${ROUTER_DNS_TABLE}`,
		`table inet ${ROUTER_DNS_TABLE} {`,
		'\tchain output {',
		'\t\ttype nat hook output priority -100; policy accept;',
		'\t\tmeta skuid dnsmasq accept',
		`\t\tip daddr 127.0.0.1 ${redirect}`,
		`\t\tip6 daddr ::1 ${redirect}`,
		'\t}',
		'}',
		''
	]);
};

function startRouterDns(cfg, section) {
	const ok = writefile(ROUTER_DNS_CONF, routerDnsConf(cfg, section)) != null &&
		system(`/usr/sbin/dnsmasq -C ${ROUTER_DNS_CONF} >/dev/null 2>&1`) == 0 &&
		writefile(ROUTER_DNS_RULESET, routerDnsRuleset(cfg)) != null &&
		system(`nft -f ${ROUTER_DNS_RULESET} >/dev/null 2>&1`) == 0;
	unlink(ROUTER_DNS_RULESET);
	return ok;
};

function routerDnsPids() {
	return filter(lsdir('/proc') ?? [], pid => match(pid, /^[0-9]+$/) &&
		index(readfile(`/proc/${pid}/cmdline`) ?? '', `-C\0${ROUTER_DNS_CONF}\0`) >= 0);
};

function stopRouterDns() {
	const tables = query('nft list tables 2>/dev/null');
	if (!tables.ok || (match(tables.text, /table inet ecycloud_dns([[:space:]]|$)/) &&
	    system(`nft delete table inet ${ROUTER_DNS_TABLE} 2>/dev/null`) != 0))
		return false;
	let pids = routerDnsPids();
	for (let attempt = 0; length(pids) && attempt < 20; attempt++) {
		system(`kill ${attempt < 10 ? '' : '-9 '}${join(' ', pids)} 2>/dev/null`);
		pids = routerDnsPids();
		if (length(pids))
			sleep(100);
	}
	return !length(pids) && (!access(ROUTER_DNS_CONF) || unlink(ROUTER_DNS_CONF));
};

export function applied() {
	return readJson(NETWORK_FILE);
};

export function intact(record) {
	return record?.router_dns != true || length(routerDnsPids()) > 0;
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
			for (let priority = PANEL_RULE_INDEX; priority <= TUN_RULE_INDEX + 10; priority++)
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
				if (priority >= PANEL_RULE_INDEX && priority <= TUN_RULE_INDEX + 10)
					ok = false;
			}
			if (match(routes.text, /table 1937([[:space:]]|$)/))
				ok = false;
		}
	}
	if (!revertDnsmasq(record?.dnsmasq))
		ok = false;
	if (!stopRouterDns())
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
	if (cfg.mode == 'tun' && !length(cfg.tunDevice))
		return { ok: false, error: 'TUN 网卡名只能包含 1 到 15 个字母、数字、下划线、点或连字符' };

	if (!revertNetwork())
		return { ok: false, error: '旧网络设置恢复失败，未应用新的代理规则' };

	const section = cfg.dnsHijack ? dnsmasqSection() : null;
	const dir = cfg.dnsHijack ? dnsmasqConfDir(section) : null;
	if (cfg.dnsHijack && !length(dir))
		return { ok: false, error: 'dnsmasq 配置目录不可用，DNS 未接入内核' };
	const record = { active: false, dnsmasq: cfg.dnsHijack ? `${dir}/ecycloud.conf` : null,
		router_dns: cfg.dnsHijack && !cfg.routerProxy };
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
				`\t\tiifname "${cfg.tunDevice}" oifname ${deviceSet(devices)} accept comment "!ecycloud: tun ingress"`,
				`\t\tiifname ${deviceSet(devices)} oifname "${cfg.tunDevice}" accept comment "!ecycloud: tun egress"`,
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

		if (!(cfg.mode == 'tproxy' ? routing(cfg, true) : panelRouting(cfg)))
			die('策略路由设置失败');

		if (record.router_dns && !startRouterDns(cfg, section))
			die(`路由器自身的 DNS 转发启动失败，请确认 127.0.0.1:${routerDnsPort(cfg)} 未被占用`);

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
