'use strict';

import { testState } from 'fs';
import { validate } from 'ecycloud.profile';

let assertions = 0;
function check(ok, message) { assertions++; if (!ok) die(message); };

const runDir = '/etc/ecycloud/run/fixture-session';
testState.files[`${runDir}/config.json`] = '{"profile":{},"proxies":[]}';
testState.commandStatus = 1;

/* mihomo -t 失败的真实输出：最后一行只说 test failed，原因在最后一条 level=error 的 msg 里 */
testState.commandText = 'time="2026-11-22T00:38:36.291206000-08:00" level=info msg="Can\'t find GeoSite.dat, start download"\n' +
	'time="2026-11-22T00:38:36.294895000-08:00" level=error msg="can\'t initial GeoSite: can\'t download GeoSite.dat: Get \\"https://127.0.0.1:1/GeoSite.dat\\": connection refused"\n' +
	'time="2026-11-22T00:38:36.294902000-08:00" level=error msg="rules[0] [GEOSITE,cn,DIRECT] error: can\'t download GeoSite.dat: Get \\"https://127.0.0.1:1/GeoSite.dat\\": connection refused"\n' +
	'configuration file /etc/ecycloud/run/fixture-session/.validate-0123456789ab.json test failed\n';
let res = validate(runDir);
check(!res.ok && res.error == 'rules[0] [GEOSITE,cn,DIRECT] error: can\'t download GeoSite.dat: Get "https://127.0.0.1:1/GeoSite.dat": connection refused',
	`校验失败须显示最后一条错误日志的原文，实际：${res.error}`);
check(res.transient == false, '内核自己跑完并报出错误才算配置不合法');

testState.commandText = 'time="2026-11-22T00:38:36.280921000-08:00" level=error msg="proxy group[0]: G: \'missing-node\' not found"\nconfiguration file x test failed\n';
res = validate(runDir);
check(res.error == 'proxy group[0]: G: \'missing-node\' not found', `代理组错误须显示原因，实际：${res.error}`);

testState.commandText = 'time="2026-11-22T00:38:36Z" level=fatal msg=Parse\nconfiguration file x test failed\n';
check(validate(runDir).error == 'Parse', '不带引号的 msg 原样显示');

testState.commandText = 'sh: /usr/libexec/mihomo: not found\n';
check(validate(runDir).error == 'sh: /usr/libexec/mihomo: not found', '没有日志行时仍显示最后一行');

testState.commandText = '';
check(validate(runDir).error == 'mihomo -t 退出码 1', '没有任何输出时显示退出码');

for (let status in [ -9, 126, 127, 1 ]) {
	testState.commandStatus = status;
	testState.commandText = status == 1 ? '' : 'time="2026-11-22T00:38:36Z" level=error msg="can\'t initial GeoSite"\n';
	check(validate(runDir).transient == true, `校验进程被信号结束、内核不可执行或没报出原因（退出码 ${status}）只是这次没校验成，不能当成配置不合法`);
}

testState.commandStatus = 0;
testState.commands = [];
const written = [];
testState.onWrite = path => push(written, path);
check(validate(runDir).ok && match(filter(testState.commands, c => index(c, ' -t -f ') >= 0)[0],
	/ -t -f '\/var\/run\/ecycloud\/validate-[0-9a-f]+\.json' -d '\/etc\/ecycloud\/run\/fixture-session' /) &&
	!length(filter(written, path => index(path, runDir) == 0)) && !length(filter(keys(testState.files), path => index(path, 'validate-') >= 0)),
	'带节点凭据的校验副本只能写在 tmpfs 并在校验后删除，不能落进闪存上的运行目录');

print(`validate_reason_test: ${assertions} assertions passed\n`);
