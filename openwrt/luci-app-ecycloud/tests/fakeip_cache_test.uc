'use strict';

import { testState } from 'fs';
import { API_FILE, CRED_FILE } from 'ecycloud.common';
import { store } from 'ecycloud.profile';
import { persistCache, prepare, watchdog } from 'ecycloud.service';

let assertions = 0;
function check(ok, message) { assertions++; if (!ok) die(message); };
let now = 1791126000;
global.time = () => now;

const runDir = '/etc/ecycloud/run/fixture-session';
const link = `${runDir}/cache.db`;
const saved = `${runDir}/cache.db.saved`;
const live = '/var/run/ecycloud/cache/fixture-session.db';
let flashWrites = 0;
let onCopy = null;
let rounds = 0;
const writeRounds = [];
global.system = command => {
	push(testState.commands, command);
	const m = match(command, /^cp -f -- '([^']+)' '([^']+)' 2>\/dev\/null$/);
	if (!m)
		return 0;
	const source = testState.links?.[m[1]] ?? m[1];
	if (!exists(testState.files, source))
		return 1;
	testState.files[m[2]] = testState.files[source];
	if (index(m[2], '/etc/') == 0) {
		flashWrites++;
		push(writeRounds, rounds);
	}
	if (onCopy)
		onCopy(m[1]);
	return 0;
};

testState.config = { run_dir: runDir, site_url: 'https://panel.test', sub_url: 'https://sub.test', enabled: '0', mode: 'tproxy', refresh_interval: '0' };
testState.files[CRED_FILE] = sprintf('%J', { email: 'fixture@test', token: 'synthetic-token', device_id: 'fixture',
	session_id: 'fixture-session', account_key: 'fixture-session', expires_at: '2030-01-01T00:00:00Z' });
testState.files[API_FILE] = sprintf('%J', { port: 19090, secret: 'synthetic-secret', speed: 'synthetic-speed' });
testState.files['/usr/libexec/mihomo'] = '';
testState.files[`${runDir}/geoip.metadb`] = 'geoip';
testState.files[`${runDir}/GeoSite.dat`] = 'geosite';
testState.links = {};
check(store({ revision: 'r1', config: { proxies: [ { name: 'fixture-node', type: 'ss', server: 'node.test', port: 10001,
	cipher: 'aes-128-gcm', password: 'fixture' } ], 'proxy-groups': [ { name: 'Fixture', type: 'select', proxies: [ 'fixture-node' ] } ],
	rules: [ 'MATCH,Fixture' ], 'rule-providers': {} }, offline_authorization: { issued_at: now - 60, valid_until: now + 7 * 86400 } }),
	'夹具配置缓存保存失败');

testState.files[link] = 'legacy-db';
check(prepare(), '启动准备必须成功');
check(testState.links[link] == live && testState.files[saved] == 'legacy-db' && testState.files[live] == 'legacy-db' && testState.files[link] == null,
	'旧版留在闪存的 cache.db 必须改名为闪存副本，内核改从 tmpfs 读写，原有映射与选中节点不丢');

testState.files[live] = 'db-after-domains';
flashWrites = 0;
persistCache();
check(testState.files[saved] == 'db-after-domains' && flashWrites == 1 && testState.links[link] == live,
	'正常停止后必须把 tmpfs 里的缓存写回闪存');
persistCache();
check(flashWrites == 1, '缓存没有变化时停止或重启不得再写闪存');

testState.files['/proc/41/cmdline'] = '/usr/libexec/mihomo\0-d\0/etc/ecycloud/run/fixture-session\0';
testState.paths['/proc/41'] = true;
let waits = 0;
global.sleep = () => {
	if (++waits == 3) {
		testState.files[live] = 'db-with-pool-state';
		delete testState.paths['/proc/41'];
		delete testState.files['/proc/41/cmdline'];
	}
};
persistCache();
check(waits == 3 && testState.files[saved] == 'db-with-pool-state', '必须等内核退出、写完地址池状态后再写回闪存');

testState.files[live] = 'db-v2';
onCopy = source => {
	if (source == live) {
		testState.files[live] = 'db-v3';
		onCopy = null;
	}
};
flashWrites = 0;
persistCache();
check(testState.files[saved] == 'db-v3' && flashWrites == 1, '拷贝期间内核写了缓存时必须重拷，不能把不一致的副本写进闪存');

delete testState.files[live];
check(prepare() && testState.files[live] == 'db-v3' && testState.links[link] == live,
	'断电重启后 tmpfs 清空，启动时必须从闪存副本恢复映射与选中节点');

delete testState.links[link];
testState.files[link] = 'rebuilt-by-kernel';
testState.files[live] = 'invalid-db';
check(prepare() && testState.files[saved] == 'rebuilt-by-kernel' && testState.files[live] == 'rebuilt-by-kernel' && testState.links[link] == live,
	'内核把损坏的缓存换成闪存上的新文件后，下次启动以新文件为准并重新放回 tmpfs');

testState.files['/proc/41/cmdline'] = '/usr/libexec/mihomo\0-d\0/etc/ecycloud/run/fixture-session\0';
delete testState.links[link];
testState.files[link] = 'opened-by-old-kernel';
check(prepare() && testState.files[link] == 'opened-by-old-kernel' && testState.links[link] == null,
	'旧内核还开着闪存上的 cache.db 时不能搬走它，等下次内核停下再迁移');
delete testState.files[link];
check(prepare() && testState.links[link] == live, '迁移条件满足后照常放到 tmpfs');

testState.response = { version: 'fixture' };
testState.httpStatus = 200;
splice(writeRounds, 0);
const busy = source => {
	if (source == live)
		testState.files[live] = `${testState.files[live]}+`;
};
global.sleep = () => {
	now += 1800;
	testState.files[live] = `db-round-${++rounds}`;
	onCopy = rounds == 12 ? busy : null;
	if (rounds == 30)
		testState.files['/var/run/ecycloud/stopping'] = '';
};
watchdog();
delete testState.files['/var/run/ecycloud/stopping'];
check(join(',', writeRounds) == '13,25', `内核运行中每 6 小时写回一次闪存，正赶上连续写入时下一轮再试，应在第 13、25 轮写，实际 ${join(',', writeRounds)}`);

printf('OpenWrt Fake-IP 缓存回归通过：%d 项断言。\n', assertions);
