'use strict';

import { testState } from 'fs';
import { API_FILE, CRED_FILE, DELAY_FILE, PROFILE_FILE, readJson } from 'ecycloud.common';
import { CATALOG_FILE, CATALOG_INDEX, NODE_PROVIDER, PENDING_FILE, catalogOf, mergeNodes, nodesOf, trimCatalog } from 'ecycloud.profile';
import { loadNodes, runUpdates, update } from 'ecycloud.service';

let assertions = 0;
function check(ok, message) {
	assertions++;
	if (!ok)
		die(message);
};

function copy(value) { return json(sprintf('%J', value)); };
const runDir = '/etc/ecycloud/run/fixture-session';
const SELECTOR_FILE = '/etc/ecycloud/selectors.json';
const EVEN = 'ecy-panel-' + join('', map([ 1, 2, 3, 4 ], () => '0123456789abcdef'));
const WITH_STATIC = 'ecy-panel-' + join('', map([ 1, 2, 3, 4 ], () => 'fedcba9876543210'));
const proxy = id => ({ name: `node-${id}`, type: 'ss', server: '192.0.2.1', port: 8000 + id, cipher: 'aes-128-gcm', password: 'fixture' });
const fixed = { name: '模板节点', type: 'ss', server: '192.0.2.2', port: 443, cipher: 'aes-128-gcm', password: 'fixture' };
/* 面板上共 60 个节点，序号 = 编号 - 1；偶数编号的同时属于 EVEN 这个键 */
const TOTAL = 60;
const entry = id => ({ name: `node-${id}`, rank: id - 1, label: `夹具 ${id}`,
	providers: id % 2 ? [ NODE_PROVIDER ] : [ NODE_PROVIDER, EVEN ], proxy: proxy(id) });
const namesOf = list => join(',', map(list, item => type(item) == 'object' ? item.name : item));

/* 面板下发的那一部分：全部节点取前 4 个，EVEN 取前 2 个；WITH_STATIC 与 EVEN 同键，左侧多一个模板里写死的节点 */
function panelProfile(stamp) {
	const providers = {};
	providers[NODE_PROVIDER] = { type: 'file', path: `${NODE_PROVIDER}.json`, payload: [ proxy(1), proxy(2), proxy(3), proxy(4), fixed ] };
	providers[EVEN] = { type: 'file', path: `${EVEN}.json`, members: [ 'node-2', 'node-4' ] };
	providers[WITH_STATIC] = { type: 'file', path: `${WITH_STATIC}.json`, members: [ '模板节点', 'node-2', 'node-4' ] };
	const catalog = { stamp, providers: {}, ranks: { 'node-1': 0, 'node-2': 1, 'node-3': 2, 'node-4': 3 } };
	catalog.providers[NODE_PROVIDER] = { key: NODE_PROVIDER, total: TOTAL, head: 4 };
	catalog.providers[EVEN] = { key: EVEN, total: TOTAL / 2, head: 2 };
	catalog.providers[WITH_STATIC] = { key: EVEN, total: TOTAL / 2, head: 2 };
	return {
		revision: 'r-' + stamp, catalog,
		offline_authorization: { issued_at: 1, valid_until: 2000000000 },
		node_labels: { 'node-1': '夹具 1', 'node-2': '夹具 2', 'node-3': '夹具 3', 'node-4': '夹具 4' },
		config: {
			proxies: [], 'proxy-providers': providers,
			'proxy-groups': [
				{ name: '代理', type: 'select', proxies: [ 'DIRECT' ], use: [ NODE_PROVIDER ], 'default-selected': 'node-1' },
				{ name: '偶数', type: 'url-test', use: [ EVEN ], 'exclude-filter': '^ecy-panel-empty$', 'empty-fallback': 'REJECT' },
				{ name: '带模板', type: 'select', use: [ WITH_STATIC ] }
			],
			rules: [ 'MATCH,代理' ]
		}
	};
};

/* 并入算法：两种格式、序号位置、不带序号的成员、占位节点 */
const listed = panelProfile('s1');
check(catalogOf({}) == null && catalogOf({ catalog: [] }) === false && catalogOf({ catalog: { ...listed.catalog, stamp: 1 } }) === false &&
	catalogOf({ catalog: { ...listed.catalog, ranks: { 'node-1': '0' } } }) === false && catalogOf(listed) == listed.catalog,
	'节点目录缺失、格式不对与正常三种情形必须分清');
mergeNodes(listed, [ entry(50), entry(31), entry(3), { ...entry(9), proxy: proxy(8) }, { name: 'node-7' }, entry(6) ]);
check(namesOf(listed.config['proxy-providers'][NODE_PROVIDER].payload) == 'node-1,node-2,node-3,node-4,node-6,node-31,node-50,模板节点',
	'并入的节点必须按序号排在带序号成员之间，模板里写死的节点不动，已有与格式不对的节点忽略');
check(namesOf(listed.config['proxy-providers'][EVEN].members) == 'node-2,node-4,node-6,node-50' &&
	namesOf(listed.config['proxy-providers'][WITH_STATIC].members) == '模板节点,node-2,node-4,node-6,node-50',
	'节点只并入 key 在其 providers 里的节点订阅，同键的节点订阅都要并入');
check(listed.catalog.ranks['node-31'] == 30 && listed.node_labels['node-50'] == '夹具 50' && listed.catalog.ranks['node-9'] == null,
	'并入后必须补上序号与显示名');
mergeNodes(listed, [ { ...entry(1), name: 'node-0', rank: -1, proxy: { ...proxy(1), name: 'node-0' } } ]);
check(namesOf(listed.config['proxy-providers'][NODE_PROVIDER].payload) == 'node-0,node-1,node-2,node-3,node-4,node-6,node-31,node-50,模板节点',
	'序号最小的节点必须排到最前');
const restored = panelProfile('s1');
restored.config['proxy-providers'][EVEN] = { type: 'file', path: `${EVEN}.json`, payload: [ { name: 'ecy-panel-empty', type: 'reject' } ] };
restored.config['proxy-providers'][WITH_STATIC] = { type: 'file', path: `${WITH_STATIC}.json`, payload: [ fixed, proxy(2), proxy(4) ] };
mergeNodes(restored, [ entry(8), entry(3) ]);
check(namesOf(restored.config['proxy-providers'][EVEN].payload) == 'node-8' &&
	namesOf(restored.config['proxy-providers'][WITH_STATIC].payload) == '模板节点,node-2,node-4,node-8' &&
	restored.config['proxy-providers'][WITH_STATIC].payload[3].port == 8008,
	'已还原的格式并入的是完整节点，占位节点在并入真实节点后去掉');
const trimmed = trimCatalog(listed, { 'node-0': true, 'node-1': true, 'node-3': true, 'node-2': true, 'node-50': true, '模板节点': true });
check(join(',', sort(keys(trimmed.ranks))) == 'node-0,node-1,node-2,node-3,node-50' && trimmed.providers[NODE_PROVIDER].head == 4 &&
	trimmed.providers[EVEN].head == 1 && trimmed.providers[WITH_STATIC].head == 1 && trimmed.providers[EVEN].total == 30 && trimmed.stamp == 's1',
	'本机再裁剪后，序号只留装入的节点，已带前缀收缩到第一个被裁掉的成员之前');

testState.config = { run_dir: runDir, site_url: 'https://panel.test', sub_url: 'https://sub.test', enabled: '1', mode: 'tun' };
testState.files[CRED_FILE] = sprintf('%J', { email: 'router@test', token: 'synthetic-token', session_id: 'fixture-session', account_key: 'fixture-session', device_id: 'fixture', expires_at: '2030-01-01T00:00:00Z' });
testState.files[API_FILE] = sprintf('%J', { port: 19090, secret: 'synthetic-secret', speed: 'synthetic-speed' });
testState.files[`${runDir}/geoip.metadb`] = 'fixture';
testState.files[`${runDir}/GeoSite.dat`] = 'fixture';
testState.files['/proc/self/status'] = 'Name:\tucode\nPid:\t4242\n';
global.system = command => { push(testState.commands, command); return 0; };

let panelStamp = 's1';
let namesStamp = null;
let nodesFailure = null;
let kernelUp = false;
let providerFails = false;
let selected = 'node-1';
let requests = [];
testState.onRequest = () => {
	for (let path, text in testState.files) {
		if (!match(path, /\/req-[a-f0-9]+\.conf$/))
			continue;
		const body = testState.files[replace(path, /\.conf$/, '.json')];
		const url = match(text, /url = "([^"]+)"/)[1];
		push(requests, { url, text, body: body != null ? json(body) : null });
		testState.httpStatus = 200;
		if (index(url, '/user/account-status') >= 0)
			testState.response = { ret: 1, data: { enable: 1 } };
		else if (index(url, '/user/profile') >= 0)
			testState.response = { ret: 1, data: { config_revision: 'changed' } };
		else if (index(url, '/config/clash') >= 0)
			testState.response = { ret: 1, data: panelProfile(panelStamp) };
		else if (index(url, '/config/nodes') >= 0) {
			const query = json(body);
			if (nodesFailure != null) {
				testState.httpStatus = nodesFailure;
				testState.response = { ret: 0, msg: 'fixture panel failure' };
				continue;
			}
			let found = [];
			let more = false;
			if (query.names != null) {
				for (let name in query.names) {
					const id = +substr(name, 5);
					if (id >= 1 && id <= TOTAL)
						push(found, entry(id));
				}
				found = sort(found, (a, b) => a.rank - b.rank);
			} else {
				const members = [];
				for (let id = 1; id <= TOTAL; id++)
					if ((query.provider == NODE_PROVIDER || (query.provider == EVEN && id % 2 == 0)) &&
					    (!length(query.search) || index(entry(id).label, query.search) >= 0))
						push(members, entry(id));
				found = slice(members, query.offset, query.offset + query.limit);
				more = length(members) > query.offset + query.limit;
			}
			testState.response = { ret: 1, data: { stamp: namesStamp ?? panelStamp, more, nodes: found } };
		} else if (index(url, 'http://127.0.0.1:19090/') == 0) {
			if (!kernelUp) {
				testState.httpStatus = 0;
				testState.response = null;
			} else if (index(url, '/providers/proxies/') >= 0) {
				testState.httpStatus = providerFails ? 500 : 200;
				testState.response = providerFails ? { message: 'fixture provider failed' } : {};
			} else if (index(url, '/proxies/') >= 0 && index(text, 'request = "PUT"') >= 0) {
				selected = json(body).name;
				testState.response = {};
			} else if (index(url, '/proxies/') >= 0)
				testState.response = { type: 'Selector', now: selected, all: [ 'DIRECT', ...map(nodesOf(readJson(`${runDir}/config.json`)), node => node.name) ] };
			else
				testState.response = { version: 'fixture' };
		} else
			testState.response = {};
	}
};
const sent = part => filter(requests, request => index(request.url, part) >= 0);

/* 取配置：声明上限、补齐选过的节点、缓存目录元数据、删掉本机的冷目录 */
testState.files[SELECTOR_FILE] = sprintf('%J', { account: 'router@test', selected: { '代理': 'node-50', '带模板': 'DIRECT', '偶数': 'node-2' },
	recent: [ 'node-31', 'node-3', 'node-999' ] });
testState.files[CATALOG_FILE] = '{}';
testState.files[CATALOG_INDEX] = '{}';
let result = update(true);
check(result.ok && result.changed, `分页下发的配置必须能通过检查并暂存：${result.error}`);
check(index(sent('/config/clash')[0].text, 'X-ECY-Node-Catalog: 5000') >= 0, '取配置必须声明本机的节点副本上限');
check(length(sent('/config/nodes')) == 1 && sprintf('%J', sent('/config/nodes')[0].body) == sprintf('%J', { names: [ 'node-31', 'node-999', 'node-50' ] }) &&
	index(sent('/config/nodes')[0].text, 'request = "POST"') >= 0,
	'用户选过而面板没带的节点必须按名取回，已有的节点与分组名、内置出站不取');
let saved = readJson(PENDING_FILE);
check(namesOf(nodesOf(saved.config)) == 'node-1,node-2,node-3,node-4,node-31,node-50,模板节点' &&
	namesOf(saved.config['proxy-providers'][EVEN].payload) == 'node-2,node-4,node-50' &&
	namesOf(saved.config['proxy-providers'][WITH_STATIC].payload) == '模板节点,node-2,node-4,node-50',
	'取回的节点必须并入缓存里对应的节点订阅');
check(saved.catalog.stamp == 's1' && saved.catalog.ranks['node-50'] == 49 && saved.catalog.providers[EVEN].total == 30 &&
	saved.node_labels['node-31'] == '夹具 31' && saved.partial[NODE_PROVIDER] && saved.partial[EVEN] && saved.partial[WITH_STATIC],
	'缓存必须保存节点目录，并标出还有成员留在面板的节点订阅');
check(testState.files[CATALOG_FILE] == null && testState.files[CATALOG_INDEX] == null, '节点目录分页时不在本机存整份节点目录，已有的要删掉');

/* 取配置与按名取之间面板换了目录：重取一次配置，仍对不上就报错，不拿对不上的节点并入 */
requests = [];
namesStamp = 's0';
result = update(true);
check(!result.ok && result.error == '面板节点已变化，请重试' && length(sent('/config/clash')) == 2 && length(sent('/config/nodes')) == 2,
	'按名取到的节点与配置不是同一版目录时必须重取配置，不能并入');
namesStamp = null;
check(readJson(PENDING_FILE).revision == 'r-s1', '取配置失败不能动已有缓存');

/* 本机上限比面板给的还小：再裁剪后目录跟着收缩 */
testState.files['/proc/meminfo'] = 'MemTotal:        1152 kB\n';
requests = [];
result = update(true);
saved = readJson(PENDING_FILE);
check(result.ok && index(sent('/config/clash')[0].text, 'X-ECY-Node-Catalog: 6') >= 0, '上限随路由器内存变化');
const kept = filter(map(nodesOf(saved.config), node => node.name), name => name != '模板节点');
check(length(kept) < 6 && 'node-50' in kept && 'node-31' in kept && join(',', sort(keys(saved.catalog.ranks))) == join(',', sort([ ...kept ])),
	'本机裁剪后保留用户选过的节点，目录序号与缓存里的节点一致');
check(saved.catalog.providers[NODE_PROVIDER].head <= 4 && saved.catalog.providers[NODE_PROVIDER].head == length(filter(kept, name => +substr(name, 5) <= saved.catalog.providers[NODE_PROVIDER].head)),
	'已带前缀长度只数仍在缓存里的连续成员');
delete testState.files['/proc/meminfo'];

/* 之后的用例用内核在跑的状态：把暂存的配置当作已提交 */
requests = [];
update(true);
testState.files[PROFILE_FILE] = testState.files[PENDING_FILE];
delete testState.files[PENDING_FILE];
testState.files['/proc/41/cmdline'] = `/usr/libexec/mihomo\0-d\0${runDir}\0`;
kernelUp = true;

/* 装入未知节点：按名取回、并入、只重载节点订阅、落盘缓存 */
requests = [];
testState.commands = [];
result = loadNodes([ 'node-40', 'node-2', 'DIRECT', 'node-998', 'node-40' ]);
saved = readJson(PROFILE_FILE);
check(result.ok && sprintf('%J', sent('/config/nodes')[0].body) == sprintf('%J', { names: [ 'node-40', 'node-998' ] }), '只按名取缓存里没有的节点');
check(namesOf(nodesOf(saved.config)) == 'node-1,node-2,node-3,node-4,node-31,node-40,node-50,模板节点' &&
	namesOf(saved.config['proxy-providers'][EVEN].payload) == 'node-2,node-4,node-40,node-50' && saved.catalog.ranks['node-40'] == 39 &&
	saved.node_labels['node-40'] == '夹具 40', '取回的节点必须并入缓存');
check(readJson(SELECTOR_FILE).recent[0] == 'node-40' && !('node-998' in readJson(SELECTOR_FILE).recent), '装入的节点记入最近装入名单，面板没给的不记');
check(length(filter(requests, request => index(request.url, '/providers/proxies/') >= 0 && index(request.text, 'request = "PUT"') >= 0)) == 3 &&
	readJson(`${runDir}/${EVEN}.json`).proxies[2].name == 'node-40', '节点文件必须重写并让内核逐个重载');
check(!length(filter(requests, request => index(request.url, '/configs') >= 0 || index(request.url, '/connections') >= 0)) &&
	!length(filter(testState.commands, command => index(command, '/etc/init.d/') >= 0)), '装入节点不能重载整份配置或重启内核');

requests = [];
const untouched = testState.files[PROFILE_FILE];
result = loadNodes([ 'node-999', 'node-40' ]);
check(result.ok && length(sent('/config/nodes')) == 1 && !length(sent('/providers/proxies/')) && testState.files[PROFILE_FILE] == untouched,
	'面板没给的节点（已删除或无权限）不改动缓存，也不算失败');

/* 内核拒收：缓存与最近装入名单恢复原样 */
providerFails = true;
let recent = sprintf('%J', readJson(SELECTOR_FILE).recent);
result = loadNodes([ 'node-41' ]);
check(!result.ok && result.error == 'fixture provider failed' && testState.files[PROFILE_FILE] == untouched &&
	sprintf('%J', readJson(SELECTOR_FILE).recent) == recent, '内核拒收装入的节点时撤回缓存与最近装入名单');
providerFails = false;

/* 面板不可达：报接口失败，不动缓存 */
nodesFailure = 503;
result = loadNodes([ 'node-41' ]);
check(!result.ok && !result.stale && result.error == 'fixture panel failure' && testState.files[PROFILE_FILE] == untouched &&
	sprintf('%J', readJson(SELECTOR_FILE).recent) == recent, '面板接口失败时不改动缓存');
nodesFailure = null;

/* 目录换版：不并入，记进最近装入名单，交给配置刷新一并取回 */
panelStamp = 's2';
result = loadNodes([ 'node-41' ]);
check(!result.ok && result.stale && testState.files[PROFILE_FILE] == untouched && readJson(SELECTOR_FILE).recent[0] == 'node-41',
	'目录换版时不并入对不上的节点，并把它记下留给配置刷新');
testState.files[SELECTOR_FILE] = sprintf('%J', { ...readJson(SELECTOR_FILE), recent: json(recent) });
panelStamp = 's1';

if (length(ARGV[0])) {
	const rpc = loadfile(ARGV[0], { raw_mode: true })()['luci.ecycloud'];

	/* 分组标记与联网搜索 */
	const offline = call => {
		const cmdline = testState.files['/proc/41/cmdline'];
		delete testState.files['/proc/41/cmdline'];
		kernelUp = false;
		const reply = call();
		testState.files['/proc/41/cmdline'] = cmdline;
		kernelUp = true;
		return reply;
	};
	let view = offline(() => rpc.groups.call({ args: {} }));
	check(!view.error && length(filter(view.groups, group => group.partial && group.remote)) == 3,
		'还有成员留在面板的分组必须标出 partial 与 remote');
	requests = [];
	let found = rpc.search_nodes.call({ args: { group: '偶数', keyword: '', offset: -1 } });
	const unknownEven = [];
	for (let id = 6; id <= TOTAL; id += 2)
		if (id != 40 && id != 50)
			push(unknownEven, `node-${id}`);
	check(found.ok && sprintf('%J', sent('/config/nodes')[0].body) == sprintf('%J', { provider: EVEN, offset: 2, limit: 100 }) &&
		namesOf(found.nodes) == join(',', unknownEven) && found.more == false && found.next == 102,
		'不带搜索词时从已带前缀之后往下取，只返回缓存里没有的节点');
	check(found.nodes[0].label == '夹具 6' && found.nodes[0].protocol == 'Shadowsocks' && found.nodes[0].delay == 0 && !found.nodes[0].is_group,
		'搜到的节点带界面要显示的名称与协议');
	requests = [];
	found = rpc.search_nodes.call({ args: { group: '代理', keyword: '夹具 5', offset: -1 } });
	check(found.ok && sent('/config/nodes')[0].body.search == '夹具 5' && sent('/config/nodes')[0].body.offset == 0 &&
		namesOf(found.nodes) == 'node-5,node-51,node-52,node-53,node-54,node-55,node-56,node-57,node-58,node-59',
		'带搜索词时从头搜，已在缓存里的 node-50 不重复返回');
	check(rpc.search_nodes.call({ args: { group: '不存在', keyword: 'x', offset: -1 } }).nodes[0] == null &&
		rpc.search_nodes.call({ args: { group: '代理', keyword: 'x', offset: 'x' } }).ok, '未知分组与非法 offset 不报错也不乱取');
	nodesFailure = 503;
	found = rpc.search_nodes.call({ args: { group: '代理', keyword: '夹具', offset: -1 } });
	check(!found.ok && found.msg == 'fixture panel failure', '面板不可达时搜索按接口失败返回');
	nodesFailure = null;
	panelStamp = 's2';
	found = rpc.search_nodes.call({ args: { group: '代理', keyword: '夹具', offset: -1 } });
	check(found.ok && found.pending && length(found.id) && found.nodes == null, '目录换版时搜索改为排一次配置刷新');
	panelStamp = 's1';
	runUpdates();

	/* 选中未知节点：后台按名取回、装入、再选中 */
	requests = [];
	let picked = rpc.select.call({ args: { group: '代理', name: 'node-44' } });
	check(picked.ok && picked.pending, '选中缓存里没有的节点必须交给后台任务');
	runUpdates();
	let task = filter(rpc.status.call({ args: {} }).update_tasks, item => item.id == picked.id)[0];
	check(task.state == 'done' && task.ok && selected == 'node-44' && 'node-44' in map(nodesOf(readJson(PROFILE_FILE).config), node => node.name) &&
		readJson(SELECTOR_FILE).selected['代理'] == 'node-44' && readJson(SELECTOR_FILE).recent[0] == 'node-44',
		`后台任务必须装入并选中节点：${task.msg}`);

	/* 选中时目录已换版：先刷新配置（把它一并取回），再选中 */
	panelStamp = 's2';
	requests = [];
	picked = rpc.select.call({ args: { group: '代理', name: 'node-46' } });
	runUpdates();
	task = filter(rpc.status.call({ args: {} }).update_tasks, item => item.id == picked.id)[0];
	saved = readJson(PROFILE_FILE);
	check(task.ok && selected == 'node-46' && length(sent('/config/clash')) == 1 && saved.catalog.stamp == 's2' &&
		'node-46' in map(nodesOf(saved.config), node => node.name), `目录换版时选中节点必须先刷新配置再装入：${task.msg}`);

	/* 整组测试带上界面列出的节点 */
	delete testState.files[DELAY_FILE];
	const queued = offline(() => rpc.test_group.call({ args: { group: '偶数', names: [ 'node-58', 'DIRECT', 'node-58', 7, 'node-x' ] } }));
	const queue = readJson(DELAY_FILE)?.queue ?? [];
	check(queued.ok && 'node-58' in queue && 'node-2' in queue && !('DIRECT' in queue) && !('node-x' in queue) &&
		length(filter(queue, name => name == 'node-58')) == 1, '整组测延迟只接受界面列出的节点标识，并与已有成员去重');

	/* 面板整份下发（没有节点目录）时不走联网搜索 */
	const whole = copy(readJson(PROFILE_FILE));
	whole.catalog = null;
	whole.partial = null;
	testState.files[PROFILE_FILE] = sprintf('%J', whole);
	requests = [];
	view = offline(() => rpc.groups.call({ args: {} }));
	found = rpc.search_nodes.call({ args: { group: '代理', keyword: '夹具', offset: -1 } });
	offline(() => rpc.test_group.call({ args: { group: '偶数', names: [ 'node-59' ] } }));
	check(!length(filter(view.groups, group => group.partial || group.remote)) && found.ok && !length(found.nodes) && !length(sent('/config/nodes')) &&
		'node-2' in readJson(DELAY_FILE).queue && !('node-59' in readJson(DELAY_FILE).queue),
		'整份下发时分组不标 remote，搜索不联网，整组测试不接受额外节点');
}

printf('OpenWrt 节点目录分页回归通过：%d 项断言。\n', assertions);
