'use strict';

import { access, chmod, popen, readfile, writefile } from 'fs';

import { PROFILE_FILE, ROUTING_MARK, ensureDir, mihomoBin, readJson, shellquote,
         writePrivateJson } from 'ecycloud.common';

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

export function cached() {
	return readJson(PROFILE_FILE);
}

export function store(remote) {
	return writePrivateJson(PROFILE_FILE, {
		revision: remote.revision ?? '',
		config: remote.config,
		node_labels: remote.node_labels ?? {},
		fetched_at: time()
	});
}

function tunSection(cfg) {
	return {
		enable: cfg.mode == 'tun',
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
		'route-exclude-address': EXCLUDED_ROUTES
	};
}

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
		tun: tunSection(cfg),
		profile: {
			'store-selected': true,
			'store-fake-ip': false
		}
	};
}

function fallbacks(cfg) {
	return {
		ipv6: cfg.ipv6,
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
}

export function assemble(remote, cfg, api) {
	if (type(remote?.proxies) != 'array' || !length(remote.proxies))
		return { ok: false, error: '面板未下发任何可用节点' };

	if (type(remote?.rules) != 'array' || !length(remote.rules))
		return { ok: false, error: '面板配置缺少分流规则' };

	const config = { ...remote };

	for (let key, value in fallbacks(cfg))
		if (!exists(config, key))
			config[key] = value;

	const merged = { ...config, ...overrides(cfg, api) };

	/* dns 整段归面板，但 listen 会让内核对外开 DNS 口；路由器上改成只监听回环供 dnsmasq 转发 */
	merged.dns = { ...(type(merged.dns) == 'object' ? merged.dns : {}) };
	merged.dns.enable = true;
	merged.dns.listen = `127.0.0.1:${cfg.dnsPort}`;

	/* 面板下发的 geox-url 指向 github，而路由器没有随包 geodata，首次启动全靠它下载。
	   只改镜像实际托管的这两个键：geoip / asn 镜像上没有，改过去就是 404 */
	if (length(cfg.geoxBase)) {
		merged['geox-url'] = { ...(type(merged['geox-url']) == 'object' ? merged['geox-url'] : {}) };
		merged['geox-url'].mmdb = `${cfg.geoxBase}/geoip.metadb`;
		merged['geox-url'].geosite = `${cfg.geoxBase}/GeoSite.dat`;
	}

	return { ok: true, config: merged };
}

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
}

export function rollback(runDir) {
	const previous = readfile(`${runDir}/config.json.bak`);
	return previous != null && writefile(`${runDir}/config.json`, previous) != null;
}

export function geodataMissing(runDir) {
	return !access(`${runDir}/geoip.metadb`) || !access(`${runDir}/GeoSite.dat`);
}

export function validate(runDir) {
	const proc = popen(sprintf('timeout 300 %s -t -f %s -d %s 2>&1',
		shellquote(mihomoBin()),
		shellquote(`${runDir}/config.json`),
		shellquote(runDir)));

	if (!proc)
		return { ok: false, error: '无法执行 mihomo' };

	const out = proc.read('all') ?? '';
	const code = proc.close();

	if (code == 0)
		return { ok: true };

	let reason = '';
	for (let line in split(out, '\n'))
		if (length(trim(line)))
			reason = trim(line);

	return { ok: false, error: length(reason) ? reason : `mihomo -t 退出码 ${code}` };
}
