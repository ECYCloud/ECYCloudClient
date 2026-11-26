'use strict';

import { testState } from 'fs';
import { CONF_DIR, CRED_FILE, STATE_FILE, commitConfig, ensureConfig, readJson } from 'ecycloud.common';
import { block, prepare } from 'ecycloud.service';
import { cursor } from 'uci';

let assertions = 0;
function check(ok, message) { assertions++; if (!ok) die(message); };
global.time = () => 1791126000;
global.system = command => { push(testState.commands, command); return 0; };

const CONFIG_FILE = '/etc/config/ecycloud';
const DEFAULTS = '/usr/share/ecycloud/config.default';
const defaults = "config ecycloud 'config'\n\toption enabled '0'\n";
function free(path, kib) {
	testState.responses[`df -Pk '${path}' 2>/dev/null`] = {
		text: `Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/root 100000 99000 ${kib} 99% /\n`, status: 0
	};
}

testState.files[DEFAULTS] = defaults;
testState.configMissing = true;
free('/etc/config', 4);
check(!ensureConfig() && testState.files[CONFIG_FILE] == null, '剩余空间不足时不得重写配置文件');
free('/etc/config', 1024);
check(ensureConfig() && testState.files[CONFIG_FILE] == defaults, '配置段缺失时必须按出厂默认值补回');
testState.configMissing = false;
delete testState.files[CONFIG_FILE];
check(ensureConfig() && testState.files[CONFIG_FILE] == null, '配置段存在时不得改动配置文件');

let commits = 0;
const uci = { ...cursor(), commit: () => ++commits > 0 };
free('/etc/config', 4);
check(!commitConfig(uci) && commits == 0, '剩余空间不足时不得提交配置，避免写出空文件');
free('/etc/config', 1024);
check(commitConfig(uci) && commits == 1, '空间充足时照常提交配置');

testState.config = { run_dir: '/etc/ecycloud/run/fixture-session', enabled: '1' };
testState.files[CRED_FILE] = sprintf('%J', { email: 'fixture@test', token: 'synthetic-token', session_id: 'fixture-session',
	account_key: 'fixture-session', device_id: 'fixture', expires_at: '2030-01-01T00:00:00Z' });
free(CONF_DIR, 10 * 1024);
check(!prepare(false) && readJson(STATE_FILE)?.error == '未找到 mihomo 内核，请在路由器上安装 mihomo-meta 后重试',
	'没装内核时必须直接提示安装内核，不能报成配置校验失败');
testState.files['/usr/libexec/mihomo'] = '';
check(!prepare(false), '缺 geodata 且剩余不足 24 MiB 时不得启动');
const failed = readJson(STATE_FILE);
check(failed?.stage == 'failed' && failed?.error == '存储空间不足：路由器剩余 10 MiB，启动至少需要 24 MiB，请清理存储或扩容后重试',
	'空间不足必须在状态里写明剩余与所需空间');

testState.files['/etc/ecycloud/run/fixture-session/geoip.metadb'] = 'x';
testState.files['/etc/ecycloud/run/fixture-session/GeoSite.dat'] = 'x';
free(CONF_DIR, 2 * 1024);
check(!prepare(false) && readJson(STATE_FILE)?.error == '存储空间不足：路由器剩余 2 MiB，启动至少需要 4 MiB，请清理存储或扩容后重试',
	'已有 geodata 时只要求运行余量');

const RENEWING = `${CONF_DIR}/renewing.json`;
free(CONF_DIR, 4);
block('fixture-expired', true);
check(testState.files[RENEWING] == null, '闪存剩余不足时不得写续期状态，避免把文件写成空的');
free(CONF_DIR, 1024);
block('fixture-expired', true);
check(readJson(RENEWING)?.reason == 'fixture-expired' && testState.writes[RENEWING] == null &&
	length(filter(keys(testState.writes), path => index(path, `${RENEWING}.`) == 0 && match(path, /\.tmp$/))) == 1 &&
	!length(filter(keys(testState.files), path => index(path, `${RENEWING}.`) == 0)), '空间充足时续期状态经临时文件改名原子写入');

if (length(ARGV[0])) {
	const rpc = loadfile(ARGV[0], { raw_mode: true })()['luci.ecycloud'];
	testState.configMissing = true;
	delete testState.files[DEFAULTS];
	const reply = rpc.start.call({ args: { refreshed: true } });
	check(reply?.ok == false && reply?.msg == '设置保存失败，路由器存储空间可能已满', '连接开关写不进配置时必须明确报错，不能静默取消');
	testState.configMissing = false;
}

print(`storage guard: ${assertions} assertions passed\n`);
