'use strict';

import { testState } from 'fs';
import { ANNOUNCE_CACHE, CRED_FILE, PROFILE_FILE } from 'ecycloud.common';
import { announcements, clashProfile, refreshAccount, touchIdentity } from 'ecycloud.panel';
import { store } from 'ecycloud.profile';

function check(ok, message) {
	if (!ok)
		die(message);
};

testState.config.site_url = 'https://fixture.test';
testState.files[CRED_FILE] = sprintf('%J', {
	token: 'fixture-token', email: 'fixture@test', device_id: 'fixture', expires_at: '2030-01-01T00:00:00Z'
});
testState.response = { ret: 1, data: { announcements: [ { id: 2, title: 'fixture-en', date: '2026-01-01', content: '<p>fixture</p>' } ] } };
let res = announcements('refresh', 'en-US');
check(res.ok, '英文公告读取失败');
let saved = json(testState.files[ANNOUNCE_CACHE]);
check(saved.locale == 'en-US' && saved.items[0].title == 'fixture-en', '缓存必须记录语言');
let found = false;
for (let path, content in testState.writes)
	if (match(path, /\.conf$/) && index(content, 'Accept-Language: en-US') >= 0)
		found = true;
check(found, '公告请求必须携带语言');

testState.response.data.announcements[0].title = 'fixture-tw';
res = announcements('', 'zh-TW');
saved = json(testState.files[ANNOUNCE_CACHE]);
check(res.ok && saved.locale == 'zh-TW' && saved.items[0].title == 'fixture-tw', '切换语言不能使用旧语言缓存');
check(!announcements('refresh', 'en-US\r\nX-Injected: 1').ok, '必须拒绝语言头注入');
check(!announcements('refresh', [ 'en-US' ]).ok, '必须拒绝数组语言');
global.system = command => { push(testState.commands, command); return 0; };
const remote = { locale: 'en-US', revision: 'fixture-revision', config: {},
	group_labels: { '主节点': 'Main nodes' },
	offline_authorization: { issued_at: time(), valid_until: time() + 7200 } };
check(store(remote), '配置元信息缓存保存失败');
check(json(testState.files[PROFILE_FILE]).locale == 'en-US', '配置缓存必须记录语言');
check(json(testState.files[PROFILE_FILE]).group_labels['主节点'] == 'Main nodes', '策略组译名须保存在界面元信息中');
check(json(testState.files[PROFILE_FILE]).config.group_labels == null, '策略组译名不能进入内核配置');
testState.response = { ret: 1, data: { config_revision: 'fixture-revision' } };
let requests = 0;
testState.onRequest = () => {
	for (let path, content in testState.files) {
		if (match(path, /\.conf$/)) {
			check(index(content, 'Accept-Language: en-US') >= 0, '配置和账户摘要必须使用缓存的同一语言');
			requests++;
		}
	}
};
check(refreshAccount().ok && touchIdentity().ok && clashProfile().ok, '配置与摘要请求失败');
check(requests >= 4, '应覆盖配置、配置摘要、账户摘要和账户状态');
testState.onRequest = null;
check(clashProfile('zh-TW').ok, '切换配置语言失败');
let switched = false;
for (let path, content in testState.writes)
	if (match(path, /\.conf$/) && index(content, '/config/clash') >= 0 && index(content, 'Accept-Language: zh-TW') >= 0)
		switched = true;
check(switched, '显式切换语言不能继续使用旧配置语言');
printf('OpenWrt 人工内容语言回归通过。\n');
